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

    /// <summary>
    /// The clip the animator's death state uses. Named "fall" because that is what the
    /// source clip is called - `fall.anim` - which is confusing but is not a mistake and
    /// is not a substitute: the Fortunato Controller's `death` state really does point at
    /// fall.anim. **The airborne states do NOT use it**; see <see cref="UpdateAnimation"/>.
    /// </summary>
    private const string DeathClip = "fall";

    /// <summary>
    /// The airborne clips, by state, matching the Fortunato Controller's jump_land
    /// sub-machine. Its entry transition is the controller's ONLY use of LeftJump:
    ///
    ///   LeftJump true  -> jump_moving, fall_moving, land_moving  -> jumpL,  jumpL1Frame
    ///   LeftJump false -> jump,        fall,        land         -> jumpR,  jumpR1Frame
    ///
    /// The "_moving" in those state names is a misnomer - nothing about them tests
    /// movement. They are the left-foot variants.
    /// </summary>
    private const string JumpLeftClip = "jumpL";

    private const string JumpRightClip = "jumpR";

    private const string AirborneLeftClip = "jumpL1Frame";

    private const string AirborneRightClip = "jumpR1Frame";

    /// <summary>The animator's `cry` state, which does have a clip. See <see cref="Cry"/>.</summary>
    private const string CryClip = "cry";

    /// <summary>
    /// The Any State -> death transition's m_TransitionDuration. Unity blended into the
    /// death pose over this; the cry transition's is 0, so only death gets a blend.
    /// </summary>
    private const float DeathBlendSeconds = 0.1f;

    /// <summary>
    /// The death -> idle transition's m_TransitionDuration, taken when Revive fires.
    ///
    /// Read out of the Fortunato Controller rather than chosen. Every OTHER transition in that
    /// controller is a hard cut - walk_run_tree to jump, jump to fall, fall to land, land back to
    /// locomotion are all m_TransitionDuration 0 - which is why this port plays those clips with no
    /// blend, and why an earlier attempt to blend into the jump clips was wrong in principle rather
    /// than merely wrong by feel. The only non-zero durations in the whole controller are the 0.1 s
    /// into death, this 0.25 s back out of it, and 0.25 s on the land states' re-fall.
    ///
    /// HONEST NOTE ON WHAT THIS BUYS: nothing visible today. RespawnChain calls Revive at
    /// OnFadeOutComplete, i.e. while the screen is fully black, so the blend runs behind the fade.
    /// It is ported because it is the controller's value and because the fade timing is not
    /// guaranteed to stay where it is.
    /// </summary>
    private const float ReviveBlendSeconds = 0.25f;

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
    /// Tallest obstruction the character will climb by walking into it, in metres.
    ///
    /// A DELIBERATE ADDITION, not a port fix. Unity's CharacterController had
    /// <c>m_StepOffset: 0</c>, so the original could not step either - the stairs before the end
    /// line had to be jumped. This exists because walking into them and stopping dead reads as a
    /// bug to anyone playing, whatever the original did.
    ///
    /// Without it the limit is set by capsule geometry alone. Contact with a step happens on its
    /// top EDGE, and the normal runs from that edge to the bottom sphere's centre at y = radius.
    /// move_and_slide only slides UP a surface it classifies as floor, i.e. under FloorMaxAngle,
    /// so the tallest walkable step is r * (1 - 1/sqrt(2)) = 0.088 m for this 0.3 m capsule.
    /// Measured at between 0.09 and 0.10 m, which is that number. The stairs' risers are 0.19 to
    /// 0.27 m - two to three times the limit - which is why it is a hard stop rather than an
    /// occasional snag, and why neither speed nor safe_margin made any difference.
    ///
    /// 0.30 m clears the tallest riser with room to spare. Raising it lets the character mount
    /// anything shorter than the new value, so tools/verify_stairs.gd asserts both directions:
    /// that he climbs the stairs, and that he cannot climb a ledge taller than this.
    /// </summary>
    [Export]
    public float StepHeight { get; set; } = 0.3f;

    /// <summary>
    /// How far below the stepped-up position to search for ground, beyond <see cref="StepHeight"/>.
    /// Without a little slack the settle can miss a tread that sits a hair lower than the lift.
    /// </summary>
    private const float StepSettleSlack = 0.05f;

    /// <summary>Ignore blocked motion smaller than this; it is jitter, not a step.</summary>
    private const float MinStepMotion = 0.001f;

    /// <summary>Below this the camera offset is finished; a millimetre is not worth carrying.</summary>
    private const float StepSmoothingEpsilon = 0.001f;

    /// <summary>
    /// How far forward to carry the character while stepping, at least. Must be enough to put his
    /// footprint ON the tread rather than leaving him hugging the riser.
    ///
    /// This is the whole reason the first version of the step-up did nothing. One frame of walking
    /// is about 4 cm, so advancing by only the motion a wall swallowed left the capsule still
    /// against the riser; the settle then contacted the riser's VERTICAL FACE, whose 90 degree
    /// normal is correctly rejected as not-floor, and every attempt was vetoed. The gates all
    /// passed - it failed at the last stage, for a reason that looked like the geometry's fault.
    ///
    /// 0.25 m is just under the 0.3 m capsule radius, so the contact point clears the edge. Being
    /// larger than one frame's motion means a step costs slightly less ground than walking it
    /// would, which is what every step-offset implementation trades for not sticking.
    /// </summary>
    [Export]
    public float StepForwardProbe { get; set; } = 0.25f;

    /// <summary>The group name <see cref="ClimbableGroup"/> defaults to, so taggers agree with it.</summary>
    public const string DefaultClimbableGroup = "climbable";

    /// <summary>
    /// Group a surface must be in for the character to step up onto it. OPT-IN: nothing is
    /// climbable unless marked, so a step-up can never happen somewhere nobody intended.
    ///
    /// Groups rather than collision layers, and worth saying why. Godot has both - layers are a
    /// bitmask on the body (Unity's layers, except an object can be on several and each body
    /// declares its own mask instead of a global matrix) and groups are many-per-node strings
    /// (Unity's tags, except many). Either could express this, but TestMove and MoveAndCollide use
    /// the BODY'S OWN collision_mask and cannot be filtered per call, so a layer would have to be
    /// consulted through a second query. The manoeuvre already holds the colliders it touched, so a
    /// group test on those costs nothing and needs no project settings. Groups are also already
    /// this project's idiom - "player" is tested in four scripts - while no layer is named or set
    /// anywhere.
    ///
    /// The cost of opt-in, so it is not a surprise later: any steps NOT tagged still stop the
    /// character dead, exactly as they did before the step-up existed. Tagging lives on the thing
    /// that builds the collision - see LevelShell.ClimbableMeshes.
    /// </summary>
    [Export]
    public string ClimbableGroup { get; set; } = DefaultClimbableGroup;

    /// <summary>
    /// Node whose local Y is held back to hide the step-up teleport from the camera. The camera aims
    /// at a child of this, so offsetting the parent moves the view without touching the body.
    /// </summary>
    [Export]
    public NodePath CameraSmoothingPath { get; set; } = new("CameraTargetParent");

    /// <summary>
    /// Time for the camera's remaining catch-up to halve, in seconds. Larger is smoother and laggier.
    ///
    /// Exponential rather than a constant speed, and the shape matters more than the amount. A
    /// constant drain starts and stops abruptly, so a flight of eight steps produced eight little
    /// linear ramps with a corner at each end - measurably within bounds, still visible as stepping.
    /// Decay proportional to what is left has no corners, and because a new step adds to an offset
    /// that is still decaying, consecutive steps blend into one continuous rise.
    ///
    /// It also self-limits: the rate scales with the offset, so the lag while running upstairs settles
    /// instead of growing, which a constant speed slower than the step rate would not do.
    ///
    /// The trade, MEASURED over the real staircase at RunSpeed rather than derived - and the
    /// measurement is worth keeping because the theory oversells it. Halving the decay does not halve
    /// the per-frame movement, because the offset accumulates over eight quick steps and a larger
    /// offset decays by more in absolute terms. So smoothness improves slowly while lag grows fast:
    ///
    ///     half-life   worst rise/frame   worst lag behind the body
    ///       0.08 s        0.040 m               0.261 m
    ///       0.15 s        0.031 m               0.349 m
    ///       0.25 s        0.026 m               0.467 m
    ///       0.40 s        0.023 m               0.631 m
    ///
    /// 0.15 is the default: about a quarter smoother per frame than 0.08, for 0.09 m more lag. Past
    /// that the returns are poor - 0.40 buys only another 0.008 m of smoothness for 0.28 m of lag,
    /// which is the camera visibly trailing the character rather than easing after him.
    ///
    /// TREAT THAT TABLE AS SUSPECT. It was measured through the old tools/verify_stairs.gd, which
    /// called move_and_slide() from _process and so drove the body at 1.7 to 3.6 times walking
    /// speed. Re-measured at RunSpeed through the rewritten scene-based verifier, worst camera rise
    /// per tick is:
    ///
    ///     half-life   worst rise/tick
    ///       0.15 s        0.053 m      <- over the 0.050 the verifier allows
    ///       0.20 s        0.049 m
    ///       0.25 s        0.045 m      <- current
    ///       0.35 s        0.040 m
    ///
    /// 0.25 rather than 0.20 because 0.20 clears the limit by a single millimetre, which is the kind
    /// of margin that makes a check fail one run in three. The lag half of the trade is NOT
    /// currently measured - the attempt to instrument it returned 0.000 at every half-life, i.e. it
    /// measured nothing - so the cost of going slower than this is unquantified. Worth confirming by
    /// ear before trusting it: a camera that eases too slowly reads as trailing the character.
    /// </summary>
    [Export]
    public float StepSmoothingHalfLife { get; set; } = 0.25f;

    /// <summary>
    /// How far off vertical a contact may be and still count as ground to step DOWN onto. Above
    /// FloorMaxAngle on purpose - see <see cref="HasStandableContact"/> for the measurements. 60
    /// covers the 46-50 degree edge contacts the stairs produce with room to spare, while still
    /// refusing anything close to a wall.
    /// </summary>
    [Export]
    public float StepDownMaxAngleDegrees { get; set; } = 60.0f;

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
    private Node3D? _cameraSmoothing;
    private float _cameraSmoothingBaseY;

    /// <summary>
    /// Metres of step-up gain the body has already taken but the camera has not been shown yet,
    /// drained at <see cref="StepSmoothingSpeed"/>.
    ///
    /// A step-up is a teleport: the whole riser lands in one frame. That is right for the body and
    /// wrong for the camera, which followed it and jumped 0.269 m in a single frame - a visible pop
    /// on every step. The body stays where physics puts it and the camera target is held back by
    /// this much, catching up over a few frames.
    /// </summary>
    private float _stepSmoothing;

    /// <summary>
    /// The animator's LeftJump bool: true when the LEFT foot was the last to land while
    /// walking or running. Not a per-jump alternation - Unity set it from animation
    /// events on the walk and run clips, at the same times as the footstep sounds, via
    /// Fortunato.SetLeftJump/SetRightJump. So the airborne pose matches the stride the
    /// player took off from, and a jump from standing still reuses whatever the last
    /// footfall left behind (false, hence jumpR, until the player has walked at all).
    /// </summary>
    private bool _leftJump;

    /// <summary>Set by <see cref="Cry"/>; see the guard in UpdateAnimation.</summary>
    private bool _crying;

    /// <summary>
    /// Blend to use for the NEXT clip change only, in seconds, or -1 for the player's default.
    /// Armed by <see cref="Revive"/> so the way out of the death pose is Unity's 0.25 s rather than a
    /// cut; every other transition in the controller is a cut, so this is spent immediately and reset.
    /// </summary>
    private float _pendingBlendSeconds = -1.0f;

    /// <summary>
    /// The clip last asked for, which is NOT the same as AnimationPlayer.CurrentAnimation.
    /// Godot clears CurrentAnimation when a non-looping clip finishes, so comparing
    /// against it re-triggered the clip on the very next tick and kept doing so for as
    /// long as the state held - the jump clips are 0.167 s against an ascent of about
    /// 0.23 s, so a single jump replayed its take-off several times. Only walk, run and
    /// idle loop (Unity's m_LoopTime); everything else is meant to end and hold its last
    /// pose, which is what tracking the request rather than the playhead gives.
    /// </summary>
    private string _requestedClip = string.Empty;

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

        _cameraSmoothing = GetNodeOrNull<Node3D>(CameraSmoothingPath);
        if (_cameraSmoothing is not null)
        {
            _cameraSmoothingBaseY = _cameraSmoothing.Position.Y;
        }

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

        Velocity = BuildVelocity(direction, input.Jump, delta);

        // The leading foot is NOT swapped here. It comes from SetLeftJump/SetRightJump,
        // driven by method tracks on the walk and run clips - see _leftJump. An earlier
        // version toggled it on every take-off, which alternates feet regardless of
        // gait and is not what the animator did.

        // Captured before the slide so the step-up can tell how much of the intended horizontal
        // motion actually happened, and retry only the part a wall swallowed.
        Transform3D beforeMove = GlobalTransform;
        Vector3 intended = new Vector3(Velocity.X, 0.0f, Velocity.Z) * (float)delta;

        bool wasOnFloor = IsOnFloor();
        MoveAndSlide();
        if (!TryStepUp(intended, beforeMove))
        {
            TryStepDown(wasOnFloor);
        }

        // Written HERE, in the same tick the offset changed, even though the DECAY happens in
        // _Process. Splitting the two is the whole point: if the node were only updated by the
        // decay, a lift taken on a physics tick would go uncompensated until the next rendered
        // frame, and the camera - which reads its target in _Process, and may well run before this
        // node does - would see the raw teleport. Measured at 5.5 m/s of camera rise, which is worse
        // than the stutter the move was meant to cure.
        ApplyStepSmoothing();

        CheckForFall();
        UpdateAnimation(input.CurrentDirection);
    }

    /// <summary>
    /// Drains the camera's step offset on the RENDER clock, not the physics clock.
    ///
    /// Reported in play as a minor stutter in the camera on every lift, with the stairs themselves
    /// feeling right. The offset is a purely VISUAL quantity - it exists so the camera is not shown
    /// a teleport - and ThirdPersonCamera reads its target in _Process, once per rendered frame.
    /// Draining it in _PhysicsProcess meant the value the camera reads only changed 60 times a
    /// second, so above 60 fps the camera repeated a position and then jumped, over and over. No
    /// amount of tuning StepSmoothingHalfLife fixes that: it makes each jump smaller without
    /// removing the stepping.
    ///
    /// The drain is already frame-rate independent (exponential in delta), so moving it here costs
    /// nothing and it now advances exactly as often as the camera samples it.
    ///
    /// This does NOT address the general case: the body's own position still only changes on physics
    /// ticks, so any motion is sampled at 60 Hz by a camera running faster. The engine-level answer
    /// to that is physics/common/physics_interpolation, which is off in this project and would need
    /// the camera opted out (it is driven per-frame) and reset_physics_interpolation() on the respawn
    /// teleport. That is a project-wide change and deliberately not made here.
    /// </summary>
    public override void _Process(double delta)
    {
        DrainStepSmoothing(delta);
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
        _requestedClip = DeathClip;

        // 0.1 s blend, which is the Any State -> death transition's m_TransitionDuration
        // in the Fortunato Controller. The port used to cut instantly. Note the cry
        // transition's duration is 0, so Cry deliberately does NOT blend.
        _animation?.Play(DeathClip, DeathBlendSeconds);
    }

    /// <summary>
    /// Fortunato.SetLeftJump / SetRightJump, called from method tracks on the walk and
    /// run clips at each footfall - the same moments that fire PlayStepSound, which is
    /// how Unity had it. Together they keep LeftJump equal to "the left foot landed
    /// last", which the animator uses to pick the airborne pose.
    /// </summary>
    public void SetLeftJump()
    {
        _leftJump = true;
    }

    public void SetRightJump()
    {
        _leftJump = false;
    }

    /// <summary>
    /// Port of Fortunato.Cry, which TimerZone calls when the player crosses the finish
    /// line. The original is one line, anim.SetTrigger("Cry"), and the Fortunato
    /// Controller has an Any State transition into a `cry` state pointing at cry.anim -
    /// an 11.4 second clip that imports fine and is sitting in the AnimationPlayer.
    ///
    /// This was previously written as a no-op on the belief that "Cry" had no clip. That
    /// was wrong: the claim came from a note about the animator's *damage* and *death*
    /// states, and only `damage` is genuinely clipless (its motion guid resolves to
    /// nothing). `death` points at fall.anim and `cry` at cry.anim, and both exist.
    /// </summary>
    public void Cry()
    {
        _crying = true;
        _requestedClip = CryClip;
        _animation?.Play(CryClip);
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
        _crying = false;

        // Unity's death -> idle transition. Spent by the next clip change in UpdateAnimation.
        _pendingBlendSeconds = ReviveBlendSeconds;
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

        // Same for crying. The animator reaches `cry` from Any State and has no
        // transition out of it, so once the ending starts the pose stays; without this
        // the player would be standing still and idle would win on the next tick.
        if (_crying)
        {
            return;
        }

        string next;
        if (IsFalling)
        {
            // The animator's fall/fall_moving states, which use the single-frame jump
            // clips - NOT fall.anim. fall.anim belongs to the death state, and playing
            // it here is what made every descent look like dying: the clip is a
            // collapse, and a jump spends most of its arc falling.
            next = _leftJump ? AirborneLeftClip : AirborneRightClip;
        }
        else if (IsJumping)
        {
            next = _leftJump ? JumpLeftClip : JumpRightClip;
        }
        else if (current != WasDirection.NoInput)
        {
            next = IsRunning ? "run" : "walk";
        }
        else
        {
            next = "idle";
        }

        if (_requestedClip != next)
        {
            _requestedClip = next;
            _animation.Play(next, _pendingBlendSeconds);
            _pendingBlendSeconds = -1.0f;
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
    /// Climbs an obstruction up to <see cref="StepHeight"/> that stopped the slide, so the
    /// character walks up stairs instead of standing against them. Returns true if he was moved.
    ///
    /// The same manoeuvre PhysX runs for Unity's <c>stepOffset</c>, done by hand because Godot's
    /// CharacterBody3D has no equivalent property: lift, advance, settle. Every stage can veto,
    /// and a veto restores the position the slide left, so a failed attempt costs nothing.
    ///
    /// Runs AFTER MoveAndSlide rather than before, which matters: it retries only the part of the
    /// intended motion a wall actually swallowed. Attempting it first and then sliding would
    /// advance the character twice in one frame.
    ///
    /// Public only so tools/verify_stairs.gd can drive the real thing. The alternative was a test
    /// that re-implements this manoeuvre, which is how a check drifts away from the code it is
    /// supposed to be checking.
    /// </summary>
    /// <param name="intended">Horizontal motion asked for this frame, before the slide.</param>
    /// <param name="beforeMove">Global transform captured before the slide.</param>
    public bool TryStepUp(Vector3 intended, Transform3D beforeMove)
    {
        // Only while walking on the ground. Without this he could mount walls in mid-air, and
        // jumping into a ledge would snap him on top of it.
        if (!IsOnFloor() || IsJumping || IsFalling)
        {
            return false;
        }

        // A wall is the only thing worth stepping over. IsOnWall is false when the slide
        // completed, which is the common case and costs one branch.
        if (!IsOnWall())
        {
            return false;
        }

        Vector3 moved = GlobalPosition - beforeMove.Origin;
        Vector3 remaining = intended - new Vector3(moved.X, 0.0f, moved.Z);
        remaining.Y = 0.0f;
        if (remaining.LengthSquared() < MinStepMotion * MinStepMotion)
        {
            return false;
        }

        // Carried at least StepForwardProbe, in the direction the blocked motion wanted to go, so
        // the settle lands on the tread instead of on the riser's vertical face. See that field.
        Vector3 advance = remaining.Normalized() * Mathf.Max(remaining.Length(), StepForwardProbe);

        Transform3D start = GlobalTransform;
        Vector3 lift = Vector3.Up * StepHeight;

        // 1. Headroom. Refusing here is what stops him climbing into a low overhang.
        if (TestMove(start, lift))
        {
            return false;
        }

        // 2. Forward, from up there. Still blocked means a real wall rather than a step, which is
        //    the check that keeps this from turning every wall into a staircase.
        Transform3D lifted = new Transform3D(start.Basis, start.Origin + lift);
        if (TestMove(lifted, advance))
        {
            return false;
        }

        // 3. Settle. Done by actually moving, because the landing surface's normal decides whether
        //    this was a step at all - dropping onto something steeper than FloorMaxAngle would
        //    leave him standing on a slope he could never have walked up.
        GlobalTransform = new Transform3D(lifted.Basis, lifted.Origin + advance);
        KinematicCollision3D? landing = MoveAndCollide(Vector3.Down * (StepHeight + StepSettleSlack));
        if (landing is null || landing.GetNormal().AngleTo(Vector3.Up) > FloorMaxAngle)
        {
            GlobalTransform = start;
            return false;
        }

        // 4. Permission. Checked LAST, after the geometry has already agreed this is a step, so the
        //    group only ever decides between "could climb" and "may climb" rather than standing in
        //    for the physics.
        if (!IsClimbable(landing.GetCollider() as Node))
        {
            GlobalTransform = start;
            return false;
        }

        // Recorded here rather than by the caller, because this method is the only thing that knows
        // how much height the teleport actually gained - and because a caller that forgets leaves
        // the camera popping. Only the vertical part is hidden: the forward probe is along the
        // direction of travel, where it reads as speed rather than a jolt.
        _stepSmoothing += GlobalPosition.Y - start.Origin.Y;
        return true;
    }

    /// <summary>
    /// Keeps the character on the stairs on the way DOWN, placing him on ground within
    /// <see cref="StepHeight"/> below instead of letting him fall off each tread.
    ///
    /// The other half of the step offset, and it turned out to be needed for a reason that had
    /// nothing to do with climbing. Walking down, the body left the floor on every riser - five
    /// separate bursts of 9 to 12 frames each - and since CheckForFall commits after 5, every step
    /// flipped the state to airborne and restarted the walk clip. Reported in play as the walk
    /// animation constantly restarting; the animation code was correct throughout, since it only
    /// replays on a CHANGE of clip and the clip genuinely kept changing.
    ///
    /// GODOT'S OWN FLOOR SNAP DOES NOT COVER THIS, which is worth recording because it looks like it
    /// should. floor_snap_length is 0.35 m against drops of 0.14 to 0.19 m, and it still let all five
    /// bursts happen; calling apply_floor_snap() by hand found ground too, but only after about five
    /// frames of falling, so it shortened the bursts without preventing one. This runs on the frame
    /// the floor is lost, which is the only moment that keeps the state from flipping at all.
    ///
    /// Deliberately NOT gated on <see cref="ClimbableGroup"/>, unlike the step up. Refusing to place
    /// him on an untagged surface would leave him falling down stairs he had just walked up, and
    /// keeping a character on ground he is already standing over takes no permission - it is not
    /// reaching anywhere he could not already go.
    /// </summary>
    public bool TryStepDown(bool wasOnFloor)
    {
        // wasOnFloor matters: without it this would catch the top of a genuine fall and stick him to
        // the first thing within StepHeight, cancelling drops the level means to be falls.
        if (!wasOnFloor || IsOnFloor() || IsJumping || IsFalling || Velocity.Y > 0.0f)
        {
            return false;
        }

        Transform3D start = GlobalTransform;

        // Forward FIRST, then down - the mirror of the step up, and necessary for the same reason.
        // Sweeping straight down from the lip lands on the EDGE between tread and riser, whose normal
        // measured 45.6 to 49.9 degrees; Godot calls that a wall, so placing him there left him
        // ungrounded and still sliding. Moving over the tread first means the sweep finds the flat.
        Vector3 forward = new Vector3(Velocity.X, 0.0f, Velocity.Z);
        if (forward.LengthSquared() > MinStepMotion * MinStepMotion)
        {
            Vector3 advance = forward.Normalized() * StepForwardProbe;
            if (!TestMove(start, advance))
            {
                GlobalTransform = new Transform3D(start.Basis, start.Origin + advance);
            }
        }

        KinematicCollision3D? landing = MoveAndCollide(Vector3.Down * (StepHeight + StepSettleSlack), false, 0.001f, false, 6);
        if (landing is null || !HasStandableContact(landing))
        {
            GlobalTransform = start;
            return false;
        }

        // Same treatment as the step up: the body moves now, the camera is shown it gradually. The
        // offset is signed, so a descent holds the camera high rather than low.
        _stepSmoothing += GlobalPosition.Y - start.Origin.Y;

        // Without this the fall speed built up on the way down keeps accumulating and the next frame
        // starts already moving, which re-opens the gap this just closed.
        Velocity = new Vector3(Velocity.X, 0.0f, Velocity.Z);
        return true;
    }

    /// <summary>
    /// Lets the camera catch up with a step the body has already taken. Public so
    /// tools/verify_stairs.gd drives the same code the game does.
    /// </summary>
    public void DrainStepSmoothing(double delta)
    {
        if (_cameraSmoothing is null)
        {
            return;
        }

        // Signed: a step up holds the camera low, a step down holds it high, and both decay toward
        // zero. Exponential, so the rate is proportional to what is left - see StepSmoothingHalfLife.
        if (_stepSmoothing != 0.0f)
        {
            if (StepSmoothingHalfLife > 0.0f)
            {
                _stepSmoothing *= Mathf.Pow(0.5f, (float)delta / StepSmoothingHalfLife);
            }
            else
            {
                _stepSmoothing = 0.0f;
            }

            // Exponential decay never actually arrives, so retire the last sliver rather than leave
            // the camera permanently a hair off and the offset being rewritten every frame forever.
            if (Mathf.Abs(_stepSmoothing) < StepSmoothingEpsilon)
            {
                _stepSmoothing = 0.0f;
            }
        }

        ApplyStepSmoothing();
    }

    /// <summary>
    /// Writes the current offset onto the camera pivot. Separate from the decay because the two run
    /// on different clocks: the offset CHANGES on a physics tick (a step is taken) and DECAYS on the
    /// render clock, so the write has to happen in both places or the camera reads a stale value.
    /// </summary>
    private void ApplyStepSmoothing()
    {
        if (_cameraSmoothing is null)
        {
            return;
        }

        Vector3 local = _cameraSmoothing.Position;
        local.Y = _cameraSmoothingBaseY - _stepSmoothing;
        _cameraSmoothing.Position = local;
    }

    /// <summary>
    /// Whether a downward sweep found something the character can come to rest on, for
    /// <see cref="TryStepDown"/>.
    ///
    /// Deliberately more permissive than FloorMaxAngle, and measured rather than guessed. Coming off
    /// a tread the capsule's round bottom lands on the EDGE between tread and riser, not on the flat,
    /// and an edge contact reports a normal tilted well off vertical - 45.6, 49.7 and 49.9 degrees at
    /// the three steps sampled, all just over the 45 degree floor limit. Judging those by
    /// FloorMaxAngle rejected every attempt: 292 calls, 0 accepted, and the descent kept flickering.
    ///
    /// The edge is a transient contact on the way to the tread below it, which is flat, so the right
    /// question is not "could he walk up this" but "is there something under him within a step". The
    /// tolerance below covers an edge contact while still refusing a genuine wall.
    /// </summary>
    private bool HasStandableContact(KinematicCollision3D collision)
    {
        for (int i = 0; i < collision.GetCollisionCount(); i++)
        {
            if (collision.GetNormal(i).AngleTo(Vector3.Up) <= Mathf.DegToRad(StepDownMaxAngleDegrees))
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>
    /// Whether a collided body is marked climbable, itself or via an ancestor.
    ///
    /// The ancestor walk is what makes tagging practical at either granularity: a single generated
    /// collision body can be tagged on its own, or a whole subtree covered by tagging its root in
    /// the scene file. Without it, only nodes that exist in a .tscn could ever be marked, and the
    /// level shell's collision bodies are built at load.
    /// </summary>
    public bool IsClimbable(Node? collider)
    {
        for (Node? node = collider; node is not null; node = node.GetParent())
        {
            if (node.IsInGroup(ClimbableGroup))
            {
                return true;
            }
        }

        return false;
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
