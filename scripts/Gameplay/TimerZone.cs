using Godot;

namespace TheFirstDay.Gameplay;

/// <summary>
/// Port of TimerZone, the volume at the finish line that ends the game.
///
/// Unity's TimerZone is a generic two-event timer - onTriggerEnter fires at once,
/// onAfterDelay fires `delay` seconds later - and everything specific to the ending
/// lived in the UnityEvent wiring rather than in the script. That wiring is
/// reproduced here directly, the same choice RespawnChain made for the death chain,
/// because a faithful generic emitter plus an inspector-shaped event list would be
/// more machinery than the one instance justifies. The wiring, read out of
/// nivelEscena (delay: 5):
///
///   onTriggerEnter, immediately:
///     InputManager.set_CanValidateInput(false)
///     Fortunato.Cry()
///     GUIFadeEffect.SetOnFadeOutComplete(Event Container)
///     particleSys_conffeti.Play()
///   onAfterDelay, 5 s later:
///     GUIFadeEffect.FadeOut()
///
///   "Event Container" is a UnityEventContainer whose single event holds:
///     Credits panel.SetActive(true)
///     Credits.RollCredits()
///
/// So: cross the line, lose control, Fortunato cries, confetti fires; five seconds
/// later the screen fades to black, and only once it is fully black do the credits
/// appear and start rolling. Note the ordering - the fade's completion callback is
/// armed in the FIRST event, before FadeOut is ever called in the second. Arming it
/// after would be a race.
///
/// The UnityEventContainer indirection exists in Unity only because
/// SetOnFadeOutComplete takes a single UnityEvent object argument, so a list of
/// calls had to be boxed in a component to be passed. Here it is just the body of
/// OnFadeOutCompleted.
/// </summary>
public partial class TimerZone : Area3D
{
    /// <summary>Unity's `delay`, the gap between entering and the fade starting.</summary>
    [Export]
    public float Delay { get; set; } = 5.0f;

    [Export]
    public NodePath PlayerPath { get; set; } = new();

    [Export]
    public NodePath FadePath { get; set; } = new();

    /// <summary>
    /// The credits, which are a SCENE now rather than a hidden Label in this one.
    ///
    /// Unity's ending revealed a panel that was already sitting in the level - `Credits
    /// panel.SetActive(true)` - so the roll played over the level's own last frame. The credits are
    /// now `res://scenes/credits.tscn`, black-backed and rolling until the text clears the top, and
    /// the same scene is what the main menu's Credits button opens. One implementation, reached two
    /// ways, so the ending and the menu cannot drift apart.
    ///
    /// Everything BEFORE this point is unchanged and still Unity's: cross the line, lose control,
    /// Fortunato cries, confetti fires, five seconds later the fade starts, and the scene change
    /// happens only once the screen is fully black - which is also what makes the change invisible.
    /// </summary>
    [Export]
    public string CreditsScenePath { get; set; } = "res://scenes/credits.tscn";

    /// <summary>
    /// particleSys_conffeti. Optional: the confetti is not ported yet, so an unset or
    /// dangling path is not an error, it just means nothing fires. Wire it when the
    /// particle system lands.
    /// </summary>
    [Export]
    public NodePath ConfettiPath { get; set; } = new();

    private PlayerCharacter? _player;
    private UI.FadeOverlay? _fade;
    private GpuParticles3D? _confetti;
    private bool _triggered;

    public override void _Ready()
    {
        _player = GetNodeOrNull<PlayerCharacter>(PlayerPath);
        _fade = GetNodeOrNull<UI.FadeOverlay>(FadePath);
        _confetti = ConfettiPath.IsEmpty ? null : GetNodeOrNull<GpuParticles3D>(ConfettiPath);

        if (_player is null || _fade is null)
        {
            GD.PushError($"{Name}: PlayerPath and FadePath must both resolve; the ending will not run.");
            return;
        }

        BodyEntered += OnBodyEntered;
    }

    private void OnBodyEntered(Node3D body)
    {
        // Unity checked CompareTag("Player"); the group is this port's equivalent.
        if (_triggered || !body.IsInGroup("player"))
        {
            return;
        }

        // Unity had no guard, and did not need one: OnTriggerEnter only fires on
        // entry and the player loses control immediately, so it could not re-enter.
        // Keeping the guard because a body resting on the boundary can be reported
        // as entering more than once, which would stack a second five-second timer
        // and roll the credits twice.
        _triggered = true;

        GD.Print($"{Name}: player crossed the finish line; ending in {Delay:0.##} s.");

        // --- onTriggerEnter ---
        // InputManager is an autoload singleton here, as RespawnChain also assumes.
        if (PlayerInput.Instance is PlayerInput input)
        {
            input.CanValidateInput = false;
        }

        _player?.Cry();

        // Armed before FadeOut is called, as Unity's ordering does.
        _fade!.FadeOutCompleted += OnFadeOutCompleted;

        _confetti?.Restart();

        // --- onAfterDelay ---
        GetTree().CreateTimer(Delay).Timeout += () => _fade!.FadeOut();
    }

    /// <summary>
    /// The UnityEventContainer's event, which revealed the credits panel and rolled it. Here it is
    /// the scene change to the credits, made behind a fully black screen.
    /// </summary>
    private void OnFadeOutCompleted()
    {
        _fade!.FadeOutCompleted -= OnFadeOutCompleted;

        // An empty path means "stay put", so a harness driving the ending is not torn down mid-test.
        if (string.IsNullOrEmpty(CreditsScenePath))
        {
            GD.Print($"{Name}: ending complete; no CreditsScenePath set, staying on this scene.");
            return;
        }

        Error error = GetTree().ChangeSceneToFile(CreditsScenePath);
        if (error != Error.Ok)
        {
            GD.PushError($"{Name}: could not load '{CreditsScenePath}': {error}.");
        }
    }
}
