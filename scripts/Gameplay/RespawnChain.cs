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
///     3. Camera Target.parent = "Temporal Target Parent"   -> the camera stops following
///     4. UI.FadeOut()
///     5. GameManager.SumarMuerte()          -> AddDeath
///     6. SetActive on a null target         -> does nothing
///
///   UI.OnFadeOutComplete
///     1. Camera Target.SetParent(Camera Target Parent)     -> the camera follows again
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
/// Only one call has no counterpart: the dangling SetActive, whose target is null in
/// the scene, so it did nothing in Unity either.
///
/// CORRECTION. This file used to claim calls 3 and 1 above reparented THE PLAYER, to
/// undo ParentPlayer's moving-platform parenting, and dropped both as unnecessary since
/// this port carries the player with sync_to_physics. Both halves were wrong, and the
/// omission was visible in play - the camera kept following the corpse all the way down.
/// The reparented object is `Camera Target` (Fortunato.prefab fileID 4000011707492224),
/// not Fortunato, and detaching it is the deliberate death effect: see
/// DetachCameraTarget. That ResetLocalPosition exists at all should have been the tell -
/// zeroing a local position only means something if the node has just come back from
/// somewhere else.
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
        DetachCameraTarget();
        _fade?.FadeOut();
        GameManager.Instance?.AddDeath();
    }

    private void OnFadeOutCompleted()
    {
        // Reattach before anything else, matching the original's call order: the camera
        // must be following again before the teleport moves the player.
        AttachCameraTarget();

        // FadeIn next, as the original did: the fade back in overlaps the teleport
        // rather than waiting for it, and its own delay covers the jump.
        _fade?.FadeIn();

        if (_cameraTarget is not null)
        {
            _cameraTarget.Position = Vector3.Zero;
        }

        _player?.Revive();
        _killVolume?.TransportPlayer();
    }

    /// <summary>
    /// Cuts the camera loose from the player for the duration of the death.
    ///
    /// This is the effect the original was after, and it is deliberate: the camera holds
    /// still while the corpse keeps falling, so the player drops out of frame and you do
    /// not watch the landing. Mouse look still works, in the original and here, because
    /// the camera reads the mouse directly rather than through the input manager that
    /// death disables.
    ///
    /// Unity did it by reparenting: `Camera Target` was lifted out of Fortunato and
    /// parented to a static scene node called "Temporal Target Parent", then put back and
    /// zeroed on the fade. Since Unity's parent setter keeps world position, the target
    /// simply froze where it was. TopLevel is Godot's equivalent and needs no node outside
    /// the player - it makes CameraTarget ignore its parents and treat its own transform
    /// as global - so player.tscn stays self-contained. The observable behaviour is the
    /// same, which is what matters; the mechanism is not part of the port's contract.
    /// </summary>
    private void DetachCameraTarget()
    {
        if (_cameraTarget is null || _cameraTarget.TopLevel)
        {
            return;
        }

        // Assign the global transform back afterwards: with TopLevel set, `Transform` IS
        // the global transform, so without this the target would snap to wherever the
        // player-relative offset happens to point in world space.
        Transform3D frozen = _cameraTarget.GlobalTransform;
        _cameraTarget.TopLevel = true;
        _cameraTarget.GlobalTransform = frozen;
    }

    /// <summary>
    /// Hands the camera back to the player. The caller zeroes the local position
    /// afterwards, which is Unity's ResetLocalPosition and what actually re-centres it.
    /// </summary>
    private void AttachCameraTarget()
    {
        if (_cameraTarget is not null)
        {
            _cameraTarget.TopLevel = false;
        }
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
