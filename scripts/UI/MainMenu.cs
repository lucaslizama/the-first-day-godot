using Godot;

namespace TheFirstDay.UI;

public partial class MainMenu : Control
{
    /// <summary>
    /// Unity's Start button called LoadScene(1), which was nivelEscena.unity in
    /// the build settings. This is that scene's Godot counterpart.
    /// </summary>
    [Export]
    public string LevelScenePath { get; set; } = "res://scenes/level.tscn";

    /// <summary>
    /// The credits, which Unity had no menu route to at all - they existed only as a panel inside the
    /// level, revealed when the player reached the finish line, so nobody who did not complete the
    /// game ever saw who made it. A DELIBERATE ADDITION, and the reason the credits are now a scene.
    /// </summary>
    [Export]
    public string CreditsScenePath { get; set; } = "res://scenes/credits.tscn";

    /// <summary>
    /// Inputs that count as "the player is reaching for the menu" and so arm the first button.
    ///
    /// Two families, because the two halves of the scheme live in different places. The arrow keys
    /// and the gamepad's d-pad and left stick arrive through Godot's built-in <c>ui_*</c> actions,
    /// which this project never redefines. W/A/S/D arrive through the project's own <c>move_*</c>
    /// actions - the level's movement bindings, which are also bound to the same sticks, so a stick
    /// push matches in both families and the first match wins.
    /// </summary>
    private static readonly string[] DirectionalActions =
    {
        "ui_up",
        "ui_down",
        "ui_left",
        "ui_right",
        "move_forward",
        "move_back",
        "move_left",
        "move_right",
    };

    private Button _startButton = null!;
    private Button _creditsButton = null!;
    private Button _exitButton = null!;
    private FadeOverlay _fade = null!;

    /// <summary>
    /// Where the fade is taking us. The overlay has one completion signal and there are now two
    /// destinations behind it, so the button records its choice and the one handler acts on it -
    /// rather than subscribing and unsubscribing a different handler per press, which leaks a
    /// connection the first time a player changes their mind.
    /// </summary>
    private string _pendingScenePath = string.Empty;

    public override void _Ready()
    {
        // The level captures the mouse, and the credits come back here, so without
        // this the menu would be unclickable on the second visit - the cursor would
        // still be captured from the run that just finished. Unity had the same shape:
        // BloquearCursor ran when a level began, and only the level ever locked it.
        Gameplay.GameManager.Instance?.ReleaseMouse();

        _startButton = GetNode<Button>("%StartButton");
        _creditsButton = GetNode<Button>("%CreditsButton");
        _exitButton = GetNode<Button>("%ExitButton");
        _fade = GetNode<FadeOverlay>("%FadeOverlay");

        _startButton.Pressed += OnStartPressed;
        _creditsButton.Pressed += OnCreditsPressed;
        _exitButton.Pressed += OnExitPressed;
        _fade.FadeOutCompleted += LoadPendingScene;

        // The level scene has not been ported yet.
        _startButton.Disabled = !ResourceLoader.Exists(LevelScenePath);

        if (_startButton.Disabled)
        {
            _startButton.TooltipText = "The level scene has not been ported yet.";
        }

        // NOTHING IS FOCUSED ON ENTRY, and that is the original's behaviour rather than a
        // preference: Main Menu.unity's EventSystem has m_FirstSelected: {fileID: 0}, i.e. null, so
        // Unity highlighted no button either. This used to call GrabFocus on Start - or on Exit when
        // Start was disabled - which drew the focus style over the button the moment the menu opened.
        //
        // WHAT THIS COSTS, AND WHY _Input BELOW EXISTS. An earlier version of this comment claimed
        // that Tab would still reach the menu because ui_focus_next focuses the first control when
        // nothing owns focus. IT DOES NOT. Godot's navigation walk starts FROM the focus owner -
        // Viewport::_gui_navigation_input bails when there is none - so with nothing focused, every
        // navigation key including Tab is inert, and the menu was reachable only with the mouse.
        // Measured: three Tab presses, focus owner NOTHING each time; the same probe moved focus
        // Start -> Exit correctly once something was focused, so it was the engine, not the probe.
        GetViewport().GuiReleaseFocus();
    }

    /// <summary>
    /// Arms the first button the moment the player reaches for the menu with a direction - arrows,
    /// W/A/S/D, d-pad or stick. This is what keeps "nothing focused on entry" from also meaning
    /// "unreachable without a mouse"; see the note in <see cref="_Ready"/> for why Tab cannot do it.
    /// </summary>
    public override void _Input(InputEvent @event)
    {
        // Something already has focus, so ordinary navigation applies and this must not drag focus
        // back to the first button - EXCEPT for W/A/S/D, which Godot will not navigate with at all.
        // See NavigateWithMoveKeys.
        if (GetViewport().GuiGetFocusOwner() is Control focused)
        {
            NavigateWithMoveKeys(@event, focused);
            return;
        }

        foreach (string action in DirectionalActions)
        {
            // Echoes are excluded by default, so holding a direction arms once rather than fighting
            // the navigation that follows.
            if (!@event.IsActionPressed(action))
            {
                continue;
            }

            // Start unless it is disabled - in which case Credits, the next thing that still works.
            // Falling through to Exit would arm "quit the game" as the menu's opening selection.
            Button first = _startButton.Disabled ? _creditsButton : _startButton;
            first.GrabFocus();

            // CONSUMED DELIBERATELY, so this press only arms the focus and does not also move it.
            // _Input runs BEFORE the viewport's GUI navigation, so without this the same ui_up or
            // ui_down would be processed again a moment later - now with a focus owner - and step
            // straight past the button just landed on. With two buttons that reads as the menu
            // opening on the wrong one.
            GetViewport().SetInputAsHandled();
            return;
        }
    }

    /// <summary>
    /// Moves focus for W/A/S/D, which Godot's own navigation will not do.
    ///
    /// THE ASYMMETRY THIS EXISTS TO CLOSE. Godot navigates on the <c>ui_*</c> actions, and their
    /// bindings are not what you would guess: <c>ui_down</c> is Down, d-pad down AND left stick Y+1,
    /// so the gamepad navigates a menu out of the box. W and S are bound only to this project's
    /// <c>move_*</c> actions, which the engine's GUI knows nothing about. The result was a menu where
    /// the first W armed a button and every W after it did nothing - arming worked, so it looked
    /// wired up, but WASD could never actually reach the second button.
    ///
    /// Only KEY events are handled here. The stick and d-pad match <c>move_*</c> too, but they are
    /// already on the <c>ui_*</c> actions and navigate correctly on their own; intercepting them
    /// would be re-implementing working engine behaviour for no gain.
    /// </summary>
    private void NavigateWithMoveKeys(InputEvent @event, Control focused)
    {
        if (@event is not InputEventKey)
        {
            return;
        }

        Side side;
        if (@event.IsActionPressed("move_forward"))
        {
            side = Side.Top;
        }
        else if (@event.IsActionPressed("move_back"))
        {
            side = Side.Bottom;
        }
        else if (@event.IsActionPressed("move_left"))
        {
            side = Side.Left;
        }
        else if (@event.IsActionPressed("move_right"))
        {
            side = Side.Right;
        }
        else
        {
            return;
        }

        // The same walk the arrow keys take, so the buttons' own focus neighbours stay the single
        // definition of the menu's layout - nothing here hard-codes Start above Exit.
        Control? next = focused.FindValidFocusNeighbor(side);
        if (next is null || next == focused)
        {
            // No neighbour that way - W at the top of the list, or any horizontal press in a column.
            // Left unhandled rather than swallowed, so it stays available to anything else.
            return;
        }

        next.GrabFocus();
        GetViewport().SetInputAsHandled();
    }

    private void OnStartPressed()
    {
        // Fade to black first; LoadPendingScene runs when the overlay is opaque.
        _pendingScenePath = LevelScenePath;
        _fade.FadeOut();
    }

    /// <summary>
    /// The credits leave through the same fade the level does, which is not only for consistency:
    /// the credits scene opens on solid black, so arriving already black makes the transition
    /// invisible rather than a cut.
    /// </summary>
    private void OnCreditsPressed()
    {
        _pendingScenePath = CreditsScenePath;
        _fade.FadeOut();
    }

    private void LoadPendingScene()
    {
        if (string.IsNullOrEmpty(_pendingScenePath))
        {
            return;
        }

        Error error = GetTree().ChangeSceneToFile(_pendingScenePath);
        if (error != Error.Ok)
        {
            GD.PushError($"Could not load '{_pendingScenePath}': {error}");
            _pendingScenePath = string.Empty;
            _fade.FadeIn();
        }
    }

    private void OnExitPressed()
    {
        GetTree().Quit();
    }
}
