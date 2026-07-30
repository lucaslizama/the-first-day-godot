using Godot;
using TheFirstDay.UI;

namespace TheFirstDay.Gameplay;

/// <summary>
/// The death-and-respawn sequence, and the checkpoint gates that feed it.
///
/// In Unity none of this was code. It was a UnityEvent graph spread across three
/// prefabs - CheckPointZone fired six calls, the UI's fade fired five more when it
/// finished, and three more when it faded back in - with every target and half the
/// method names stored as prefab-instance overrides in the scene. That is why the
/// GameManager port left the chain open: the wiring is not visible in the scripts,
/// and it does not survive a naive read of the scene either.
///
/// Recovered from the overrides, the graph is:
///
///   CheckPointZone.onCheckPointCollision  (player enters the kill volume)
///     1. InputManager.CanValidateInput = false
///     2. Fortunato.Die()
///     3. Fortunato.transform.parent = "Temporal Target Parent"
///     4. UI.FadeOut()
///     5. GameManager.SumarMuerte()          -> AddDeath
///     6. SetActive on a null target         -> does nothing
///
///   UI.OnFadeOutComplete
///     1. Fortunato.transform.SetParent(null)
///     2. UI.FadeIn()
///     3. Camera Target.ResetPosition()
///     4. Fortunato.Revive()
///     5. CheckPointTeleport.TransportPlayer()
///
///   UI.OnFadeInComplete
///     1. InputManager.CanValidateInput = true
///     2. UI.SetFadeInSpeed(2)
///     3. UI.SetFadeInDelay(0.5)
///
/// Reproduced here in that order, because order is behaviour: the teleport happens
/// while the screen is black and after Revive has cleared the fall speed, and the
/// fade-in is already running by then.
///
/// Three calls have no counterpart, all for the same reason. Calls 3 and 1 of the
/// first two lists parked the player under a fixed node and then unparented it,
/// which existed to undo ParentPlayer's moving-platform parenting; this port carries
/// the player with sync_to_physics instead and never reparents it, so there is
/// nothing to undo. The dangling SetActive did nothing in Unity either - its target
/// is null in the scene.
///
/// The timings are the fade's, not respawnDelay: 1 s of fadeOutDelay, then 2 s to
/// black at 0.5 alpha/s, then the teleport, then a 1 s delay and 0.667 s back at
/// 1.5 alpha/s. After the first fade-in completes the last two calls speed all
/// later ones up to a 0.5 s delay and 0.5 s fade. respawnDelay itself is 2 in the
/// prefab and read by nothing.
///
/// The two Trigger Zones are here too. Unity's TriggerZone.cs is a generic
/// enter/exit/stay UnityEvent emitter, but both instances in the level do the same
/// two things - move the checkpoint on and reset the death count - so they are
/// wired directly rather than reproduced as a general mechanism. If the Timer Zone
/// needs the generic version later, that is the point to build it.
/// </summary>
public partial class RespawnChain : Node
{
    [Export]
    public NodePath KillVolumePath { get; set; } = new();

    [Export]
    public NodePath FadePath { get; set; } = new();

    [Export]
    public NodePath PlayerPath { get; set; } = new();

    /// <summary>
    /// Camera Target in the original, the node ResetLocalPosition sat on. Reset to its
    /// own origin after the teleport so the camera does not swing in from wherever it
    /// was trailing when the player died.
    /// </summary>
    [Export]
    public NodePath CameraTargetPath { get; set; } = new();

    /// <summary>First Trigger Zone, and the checkpoint it hands to the kill volume.</summary>
    [Export]
    public NodePath FirstZonePath { get; set; } = new();

    [Export]
    public NodePath FirstZoneCheckpointPath { get; set; } = new();

    [Export]
    public NodePath SecondZonePath { get; set; } = new();

    [Export]
    public NodePath SecondZoneCheckpointPath { get; set; } = new();

    /// <summary>SetFadeInSpeed's argument on OnFadeInComplete.</summary>
    [Export]
    public float LaterFadeInSpeed { get; set; } = 2.0f;

    /// <summary>SetFadeInDelay's argument on OnFadeInComplete.</summary>
    [Export]
    public float LaterFadeInDelay { get; set; } = 0.5f;

    private CheckpointTeleport? _killVolume;
    private FadeOverlay? _fade;
    private PlayerCharacter? _player;
    private Node3D? _cameraTarget;

    public override void _Ready()
    {
        _killVolume = GetNodeOrNull<CheckpointTeleport>(KillVolumePath);
        _fade = GetNodeOrNull<FadeOverlay>(FadePath);
        _player = GetNodeOrNull<PlayerCharacter>(PlayerPath);
        _cameraTarget = GetNodeOrNull<Node3D>(CameraTargetPath);

        if (_killVolume is null || _fade is null || _player is null)
        {
            GD.PushError($"{Name}: needs KillVolumePath, FadePath and PlayerPath to resolve; the player cannot respawn without all three.");
            return;
        }

        _killVolume.CheckpointCollision += OnDeath;
        _fade.FadeOutCompleted += OnFadeOutCompleted;
        _fade.FadeInCompleted += OnFadeInCompleted;

        WireZone(FirstZonePath, FirstZoneCheckpointPath);
        WireZone(SecondZonePath, SecondZoneCheckpointPath);
    }

    public override void _ExitTree()
    {
        if (_killVolume is not null)
        {
            _killVolume.CheckpointCollision -= OnDeath;
        }

        if (_fade is not null)
        {
            _fade.FadeOutCompleted -= OnFadeOutCompleted;
            _fade.FadeInCompleted -= OnFadeInCompleted;
        }
    }

    /// <summary>
    /// A Trigger Zone: on entry it moves the kill volume's checkpoint forward and
    /// resets the death count, so progress both saves and calms the effects down.
    /// </summary>
    private void WireZone(NodePath zonePath, NodePath checkpointPath)
    {
        var zone = GetNodeOrNull<Area3D>(zonePath);
        var checkpoint = GetNodeOrNull<Node3D>(checkpointPath);
        if (zone is null)
        {
            return;
        }

        if (checkpoint is null)
        {
            GD.PushWarning($"{Name}: zone '{zonePath}' has no checkpoint at '{checkpointPath}'; entering it would move the respawn point to nothing.");
            return;
        }

        zone.BodyEntered += body =>
        {
            if (body is not PlayerCharacter && !body.IsInGroup(CheckpointTeleport.PlayerGroup))
            {
                return;
            }

            _killVolume?.SetCheckpoint(checkpoint);
            GameManager.Instance?.ResetDeaths();
        };
    }

    private void OnDeath()
    {
        if (_player is null || _player.IsDead)
        {
            return;
        }

        if (PlayerInput.Instance is PlayerInput input)
        {
            input.CanValidateInput = false;
        }

        _player.Die();
        _fade?.FadeOut();
        GameManager.Instance?.AddDeath();
    }

    private void OnFadeOutCompleted()
    {
        // FadeIn first, as the original did: the fade back in overlaps the teleport
        // rather than waiting for it, and its own delay covers the jump.
        _fade?.FadeIn();

        if (_cameraTarget is not null)
        {
            _cameraTarget.Position = Vector3.Zero;
        }

        _player?.Revive();
        _killVolume?.TransportPlayer();
    }

    private void OnFadeInCompleted()
    {
        if (PlayerInput.Instance is PlayerInput input)
        {
            input.CanValidateInput = true;
        }

        if (_fade is not null)
        {
            _fade.FadeInSpeed = LaterFadeInSpeed;
            _fade.FadeInDelay = LaterFadeInDelay;
        }
    }
}
