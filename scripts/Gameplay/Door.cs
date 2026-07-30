using Godot;

namespace TheFirstDay.Gameplay;

/// <summary>
/// Port of Door, on puertaInicio - the door at the level's entrance.
///
/// Unity's whole script is one line in OnTriggerEnter:
///
///     anim.SetTrigger("Open");
///
/// and note what is NOT there: **no tag check**. TimerZone tests
/// CompareTag("Player"), this does not, so in the original anything entering the volume
/// opens the door. Reproduced as-is rather than tightened, since in practice only the
/// player can reach it and narrowing it would be a silent behaviour change.
///
/// The animator behind it has one trigger, `Open`, a default state with **no clip** - the
/// closed door is just the rest pose, not an animation - and a single transition to
/// `puertaAbrir` with no way back. So the door opens once and stays open, which is why
/// this fires once and then stops listening.
/// </summary>
public partial class Door : Node3D
{
    /// <summary>The trigger volume. Unity added a BoxCollider with isTrigger on the root.</summary>
    [Export]
    public NodePath TriggerPath { get; set; } = new();

    [Export]
    public NodePath AnimationPlayerPath { get; set; } = new();

    /// <summary>The clip the animator's `puertaAbrir` state plays.</summary>
    [Export]
    public string OpenAnimation { get; set; } = "puertaAbrir";

    private AnimationPlayer? _animation;
    private Area3D? _trigger;

    public bool IsOpen { get; private set; }

    public override void _Ready()
    {
        _animation = GetNodeOrNull<AnimationPlayer>(AnimationPlayerPath);
        _trigger = GetNodeOrNull<Area3D>(TriggerPath);

        if (_animation is null || _trigger is null)
        {
            GD.PushError($"{Name}: AnimationPlayerPath and TriggerPath must both resolve; the door cannot open.");
            return;
        }

        if (!_animation.HasAnimation(OpenAnimation))
        {
            GD.PushError($"{Name}: no '{OpenAnimation}' animation; the door has nothing to play.");
            return;
        }

        _trigger.BodyEntered += OnBodyEntered;
    }

    private void OnBodyEntered(Node3D body)
    {
        // Unity's animator had no transition out of puertaAbrir, so a second trigger
        // would restart the clip and slam the door shut before reopening it. Guarded.
        if (IsOpen)
        {
            return;
        }

        IsOpen = true;
        _animation!.Play(OpenAnimation);
        GD.Print($"{Name}: opened by {body.Name}.");
    }
}
