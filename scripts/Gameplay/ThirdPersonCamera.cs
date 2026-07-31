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

    /// <summary>
    /// Fastest the camera may travel INWARD when geometry blocks the view, in metres per second.
    /// Set to 0 for the original behaviour, which was an unbounded snap in a single frame.
    ///
    /// A DELIBERATE ADDITION. The original snapped, and on the staircase that reads as the camera
    /// jumping: each tread the character climbs becomes the nearest occluder in turn, so the distance
    /// is rewritten step after step. Measured on the flight, with no respawn in the sample, the
    /// distance moved inward by up to 2.77 m in one tick and by more than 5 cm seven times.
    ///
    /// 20 m/s spreads a 3 m correction over about nine frames at 60 fps - fast enough to keep up with
    /// walking into a wall, slow enough not to register as a jolt.
    ///
    /// The cost of not snapping is that the camera can sit briefly further out than the obstruction
    /// allows, i.e. inside geometry. That is much cheaper here than it would normally be, because
    /// this project already fades surfaces within 1.8 m of the camera - see the proximity fade in
    /// docs/level-port-scope.md - so anything it passes through dissolves rather than filling the
    /// frame. If clipping ever does show, raise this rather than returning to a snap.
    /// </summary>
    [Export]
    public float ZoomInMetresPerSecond { get; set; } = 20.0f;

    /// <summary>
    /// Time for the camera's remaining distance to its pivot to halve, in seconds. 0 follows rigidly,
    /// which is what this did before.
    ///
    /// A DELIBERATE ADDITION, and the reason it is needed is a clock mismatch rather than a taste.
    /// The camera is NOT parented to the player - it is a sibling that writes its own GlobalPosition -
    /// but the follow was a rigid copy of the target's position, which behaves exactly like being
    /// parented. The target only moves on PHYSICS ticks, 60 times a second, while this runs in
    /// _Process once per rendered frame; so above 60 fps the camera reproduced each 60 Hz step
    /// verbatim, holding still for some frames and then moving. That is bumpiness no amount of
    /// step-offset smoothing can remove, because it is not about steps at all - it affects ordinary
    /// walking just as much.
    ///
    /// Only the PIVOT is eased, never the rotation. Mouse look still applies the same frame it is
    /// read, so aiming stays crisp; what lags slightly is the camera trailing the character's
    /// movement, which is what a third-person camera is supposed to do.
    ///
    /// 0.05 s spreads one 60 Hz step over roughly five frames at 144 fps. The steady-state cost is a
    /// constant trailing offset of about v * halfLife / ln2 - some 0.18 m at walk speed, along the
    /// direction of travel, where it reads as follow rather than as lag.
    /// </summary>
    [Export]
    public float FollowHalfLife { get; set; } = 0.05f;

    /// <summary>
    /// Metres of pivot movement in one frame that is treated as a teleport rather than motion, and so
    /// snapped instead of eased.
    ///
    /// Without this the respawn chain would send the camera gliding across the level from wherever the
    /// player died to the checkpoint, easing the whole way. A step is at most 0.3 m and a running
    /// frame is under 0.1 m, so 2 m cannot be reached by anything the character does on foot.
    /// </summary>
    [Export]
    public float FollowSnapDistance { get; set; } = 2.0f;

    private float _yawDegrees;
    private float _pitchDegrees;
    private float _currentDistance;

    /// <summary>The eased pivot the camera is placed from. See <see cref="FollowHalfLife"/>.</summary>
    private Vector3 _followPivot;
    private bool _hasFollowPivot;

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
        Vector3 pivot = FollowPivot(target, delta);

        // Rotation must already be applied: the line-of-sight rays are cast along
        // the camera's own axes.
        //
        // Cast from the TRUE target, not the eased pivot: what must stay visible is the character,
        // and the pivot trails him by a few centimetres.
        float actual = _currentDistance;
        float furthest = Mathf.Max(DesiredDistance, actual);
        float calculated = CalculateMaximumDistance(target, furthest);
        float distance = ResolveDistance(actual, calculated, DesiredDistance, delta);

        GlobalPosition = pivot - (-GlobalBasis.Z * distance);

        // Measured against the true target, so the distance the occlusion logic reasons about is the
        // distance to the character rather than to the pivot.
        _currentDistance = GlobalPosition.DistanceTo(target);
    }

    /// <summary>
    /// The eased position the camera is placed from, so a target that only moves on physics ticks does
    /// not arrive at the camera in 60 Hz steps. See <see cref="FollowHalfLife"/>.
    /// </summary>
    private Vector3 FollowPivot(Vector3 target, double delta)
    {
        if (!_hasFollowPivot)
        {
            _hasFollowPivot = true;
            _followPivot = target;
            return _followPivot;
        }

        // A teleport is not motion. Respawning would otherwise send the camera gliding across the
        // level from the place of death to the checkpoint.
        if (FollowHalfLife <= 0.0f
            || _followPivot.DistanceSquaredTo(target) > FollowSnapDistance * FollowSnapDistance)
        {
            _followPivot = target;
            return _followPivot;
        }

        float t = 1.0f - Mathf.Pow(0.5f, (float)delta / FollowHalfLife);
        _followPivot = _followPivot.Lerp(target, t);
        return _followPivot;
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
    /// Pulls inward when something blocks the view, then eases back out over ZoomOutSeconds once
    /// there is room again. The original's zoom-*in* branch is unreachable here because
    /// DesiredDistance is also the maximum.
    /// </summary>
    private float ResolveDistance(float actual, float calculated, float desired, double delta)
    {
        // Something is closer than we currently are. This used to snap with no easing at all, which
        // is the camera jump reported on the stairs: every tread the character climbs becomes the
        // nearest occluder in turn, so the view distance was being rewritten from scratch step after
        // step. Measured on the flight - with no respawn in the sample - the distance moved inward by
        // up to 2.77 m in a single tick, 7 times by more than 5 cm.
        //
        // Bounded instead of instant, at ZoomInMetresPerSecond. It still arrives; it just cannot do
        // the whole distance in one frame.
        if (actual - calculated > FloatTolerance)
        {
            _zoomingOut = false;
            float closest = Mathf.Max(Mathf.Min(calculated, desired), MinimumDistance);
            if (ZoomInMetresPerSecond <= 0.0f)
            {
                return closest;
            }

            // Never further out than we already are, and never past the obstruction.
            return Mathf.Max(closest, actual - (ZoomInMetresPerSecond * (float)delta));
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
