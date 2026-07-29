using Godot;

namespace TheFirstDay.Gameplay;

/// <summary>
/// Port of Unity's CheckPointTeleport.cs, as an Area3D.
///
/// Two jobs, despite the single name: it is the death volume that fires when the
/// player falls into it, and it holds the checkpoint the player is sent back to.
/// The checkpoint is not fixed - Trigger Zone 1 and 2 call SetCheckpoint as the
/// player progresses, so the same volume returns you to a different place later
/// in the level.
///
/// Unity found the player with GameObject.FindGameObjectWithTag("Player") and
/// gated the trigger on the same tag. Godot has no tags, so this uses the
/// "player" group, with PlayerPath as an explicit override.
/// </summary>
public partial class CheckpointTeleport : Area3D
{
    /// <summary>Group standing in for Unity's "Player" tag.</summary>
    public const string PlayerGroup = "player";

    /// <summary>Emitted when the player enters, replacing the onCheckPointCollision UnityEvent.</summary>
    [Signal]
    public delegate void CheckpointCollisionEventHandler();

    /// <summary>Where <see cref="TransportPlayer"/> sends the player. Reassignable at runtime.</summary>
    [Export]
    public NodePath CheckpointPath { get; set; } = new();

    /// <summary>
    /// Optional explicit player reference. Left empty, the first node in the
    /// "player" group is used, matching the original's tag lookup.
    /// </summary>
    [Export]
    public NodePath PlayerPath { get; set; } = new();

    /// <summary>
    /// respawnDelay from the original, 2.0 in the CheckPointZone prefab. Carried
    /// over for parity only: the Unity script declared the field and never read
    /// it, so nothing here consumes it either. The actual delay came from the
    /// screen fade's duration.
    /// </summary>
    [Export]
    public float RespawnDelay { get; set; } = 2.0f;

    private Node3D? _checkpoint;
    private Node3D? _player;

    public override void _Ready()
    {
        _checkpoint = GetNodeOrNull<Node3D>(CheckpointPath);
        if (_checkpoint is null)
        {
            GD.PushWarning($"{Name}: CheckpointPath '{CheckpointPath}' did not resolve; TransportPlayer will do nothing until SetCheckpoint is called.");
        }

        BodyEntered += OnBodyEntered;
    }

    private Node3D? ResolvePlayer()
    {
        if (_player is not null && _player.IsInsideTree())
        {
            return _player;
        }

        if (!PlayerPath.IsEmpty)
        {
            _player = GetNodeOrNull<Node3D>(PlayerPath);
        }

        // Deliberately resolved lazily rather than in _Ready: the original looked
        // the player up in Awake, but here the volume can be ready before the
        // player is in the tree.
        _player ??= GetTree().GetFirstNodeInGroup(PlayerGroup) as Node3D;

        if (_player is null)
        {
            GD.PushError($"{Name}: no player found. Add the player to the '{PlayerGroup}' group or set PlayerPath.");
        }

        return _player;
    }

    private void OnBodyEntered(Node3D body)
    {
        if (body.IsInGroup(PlayerGroup) || body == ResolvePlayer())
        {
            EmitSignal(SignalName.CheckpointCollision);
        }
    }

    /// <summary>
    /// Moves the player to the checkpoint instantly. In the original this was
    /// called from the fade's completion callback, not from the collision, so the
    /// jump happens while the screen is black.
    /// </summary>
    public void TransportPlayer()
    {
        Node3D? player = ResolvePlayer();
        if (player is null || _checkpoint is null)
        {
            return;
        }

        player.GlobalPosition = _checkpoint.GlobalPosition;
    }

    public void SetCheckpoint(Node3D checkpoint)
    {
        _checkpoint = checkpoint;
    }
}
