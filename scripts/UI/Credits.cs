using Godot;

namespace TheFirstDay.UI;

/// <summary>
/// The credits roll, now a scene of its own (<c>res://scenes/credits.tscn</c>) rather than a hidden
/// Label inside the level: black screen, text rolling up from below the bottom edge until it clears
/// the top, then back to the main menu. Reached two ways - the level's ending, and the main menu's
/// Credits button - and there is exactly one of it, so the two cannot drift apart.
///
/// A DELIBERATE DIVERGENCE, requested rather than inferred. Unity's Credits was a **timed** scroll:
///
///     while (creditsTime > 0f) {
///         creditsTime -= Time.deltaTime;
///         self.anchoredPosition += Vector2.up * Time.deltaTime * scrollspeed;
///         yield return null;
///     }
///     onCreditsEnd.Invoke();
///
/// with scrollspeed 3 and creditsTime 10 on the instance in UI.prefab. That is 30 units of travel in
/// ten seconds - a text that twitches upward by a couple of lines over a level's ending and then
/// stops wherever it happens to be, on top of the level's own last frame. The original's numbers are
/// recorded in docs/level-port-scope.md and are NOT what this does any more.
///
/// What replaces them is distance-driven, not time-driven: the roll ends when the text has actually
/// left the screen, so adding a name lengthens the roll instead of truncating it. <see
/// cref="ScrollSpeed"/> is the only knob, and the geometry comes from the viewport at runtime.
/// </summary>
public partial class Credits : Control
{
    /// <summary>
    /// Roll speed in pixels per second, in the project's 1920x1080 canvas space.
    ///
    /// Not comparable to Unity's <c>scrollspeed</c> of 3, which was in a different unit over a
    /// different clock and only ever had to cover 30 of them. Chosen by measurement: at the time of
    /// writing the text was 2527 px tall, so the travel is 1080 + 2527 = 3607 px and this reads it
    /// out in about 26 s. 100 px/s was tried first and ran 36 s, which is a long time to hold a
    /// player who has just finished a jam game.
    ///
    /// Those figures date immediately, and that is the design working rather than a defect: the roll
    /// is distance-driven, so adding a name makes it LONGER instead of pushing the last name off the
    /// end. Adding the Godot-port block did exactly that, 2296 px to 2527. Re-time it if the list
    /// grows a lot; it is skippable either way.
    /// </summary>
    [Export]
    public float ScrollSpeed { get; set; } = 140.0f;

    /// <summary>
    /// How long after the scene opens before a press will skip, in seconds.
    ///
    /// Arriving here from the main menu's Credits button means the button was just pressed, and
    /// arriving from the ending means the player has been holding a direction. ChangeSceneToFile is
    /// deferred to the end of the frame, so the PRESS is consumed by the old scene and only a
    /// release can land here - which is already filtered out below - but a held key repeating, or a
    /// second impatient press, would otherwise skip the credits before a single line is legible.
    /// </summary>
    [Export]
    public float SkipGuardSeconds { get; set; } = 0.4f;

    [Export]
    public string MainMenuScenePath { get; set; } = "res://scenes/main_menu.tscn";

    [Export]
    public NodePath RollPath { get; set; } = new("Roll");

    private Label _roll = null!;
    private float _endY;
    private double _elapsed;
    private bool _finished;

    public override void _Ready()
    {
        _roll = GetNode<Label>(RollPath);
        LayOutRoll();
    }

    /// <summary>
    /// Places the text just below the bottom edge and works out where "gone" is.
    ///
    /// Both from the viewport rather than hard-coded: under the project's <c>canvas_items</c> stretch
    /// mode this rect is the 1920x1080 base size whatever the window is doing, so the roll is
    /// resolution-independent without any scaling maths of its own.
    /// </summary>
    private void LayOutRoll()
    {
        Vector2 view = GetViewportRect().Size;

        // Full width so the Label's own centring does the horizontal work; the height is whatever
        // the text needs, which is what makes the roll's length follow its content.
        float textHeight = _roll.GetMinimumSize().Y;
        _roll.Size = new Vector2(view.X, textHeight);
        _roll.Position = new Vector2(0.0f, view.Y);

        // Gone is the last line clearing the TOP edge, not the first line reaching it.
        _endY = -textHeight;
    }

    public override void _Process(double delta)
    {
        _elapsed += delta;

        if (_finished)
        {
            return;
        }

        Vector2 position = _roll.Position;
        position.Y -= ScrollSpeed * (float)delta;
        _roll.Position = position;

        if (position.Y <= _endY)
        {
            Finish();
        }
    }

    /// <summary>
    /// Any deliberate press cuts the roll short. Mouse MOTION is excluded on purpose - it is not an
    /// intent to skip, and a nudged mouse would otherwise end the credits.
    /// </summary>
    public override void _UnhandledInput(InputEvent @event)
    {
        if (_finished || _elapsed < SkipGuardSeconds)
        {
            return;
        }

        bool pressed = @event switch
        {
            InputEventKey key => key.Pressed && !key.Echo,
            InputEventMouseButton mouse => mouse.Pressed,
            InputEventJoypadButton pad => pad.Pressed,
            _ => false,
        };

        if (!pressed)
        {
            return;
        }

        GetViewport().SetInputAsHandled();
        Finish();
    }

    private void Finish()
    {
        if (_finished)
        {
            return;
        }

        _finished = true;
        GoToMainMenu();
    }

    /// <summary>Unity's Credits.onCreditsEnd, wired in UI.prefab to the UI's GoToMainMenu.</summary>
    public void GoToMainMenu()
    {
        // An empty path means "stay put" rather than an error. Harness scenes clear it so the tree is
        // not torn down mid-test, and an export left unset should not spam a resource failure either.
        if (string.IsNullOrEmpty(MainMenuScenePath))
        {
            GD.Print($"{Name}: credits finished; no MainMenuScenePath set, staying on this scene.");
            return;
        }

        Error error = GetTree().ChangeSceneToFile(MainMenuScenePath);
        if (error != Error.Ok)
        {
            GD.PushError($"{Name}: could not load '{MainMenuScenePath}': {error}.");
        }
    }
}
