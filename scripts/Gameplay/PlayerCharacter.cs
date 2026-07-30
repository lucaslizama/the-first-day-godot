using Godot;

namespace TheFirstDay.Gameplay;

/// <summary>
/// Port of the player controller: Unity's Yelena.cs plus its YelenaMovementModule
/// and YelenaKeyboardMovement helpers, collapsed into one CharacterBody3D.
///
/// Despite the class names, this drove *Fortunato* in the shipped level — the
/// Yelena script component is attached to the Fortunato prefab, while the Yelena
/// prefab instance itself is disabled (m_IsActive: 0). Tunable defaults below are
/// Fortunato's, not the Yelena prefab's.
///
/// Runs in _PhysicsProcess rather than Unity's Update, so the fall grace period
/// is five physics ticks instead of five rendered frames.
/// </summary>
public partial class PlayerCharacter : CharacterBody3D
{
    /// <summary>Constant downward bias applied while grounded, as in the original.</summary>
    private const float GroundedSpeed = -1.0f;

    private const int TicksToWaitForFall = 5;

    /// <summary>Stands in for the animator's clipless death state. See <see cref="Die"/>.</summary>
    private const string DeathSubstituteClip = "fall";

    /// <summary>
    /// The eight movement directions in camera space, using Godot's -Z forward.
    /// Indexed by <see cref="WasDirection"/>.
    /// </summary>
    private static readonly Vector3[] Directions =
    {
        new(0.0f, 0.0f, -1.0f),  // Up
        new(0.0f, 0.0f, 1.0f),   // Down
        new(-1.0f, 0.0f, 0.0f),  // Left
        new(1.0f, 0.0f, 0.0f),   // Right
        new(1.0f, 0.0f, -1.0f),  // UpRight
        new(-1.0f, 0.0f, -1.0f), // UpLeft
        new(1.0f, 0.0f, 1.0f),   // DownRight
        new(-1.0f, 0.0f, 1.0f),  // DownLeft
        Vector3.Zero,            // NoInput
    };

    [Export]
    public float WalkSpeed { get; set; } = 2.5f;

    [Export]
    public float RunSpeed { get; set; } = 4.5f;

    /// <summary>Maximum turn rate, degrees per second (Quaternion.RotateTowards in the original).</summary>
    [Export]
    public float AngularSpeedDegrees { get; set; } = 720.0f;

    [Export]
    public float JumpForce { get; set; } = 10.0f;

    [Export]
    public float Gravity { get; set; } = 20.0f;

    /// <summary>
    /// Supplies the movement basis. The original flattened a "YAxis" transform to
    /// strip pitch and roll; here only the camera's yaw is used, which is the same
    /// intent without mutating the camera.
    /// </summary>
    [Export]
    public NodePath CameraBasisPath { get; set; } = new();

    /// <summary>Drives Fortunato's clips. Optional: movement works without it.</summary>
    [Export]
    public NodePath AnimationPlayerPath { get; set; } = new();

    /// <summary>
    /// The footstep sound, Fortunato's own AudioSource. Optional: without it the
    /// animation's method tracks find nothing to play and are harmless.
    /// </summary>
    [Export]
    public NodePath StepSoundPath { get; set; } = new("StepSound");

    /// <summary>Random.Range(0.8f, 1.2f) in RandomizePitch.</summary>
    [Export]
    public float MinStepPitch { get; set; } = 0.8f;

    [Export]
    public float MaxStepPitch { get; set; } = 1.2f;

    private Node3D? _cameraBasis;
    private AnimationPlayer? _animation;
    private AudioStreamPlayer3D? _stepSound;

    /// <summary>
    /// Alternates the take-off foot. The original tracked this with a LeftJump
    /// animator bool, flipped by SetLeftJump/SetRightJump animation events.
    /// </summary>
    private bool _leftJump;

    public bool IsRunning { get; private set; }

    public bool IsJumping { get; private set; }

    public bool IsFalling { get; private set; }

    /// <summary>
    /// Set between <see cref="Die"/> and <see cref="Revive"/>. Control is stopped by
    /// PlayerInput.CanValidateInput rather than by this, exactly as in the original -
    /// the respawn chain disables input in the same breath as calling Die.
    /// </summary>
    public bool IsDead { get; private set; }

    private bool _checkingForFall;
    private int _fallCheckTicks;

    public override void _Ready()
    {
        _cameraBasis = GetNodeOrNull<Node3D>(CameraBasisPath);
        _animation = GetNodeOrNull<AnimationPlayer>(AnimationPlayerPath);
        _stepSound = GetNodeOrNull<AudioStreamPlayer3D>(StepSoundPath);

        if (_cameraBasis is null)
        {
            GD.PushWarning($"{Name}: CameraBasisPath '{CameraBasisPath}' did not resolve; movement will use world axes.");
        }

        StripUnresolvableTracks();
    }

    /// <summary>
    /// The clip FBXs were exported from a Maya rig, so every animation also carries
    /// tracks for its IK/FK control hierarchy (Group/Main/MotionSystem/...). The base
    /// model only contains the deformation skeleton, so those tracks resolve to
    /// nothing and Godot warns about each one on every play — thousands of lines.
    /// Skinning is unaffected; drop them once up front instead of muting the warning
    /// project-wide, which would also hide genuine animation breakage later.
    /// </summary>
    private void StripUnresolvableTracks()
    {
        if (_animation is null)
        {
            return;
        }

        Node? root = _animation.GetNodeOrNull(_animation.RootNode);
        if (root is null)
        {
            return;
        }

        foreach (string name in _animation.GetAnimationList())
        {
            Animation animation = _animation.GetAnimation(name);

            for (int track = animation.GetTrackCount() - 1; track >= 0; track--)
            {
                // Bone tracks look like "Path/To/Skeleton3D:BoneName"; only the node
                // portion needs to resolve.
                var nodePath = new NodePath(animation.TrackGetPath(track).GetConcatenatedNames());
                if (root.GetNodeOrNull(nodePath) is null)
                {
                    animation.RemoveTrack(track);
                }
            }
        }
    }

    public override void _PhysicsProcess(double delta)
    {
        PlayerInput? input = PlayerInput.Instance;
        if (input is null)
        {
            return;
        }

        IsRunning = input.Run;

        Vector3 direction = GetDirection(input.CurrentDirection);
        ApplyRotation(direction, input.CurrentDirection, delta);

        bool wasJumping = IsJumping;
        Velocity = BuildVelocity(direction, input.Jump, delta);

        // Take-off happened this tick: swap the leading foot.
        if (IsJumping && !wasJumping)
        {
            _leftJump = !_leftJump;
        }

        MoveAndSlide();
        CheckForFall();
        UpdateAnimation(input.CurrentDirection);
    }

    /// <summary>
    /// Port of Fortunato.PlayStepSound, called from the walk and run clips' method
    /// tracks - the animation events that did not survive the FBX export and were
    /// re-added by tools/add_footstep_events.gd at measured footfalls.
    ///
    /// Unity fired two events per footfall, RandomizePitch then PlayStepSound. Both are
    /// done here in one call: two method keys at the same time in one track depend on
    /// insertion order to come out right, and the pair was always used together anyway -
    /// Fortunato.Update's landing branch called RandomizePitch and then played the same
    /// source. <see cref="RandomizePitch"/> is still public, as it was there.
    /// </summary>
    public void PlayStepSound()
    {
        RandomizePitch();
        _stepSound?.Play();
    }

    /// <summary>Port of Fortunato.RandomizePitch: source.pitch = Random.Range(0.8, 1.2).</summary>
    public void RandomizePitch()
    {
        if (_stepSound is not null)
        {
            _stepSound.PitchScale = (float)GD.RandRange(MinStepPitch, MaxStepPitch);
        }
    }

    /// <summary>
    /// Port of Fortunato.Die. The original pulled the animator's "Death" trigger and
    /// disabled input; the input half is the respawn chain's first call, so only the
    /// animation is here.
    ///
    /// **There is no death animation.** The controller's damage and death states have
    /// no clip anywhere in the project, in FBX or .anim form - confirmed while porting
    /// the animations, and the reason this needed a substitute at all. Unity's animator
    /// would have entered a state with nothing to play and held whatever pose it had.
    ///
    /// The substitute is the fall clip, which is the closest thing the project owns and
    /// reads correctly for the only way the player dies: falling into the kill volume.
    /// Nothing else is invented - no ragdoll, no fresh animation.
    /// </summary>
    public void Die()
    {
        if (IsDead)
        {
            return;
        }

        IsDead = true;
        _animation?.Play(DeathSubstituteClip);
    }

    /// <summary>
    /// Port of Fortunato.Revive: the "Revive" trigger plus charController.Move(zero).
    /// The zero move existed to flush the controller's accumulated motion, which is
    /// Velocity here - without clearing it, the fall speed built up on the way into the
    /// kill volume survives the teleport and the player drops straight through the
    /// checkpoint floor.
    /// </summary>
    public void Revive()
    {
        IsDead = false;
        IsFalling = false;
        IsJumping = false;
        _checkingForFall = false;
        Velocity = Vector3.Zero;
    }

    /// <summary>
    /// Stands in for the "Fortunato Controller" animator. Its walk_run_tree blended
    /// on MoveSpeed, but the keyboard path only ever set that to 0 or 1, so walk and
    /// run are selected outright. The controller's damage and death states are not
    /// reproduced: neither has a clip in the project, in FBX or .anim form.
    /// </summary>
    private void UpdateAnimation(WasDirection current)
    {
        if (_animation is null)
        {
            return;
        }

        // While dead the clip is Die's business. Without this the per-tick selection
        // below would immediately overwrite it, since the player is usually still
        // falling at the moment they die.
        if (IsDead)
        {
            return;
        }

        string next;
        if (IsFalling)
        {
            next = "fall";
        }
        else if (IsJumping)
        {
            next = _leftJump ? "jumpL" : "jumpR";
        }
        else if (current != WasDirection.NoInput)
        {
            next = IsRunning ? "run" : "walk";
        }
        else
        {
            next = "idle";
        }

        if (_animation.CurrentAnimation != next)
        {
            _animation.Play(next);
        }
    }

    /// <summary>
    /// Maps the discrete direction into world space using the camera's yaw only.
    /// </summary>
    private Vector3 GetDirection(WasDirection current)
    {
        Vector3 local = Directions[(int)current];
        if (local == Vector3.Zero)
        {
            return Vector3.Zero;
        }

        Vector3 forward = Vector3.Forward; // world -Z if no camera is wired
        if (_cameraBasis is not null)
        {
            forward = -_cameraBasis.GlobalBasis.Z;
        }

        forward.Y = 0.0f;
        if (forward.LengthSquared() < 0.0001f)
        {
            return Vector3.Zero;
        }

        forward = forward.Normalized();
        Vector3 right = forward.Cross(Vector3.Up);

        // local.Z is negative for "forward", hence the sign flip.
        Vector3 world = (right * local.X) + (forward * -local.Z);
        return world.Normalized();
    }

    /// <summary>
    /// Turns toward the direction of travel at a capped rate. The original stored
    /// a table of per-direction yaw offsets (0, 180, 270, 90, 45, 315, 135, 225)
    /// added to the camera's yaw, which reduces exactly to "face where you move".
    /// </summary>
    private void ApplyRotation(Vector3 direction, WasDirection current, double delta)
    {
        if (current == WasDirection.NoInput || direction == Vector3.Zero)
        {
            return;
        }

        float currentYaw = Rotation.Y;
        float targetYaw = Mathf.Atan2(-direction.X, -direction.Z);

        float difference = Mathf.Wrap(targetYaw - currentYaw, -Mathf.Pi, Mathf.Pi);
        float maxStep = Mathf.DegToRad(AngularSpeedDegrees) * (float)delta;
        float step = Mathf.Clamp(difference, -maxStep, maxStep);

        Rotation = new Vector3(0.0f, currentYaw + step, 0.0f);
    }

    /// <summary>
    /// Assembles the velocity in the original's order: horizontal speed, grounded
    /// bias, jump transitions, then gravity.
    /// </summary>
    private Vector3 BuildVelocity(Vector3 direction, bool jumpPressed, double delta)
    {
        Vector3 velocity = Velocity;
        float speed = IsRunning ? RunSpeed : WalkSpeed;

        velocity.X = direction.X * speed;
        velocity.Z = direction.Z * speed;

        if (!IsJumping && !IsFalling)
        {
            velocity.Y = GroundedSpeed;
        }

        if (jumpPressed && !IsFalling && !IsJumping)
        {
            velocity.Y = JumpForce;
            IsJumping = true;
        }

        // Apex reached: hand over from jumping to falling.
        if (IsJumping && velocity.Y <= 0.0f)
        {
            IsJumping = false;
            IsFalling = true;
        }

        if (IsFalling && IsOnFloor())
        {
            IsFalling = false;
            velocity.Y = GroundedSpeed;

            // Fortunato.Update played the step sound whenever the animator sat in its
            // "land" or "land_moving" state - every frame it was in one, in fact. Neither
            // clip came across in the FBX, so there is no land state to watch; touchdown
            // is the same moment, and playing once is what the short state amounted to.
            PlayStepSound();
        }

        if (IsFalling || IsJumping)
        {
            velocity.Y -= Gravity * (float)delta;
        }

        return velocity;
    }

    /// <summary>
    /// Leaving the floor does not immediately mean falling: the original waited
    /// five frames before committing, so walking over small gaps and seams does
    /// not trigger a fall. Aborts early if the floor comes back.
    /// </summary>
    private void CheckForFall()
    {
        if (IsFalling || IsJumping)
        {
            _checkingForFall = false;
            return;
        }

        if (!_checkingForFall)
        {
            if (IsOnFloor())
            {
                return;
            }

            _checkingForFall = true;
            _fallCheckTicks = 0;
        }

        if (IsOnFloor())
        {
            _checkingForFall = false;
            return;
        }

        _fallCheckTicks++;
        if (_fallCheckTicks >= TicksToWaitForFall)
        {
            _checkingForFall = false;
            IsFalling = true;
        }
    }
}
