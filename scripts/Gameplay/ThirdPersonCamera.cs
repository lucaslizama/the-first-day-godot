using Godot;

namespace TheFirstDay.Gameplay;

/// <summary>
/// Port of the level's BasicCameraController (the AdvancedUtilities third-person
/// camera asset), reduced to the behaviour that is actually live in
/// nivelEscena.unity. Defaults below are that scene's serialised values.
///
/// Deliberately not ported, each verified inert in this level rather than assumed:
///   Zoom (scroll)  DesiredDistance = MinZoom = MaxZoom = 6, so scrolling cannot
///                  change the distance. The distance *smoothing* below is the
///                  live half of that component.
///   Cursor         Enabled = 0 on THIS component - but the cursor is still locked,
///                  by GameManager.BloquearCursor, which the scene wires to the
///                  manager's own onGameStart. So the camera asset does not capture
///                  the mouse and the game does. See _Ready.
///   ScreenShake    Enabled = 0.
///   AutoRotation   Enabled = 1, but nothing ever calls AutoRotate(), so
///                  UpdateAutoRotate() returns immediately every frame.
///   Headbob        Enabled = 1, but it only activates when the camera distance is
///                  ~0 (first person) or via ranged activation, which is off.
///                  Distance here is 6 with a floor of 2, so it never fires.
///   ThicknessChecking, rotation-degree events, horizontal limits: all disabled.
/// </summary>
public partial class ThirdPersonCamera : Camera3D
{
    private const float FloatTolerance = 0.0001f;

    /// <summary>
    /// Line-of-sight sampling points in camera space (right, up, forward), matching
    /// the scene's five-point plus pattern.
    /// </summary>
    private static readonly Vector3[] SamplingPoints =
    {
        new(0.0f, 0.0f, 0.0f),
        new(0.0f, 0.5f, 0.0f),
        new(0.0f, -0.5f, 0.0f),
        new(0.5f, 0.0f, 0.0f),
        new(-0.5f, 0.0f, 0.0f),
    };

    /// <summary>
    /// What the camera aims at. Exported as a NodePath and resolved in _Ready:
    /// typed node exports do not survive being written into the scene file here.
    /// </summary>
    [Export]
    public NodePath TargetPath { get; set; } = new();

    /// <summary>Excluded from line-of-sight rays, since they start inside the player.</summary>
    [Export]
    public NodePath IgnoreBodyPath { get; set; } = new();

    private Node3D? _target;
    private CollisionObject3D? _ignoreBody;

    [Export]
    public float DesiredDistance { get; set; } = 6.0f;

    /// <summary>Hard floor enforced even when geometry is closer (Zoom.MinimumDistance).</summary>
    [Export]
    public float MinimumDistance { get; set; } = 2.0f;

    [Export]
    public float InitialYawDegrees { get; set; } = 180.0f;

    /// <summary>Positive pitches the camera downward, as in the original.</summary>
    [Export]
    public float InitialPitchDegrees { get; set; } = 35.0f;

    [Export]
    public float PitchUpLimitDegrees { get; set; } = 60.0f;

    [Export]
    public float PitchDownLimitDegrees { get; set; } = -60.0f;

    [Export]
    public float SensitivityHorizontal { get; set; } = 2.0f;

    [Export]
    public float SensitivityVertical { get; set; } = 2.0f;

    /// <summary>
    /// Whether to flip the vertical look, relative to Godot's raw mouse axis.
    ///
    /// Unity's scene sets Invert.Vertical = 1, and this port copied that flag straight
    /// across - which double-inverted it, because the two engines' vertical mouse axes
    /// already run opposite ways: Unity's "Mouse Y" is positive when the mouse moves
    /// UP, Godot's InputEventMouseMotion.Relative.Y is positive when it moves DOWN.
    ///
    /// So Unity's flag existed to make the camera behave normally. In the asset,
    /// RotateVertically(degrees) does Rotate(CameraTransform.Right, degrees), where
    /// positive pitches the camera down; inverting the input therefore gave
    /// mouse-up = look-up. Copying the flag on top of Godot's already-flipped axis
    /// produced aeroplane controls instead, which is how it was reported.
    ///
    /// false here is the setting that reproduces the original's feel.
    /// </summary>
    [Export]
    public bool InvertVertical { get; set; }

    /// <summary>
    /// Unity's "Mouse X"/"Mouse Y" axes scaled raw pixel delta by 0.1 before the
    /// camera applied its own sensitivity, so the effective rate is 0.1 * 2
    /// degrees per pixel.
    /// </summary>
    [Export]
    public float MouseAxisScale { get; set; } = 0.1f;

    /// <summary>Seconds to ease back out to DesiredDistance once the view clears.</summary>
    [Export]
    public float ZoomOutSeconds { get; set; } = 0.6f;

    private float _yawDegrees;
    private float _pitchDegrees;
    private float _currentDistance;

    private Vector2 _pendingMouseDelta;

    private bool _zoomingOut;
    private double _zoomElapsed;
    private float _zoomStartDistance;

    public override void _Ready()
    {
        _target = GetNodeOrNull<Node3D>(TargetPath);
        _ignoreBody = GetNodeOrNull<CollisionObject3D>(IgnoreBodyPath);

        if (_target is null)
        {
            GD.PushError($"{Name}: TargetPath '{TargetPath}' did not resolve to a Node3D; the camera will not move.");
        }

        _yawDegrees = InitialYawDegrees;
        _pitchDegrees = InitialPitchDegrees;
        _currentDistance = DesiredDistance;

        // Unity's GameManager.Start invoked onGameStart, wired to BloquearCursor on
        // itself, which locked and hid the cursor. That manager was a scene object, so
        // its Start meant "a level began". Here GameManager is an autoload and its
        // _Ready fires when the *process* starts - before the main menu, whose buttons
        // need a cursor - so the call has to come from something level-scoped instead.
        //
        // This camera is that: exactly one per level, and the node the capture exists
        // for. Without this the mouse was never captured at all; StartGame had no
        // caller anywhere in the project.
        GameManager.Instance?.StartGame();

        UpdateCamera(0.0);
    }

    public override void _UnhandledInput(InputEvent @event)
    {
        // The original read mouse deltas unconditionally - no hold-to-rotate button.
        // The cursor IS locked, just not by this component; see the header and _Ready.
        if (@event is InputEventMouseMotion motion)
        {
            _pendingMouseDelta += motion.Relative;
        }
    }

    public override void _Process(double delta)
    {
        UpdateCamera(delta);
    }

    private void UpdateCamera(double delta)
    {
        if (_target is null)
        {
            return;
        }

        ApplyRotation();

        Vector3 target = _target.GlobalPosition;

        // Rotation must already be applied: the line-of-sight rays are cast along
        // the camera's own axes.
        float actual = _currentDistance;
        float furthest = Mathf.Max(DesiredDistance, actual);
        float calculated = CalculateMaximumDistance(target, furthest);
        float distance = ResolveDistance(actual, calculated, DesiredDistance, delta);

        GlobalPosition = target - (-GlobalBasis.Z * distance);
        _currentDistance = GlobalPosition.DistanceTo(target);
    }

    private void ApplyRotation()
    {
        float horizontalStep = MouseAxisScale * SensitivityHorizontal;
        float verticalStep = MouseAxisScale * SensitivityVertical;

        _yawDegrees -= _pendingMouseDelta.X * horizontalStep;

        float vertical = _pendingMouseDelta.Y * verticalStep;
        _pitchDegrees += InvertVertical ? -vertical : vertical;
        _pitchDegrees = Mathf.Clamp(_pitchDegrees, PitchDownLimitDegrees, PitchUpLimitDegrees);

        _pendingMouseDelta = Vector2.Zero;

        GlobalRotation = new Vector3(
            -Mathf.DegToRad(_pitchDegrees),
            Mathf.DegToRad(_yawDegrees),
            0.0f);
    }

    /// <summary>
    /// Casts a ray from each sampling point back toward the camera and returns the
    /// nearest obstruction, which caps how far out the camera may sit.
    /// </summary>
    private float CalculateMaximumDistance(Vector3 target, float furthestDistance)
    {
        PhysicsDirectSpaceState3D space = GetWorld3D().DirectSpaceState;

        Basis basis = GlobalBasis;
        Vector3 forward = -basis.Z;
        Vector3 right = basis.X;
        Vector3 up = basis.Y;
        Vector3 backTowardsCamera = basis.Z;

        float closest = furthestDistance;

        foreach (Vector3 sample in SamplingPoints)
        {
            Vector3 start = target
                + (right * sample.X)
                + (up * sample.Y)
                + (forward * sample.Z);

            float distanceToCheck = closest - sample.Z;
            if (distanceToCheck <= 0.0f)
            {
                continue;
            }

            var query = PhysicsRayQueryParameters3D.Create(
                start,
                start + (backTowardsCamera * distanceToCheck));

            if (_ignoreBody is not null)
            {
                query.Exclude = new Godot.Collections.Array<Rid> { _ignoreBody.GetRid() };
            }

            Godot.Collections.Dictionary hit = space.IntersectRay(query);
            if (hit.Count > 0)
            {
                closest = start.DistanceTo((Vector3)hit["position"]);
            }
        }

        return closest;
    }

    /// <summary>
    /// Snaps inward the instant something blocks the view, then eases back out over
    /// ZoomOutSeconds once there is room again. The original's zoom-*in* branch is
    /// unreachable here because DesiredDistance is also the maximum.
    /// </summary>
    private float ResolveDistance(float actual, float calculated, float desired, double delta)
    {
        // Something moved closer than we currently are: snap, no easing.
        if (actual - calculated > FloatTolerance)
        {
            _zoomingOut = false;
            return Mathf.Max(Mathf.Min(calculated, desired), MinimumDistance);
        }

        bool roomToGrow = calculated - actual > FloatTolerance;
        bool shortOfDesired = desired - actual > FloatTolerance;

        if (roomToGrow && shortOfDesired)
        {
            if (!_zoomingOut)
            {
                _zoomingOut = true;
                _zoomElapsed = 0.0;
                _zoomStartDistance = actual;
            }

            _zoomElapsed += delta;

            float t = ZoomOutSeconds > 0.0f
                ? Mathf.Clamp((float)(_zoomElapsed / ZoomOutSeconds), 0.0f, 1.0f)
                : 1.0f;

            float lerped = Mathf.Lerp(_zoomStartDistance, desired, t);
            if (t >= 1.0f)
            {
                _zoomingOut = false;
            }

            return Mathf.Max(Mathf.Min(lerped, calculated), MinimumDistance);
        }

        _zoomingOut = false;
        return Mathf.Max(Mathf.Min(calculated, desired), MinimumDistance);
    }
}
