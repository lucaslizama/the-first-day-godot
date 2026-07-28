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

    private Node3D? _cameraBasis;

    public bool IsRunning { get; private set; }

    public bool IsJumping { get; private set; }

    public bool IsFalling { get; private set; }

    private bool _checkingForFall;
    private int _fallCheckTicks;

    public override void _Ready()
    {
        _cameraBasis = GetNodeOrNull<Node3D>(CameraBasisPath);

        if (_cameraBasis is null)
        {
            GD.PushWarning($"{Name}: CameraBasisPath '{CameraBasisPath}' did not resolve; movement will use world axes.");
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
        MoveAndSlide();
        CheckForFall();
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
