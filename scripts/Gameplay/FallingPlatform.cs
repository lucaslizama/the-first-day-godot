using Godot;

namespace TheFirstDay.Gameplay;

/// <summary>
/// Port of Unity's FallingPlatform.cs - 8 instances in nivelEscena, forming the
/// collapsing walkway between z = -45 and z = -61.
///
/// The player steps on it, it hangs for <see cref="FallDelay"/>, then sinks at a
/// constant <see cref="FallSpeed"/> until it has travelled
/// <see cref="ResetDistance"/>, at which point it snaps back and arms again.
///
/// Three notes on the original.
///
/// The Unity script lived on the trigger child and moved the root through a
/// serialised Transform reference, and the root carried both the mesh collider and
/// the trigger. Here the script is on the body it moves, with the trigger as its
/// child, so the trigger still sinks with the platform.
///
/// It has to be an AnimatableBody3D rather than a plain Node3D above one: with
/// sync_to_physics enabled - which is what carries the player, in place of
/// ParentPlayer - the body writes its own transform back from the physics server
/// every tick, so moving a parent node moves the mesh and the trigger while the
/// collision body stays exactly where it was. The player then stands on a collider
/// hanging in mid-air while the platform visibly descends beneath them. Measured,
/// not guessed: see tools/verify_platforms.gd, which fails on precisely that.
///
/// Its coroutine ran on rendered frames (Time.deltaTime, yield return null); this
/// runs in _PhysicsProcess, as PlayerCharacter does. The descent is distance
/// driven in both, so the motion is frame-rate independent either way and the
/// timings match.
///
/// The reset is a deliberate divergence. Unity captured platform.position - a
/// world position - in Awake, then restored it with platform.localPosition. Every
/// instance sits under a container called Obstaculos at (-0.2, 0, 0), so the two
/// differ, and each platform reappeared 20 cm to the -x of where it started, once,
/// on its first cycle. That is a bug, not a design: nothing else in the level
/// shifts sideways, and the offset is exactly the container's. This port stores
/// the rest position in the space it assigns back to, so the platform returns to
/// where it was.
/// </summary>
public partial class FallingPlatform : AnimatableBody3D
{
    /// <summary>velocidadCaida, 2 in the prefab. Metres per second.</summary>
    [Export]
    public float FallSpeed { get; set; } = 2.0f;

    /// <summary>delayCaida, 0.5 in the prefab. Grace period between the step and the drop.</summary>
    [Export]
    public float FallDelay { get; set; } = 0.5f;

    /// <summary>
    /// distanciaDesactivacion, 10 in the prefab. Despite the name, nothing is
    /// deactivated: it is the distance after which the platform snaps back.
    /// </summary>
    [Export]
    public float ResetDistance { get; set; } = 10.0f;

    /// <summary>The volume that arms the fall, standing in for the OnTriggerEnter.</summary>
    [Export]
    public NodePath TriggerPath { get; set; } = new("Trigger");

    private Vector3 _restPosition;
    private float _waited;
    private float _fallen;

    /// <summary>True from the moment it is triggered until it has snapped back.</summary>
    public bool IsFalling { get; private set; }

    public override void _Ready()
    {
        _restPosition = Position;

        var trigger = GetNodeOrNull<Area3D>(TriggerPath);
        if (trigger is null)
        {
            GD.PushError($"{Name}: TriggerPath '{TriggerPath}' did not resolve to an Area3D; this platform will never fall.");
            return;
        }

        trigger.BodyEntered += OnBodyEntered;
    }

    private void OnBodyEntered(Node3D body)
    {
        // Unity gated this on the "Player" tag. Godot has no tags: the group is the
        // convention CheckpointTeleport already established, and the type check
        // covers a player that has not been put in the group.
        if (body is PlayerCharacter || body.IsInGroup(CheckpointTeleport.PlayerGroup))
        {
            Fall();
        }
    }

    /// <summary>
    /// Starts the fall. Public because the original was: a UnityEvent could drop a
    /// platform without anyone standing on it.
    /// </summary>
    public void Fall()
    {
        if (IsFalling)
        {
            return;
        }

        IsFalling = true;
        _waited = 0.0f;
        _fallen = 0.0f;
    }

    public override void _PhysicsProcess(double delta)
    {
        if (!IsFalling)
        {
            return;
        }

        if (_waited < FallDelay)
        {
            _waited += (float)delta;
            return;
        }

        float step = FallSpeed * (float)delta;
        _fallen += step;

        // Unity translated in Space.Self, so down means the platform's own -Y, not
        // the world's. Basis.Y is that axis expressed in the parent's space, which
        // is the space Position lives in. None of the eight instances is rotated,
        // so this only matters if one ever is.
        Position -= Basis.Y * step;

        if (_fallen >= ResetDistance)
        {
            Position = _restPosition;
            IsFalling = false;
        }
    }
}
