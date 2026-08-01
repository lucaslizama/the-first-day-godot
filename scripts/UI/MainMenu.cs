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
    /// The options screen, ALSO A DELIBERATE ADDITION - the original had no settings of any kind.
    /// Instantiated at runtime rather than instanced in this scene, so the shipped menu file gains
    /// one button and nothing else: no new ext_resource, no uid for an editor save to invent.
    /// </summary>
    [Export]
    public string OptionsScenePath { get; set; } = "res://scenes/options_menu.tscn";

    private Button _startButton = null!;
    private Button _creditsButton = null!;
    private Button _optionsButton = null!;
    private Button _exitButton = null!;
    private FadeOverlay _fade = null!;
    private OptionsMenu? _options;
    private Control _menuArea = null!;

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
        _optionsButton = GetNode<Button>("%OptionsButton");
        _exitButton = GetNode<Button>("%ExitButton");
        _fade = GetNode<FadeOverlay>("%FadeOverlay");
        _menuArea = GetNode<Control>("MenuArea");

        _startButton.Pressed += OnStartPressed;
        _creditsButton.Pressed += OnCreditsPressed;
        _optionsButton.Pressed += OnOptionsPressed;
        _exitButton.Pressed += OnExitPressed;
        _fade.FadeOutCompleted += LoadPendingScene;

        MountOptionsMenu();

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
        // WHILE THE OPTIONS SCREEN IS OPEN THIS HANDLER MUST STAND DOWN COMPLETELY, and the reason is
        // specific rather than tidiness. The arming branch below grabs focus for %StartButton
        // whenever nothing owns focus, and FindValidFocusNeighbor searches the whole viewport
        // geometrically - neither knows that a panel is drawn on top. So a player who clicked empty
        // space in the options screen, pressed W and then Enter would start the game from inside the
        // options menu. Hiding MenuArea (see OnOptionsPressed) makes those buttons unfocusable, and
        // this makes the outcome independent of that too: two guards, because the failure is silent.
        if (_options is not null && _options.Visible)
        {
            return;
        }

        // Something already has focus, so ordinary navigation applies and this must not drag focus
        // back to the first button - EXCEPT for W/A/S/D, which Godot will not navigate with at all.
        // See NavigateWithMoveKeys.
        if (GetViewport().GuiGetFocusOwner() is Control focused)
        {
            MenuNavigation.TryNavigateWithMoveKeys(GetViewport(), @event, focused);
            return;
        }

        // Start unless it is disabled - in which case Credits, the next thing that still works.
        // Falling through to Exit would arm "quit the game" as the menu's opening selection.
        Button first = _startButton.Disabled ? _creditsButton : _startButton;
        MenuNavigation.TryArm(GetViewport(), @event, first);
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

    /// <summary>
    /// Loads the options scene and parks it, hidden, above this menu.
    ///
    /// A sibling of MainMenu under the CanvasLayer rather than a child of it, so the options screen
    /// draws over the whole menu including the title. That also puts it above this menu's
    /// FadeOverlay, which is harmless because the two are never visible together: the options screen
    /// is closed before any scene transition begins.
    /// </summary>
    private void MountOptionsMenu()
    {
        if (!ResourceLoader.Exists(OptionsScenePath))
        {
            _optionsButton.Disabled = true;
            _optionsButton.TooltipText = "The options scene is missing.";
            GD.PushWarning($"{Name}: '{OptionsScenePath}' does not exist; the Options button is disabled.");
            return;
        }

        if (ResourceLoader.Load<PackedScene>(OptionsScenePath) is not PackedScene packed
            || packed.Instantiate() is not OptionsMenu options)
        {
            _optionsButton.Disabled = true;
            GD.PushError($"{Name}: '{OptionsScenePath}' is not an OptionsMenu scene.");
            return;
        }

        _options = options;
        _options.Visible = false;
        _options.Closed += OnOptionsClosed;

        // DEFERRED, because a plain AddChild here fails outright: the CanvasLayer is still
        // instantiating its own children while this _Ready runs, and Godot refuses with "Parent node
        // is busy setting up children". It failed silently apart from that one line, leaving the
        // Options button enabled and wired to a screen that was never in the tree.
        //
        // The field is assigned before the deferred call, so the _Input guard is already live; the
        // node itself joins the tree next frame, hidden, which is a frame before any player could
        // press the button.
        GetParent().CallDeferred(Node.MethodName.AddChild, _options);
    }

    private void OnOptionsPressed()
    {
        if (_options is null)
        {
            return;
        }

        // Hidden Controls are skipped by the focus-neighbour walk, so nothing on the options screen
        // can reach Start, Credits or Exit while it is open. See the note in _Input.
        _menuArea.Visible = false;
        _options.Open(_optionsButton);
    }

    private void OnOptionsClosed()
    {
        _menuArea.Visible = true;
        _optionsButton.GrabFocus();
    }

    private void OnExitPressed()
    {
        // SceneTree.Quit does not deliver NotificationWMCloseRequest, and relying on teardown order
        // for a disk write is not worth the risk of losing a setting the player just changed.
        Utils.GameSettings.Instance?.FlushIfDirty();

        GetTree().Quit();
    }
}
