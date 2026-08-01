using Godot;

namespace TheFirstDay.UI;

/// <summary>
/// Port of PauseMenu. Escape toggles a translucent overlay with one button, which returns to the
/// main menu.
///
/// The button reads "Exit". Unity's said "Salir" - the original is in Spanish - so this is a
/// deliberate divergence, changed on request, not a translation the port inferred.
///
/// Unity's ToggleMenuPausa flipped four things independently:
///
///     menuPausa.SetActive(!menuPausa.activeInHierarchy);
///     Time.timeScale = Time.timeScale == 1f ? 0f : 1f;
///     Cursor.lockState = Cursor.lockState == CursorLockMode.Locked ? CursorLockMode.None : CursorLockMode.Locked;
///     Cursor.visible = Cursor.visible ? false : true;
///
/// Here all three consequences are derived from the panel's new visibility instead of
/// toggled separately. That is deliberate: four independent toggles can desynchronise -
/// anything else that touches the cursor or the time scale leaves them inconsistent, and
/// the original had no way back from that. Kept in lockstep, the behaviour is identical
/// as long as nothing else interferes, and correct when something does.
///
/// The `controller` field on Unity's component, a CamControllerFunctionAccess, is
/// **unassigned in the prefab** (fileID: 0) and never read by the script. Nothing to
/// port; that is also why CamControllerFunctionAccess itself has nothing calling it.
///
/// Godot's equivalent of timeScale = 0 is SceneTree.Paused, which is not quite the same
/// thing: a paused Godot node stops processing entirely, so this node and its panel must
/// be ProcessMode.Always or Escape would pause the game and then never be heard again.
/// That is set in the scene, and checked in _Ready rather than assumed.
/// </summary>
public partial class PauseMenu : Node
{
    /// <summary>The overlay Unity called menuPausa. Starts hidden, as it does there.</summary>
    [Export]
    public NodePath PanelPath { get; set; } = new();

    /// <summary>Unity's GoToMainMenu did LoadScene(0), the main menu.</summary>
    [Export]
    public string MainMenuScenePath { get; set; } = "res://scenes/main_menu.tscn";

    /// <summary>
    /// The options screen, a DELIBERATE ADDITION shared with the main menu so the two entry points
    /// cannot drift. Mounted from code rather than instanced in level.tscn: that keeps the most
    /// fragile file in the project free of another ext_resource, and makes ProcessMode.Always a
    /// guarantee here instead of a scene property an editor save could quietly drop.
    /// </summary>
    [Export]
    public string OptionsScenePath { get; set; } = "res://scenes/options_menu.tscn";

    private Control? _panel;
    private Button? _quitButton;
    private Button? _optionsButton;
    private Control? _buttons;
    private OptionsMenu? _options;

    /// <summary>
    /// Still derived from the panel's visibility, and the options screen is a CHILD of that panel -
    /// which is the whole reason it is parented there. Opening options therefore cannot change
    /// whether the game is paused, because the panel never stops being visible.
    /// </summary>
    public bool IsPaused => _panel is not null && _panel.Visible;

    public override void _Ready()
    {
        _panel = GetNodeOrNull<Control>(PanelPath);
        if (_panel is null)
        {
            GD.PushError($"{Name}: PanelPath '{PanelPath}' did not resolve; the game cannot be paused.");
            return;
        }

        _panel.Visible = false;

        // Without Always on both, pausing would stop the very nodes that un-pause.
        if (ProcessMode != ProcessModeEnum.Always || _panel.ProcessMode != ProcessModeEnum.Always)
        {
            GD.PushWarning($"{Name}: this node and its panel should both be ProcessMode.Always, or the pause cannot be lifted.");
        }

        _quitButton = _panel.GetNodeOrNull<Button>("%QuitButton");
        if (_quitButton is not null)
        {
            _quitButton.Pressed += GoToMainMenu;
        }
        else
        {
            GD.PushWarning($"{Name}: no %QuitButton under the panel; there is no way out of the pause menu.");
        }

        _buttons = _panel.GetNodeOrNull<Control>("Buttons");
        _optionsButton = _panel.GetNodeOrNull<Button>("%OptionsButton");
        if (_optionsButton is not null)
        {
            _optionsButton.Pressed += OnOptionsPressed;
            MountOptionsMenu();
        }
        else
        {
            GD.PushWarning($"{Name}: no %OptionsButton under the panel; the options screen is unreachable in game.");
        }
    }

    /// <summary>
    /// Arms the first button when the player reaches for the paused menu with a direction, and moves
    /// focus for W/A/S/D once something is focused - the same two halves the title screen has, and
    /// for the same reason: WASD is bound only to the <c>move_*</c> actions, which Godot's GUI knows
    /// nothing about, so without this W would arm a button and then do nothing at all.
    ///
    /// In <c>_Input</c> rather than <c>_UnhandledInput</c> because arming has to happen before the
    /// viewport's own GUI navigation, which is where <see cref="MenuNavigation.TryArm"/>'s consume
    /// matters. Everything is gated on the game actually being paused, so none of it can touch a
    /// direction the player pressed to move the character.
    /// </summary>
    public override void _Input(InputEvent @event)
    {
        if (!IsPaused)
        {
            return;
        }

        // The options screen owns the input while it is open; it has its own arming and navigation.
        if (_options is not null && _options.Visible)
        {
            return;
        }

        if (GetViewport().GuiGetFocusOwner() is Control focused)
        {
            MenuNavigation.TryNavigateWithMoveKeys(GetViewport(), @event, focused);
            return;
        }

        // Options unless it is disabled - in which case Exit, the only other thing here. Ordered so a
        // player who never touches the mouse does not land on "quit to menu" as their first option.
        Button? first = _optionsButton is not null && !_optionsButton.Disabled
            ? _optionsButton
            : _quitButton;

        if (first is not null)
        {
            MenuNavigation.TryArm(GetViewport(), @event, first);
        }
    }

    public override void _UnhandledInput(InputEvent @event)
    {
        // While the options screen is open it consumes `pause` itself, in _Input, which the engine
        // always runs before _UnhandledInput - so this should never see it. Checked anyway, because
        // the failure it prevents is the nastiest one available here: Escape would resume the game
        // and re-capture the mouse with the options panel still drawn over it.
        if (_options is not null && _options.Visible)
        {
            return;
        }

        if (@event.IsActionPressed("pause"))
        {
            Toggle();
            GetViewport().SetInputAsHandled();
        }
    }

    private void MountOptionsMenu()
    {
        if (_panel is null || !ResourceLoader.Exists(OptionsScenePath))
        {
            _optionsButton!.Disabled = true;
            GD.PushWarning($"{Name}: '{OptionsScenePath}' does not exist; the Options button is disabled.");
            return;
        }

        if (ResourceLoader.Load<PackedScene>(OptionsScenePath) is not PackedScene packed
            || packed.Instantiate() is not OptionsMenu options)
        {
            _optionsButton!.Disabled = true;
            GD.PushError($"{Name}: '{OptionsScenePath}' is not an OptionsMenu scene.");
            return;
        }

        _options = options;
        _options.Visible = false;

        // Set here rather than trusted from the scene file. Without Always the options screen would
        // be frozen the instant it opened, because it only ever opens while the tree is paused.
        _options.ProcessMode = ProcessModeEnum.Always;
        _options.Closed += OnOptionsClosed;

        // Deferred: the panel is still setting up its own children while this _Ready runs, and a
        // direct AddChild fails with "Parent node is busy setting up children" - one error line, and
        // then a wired button leading to a screen that is not in the tree.
        _panel.CallDeferred(Node.MethodName.AddChild, _options);
    }

    private void OnOptionsPressed()
    {
        if (_options is null)
        {
            return;
        }

        // Hidden Controls cannot take focus, so nothing on the options screen can walk onto Exit
        // behind it - which would let a player quit to the menu from inside the options.
        if (_buttons is not null)
        {
            _buttons.Visible = false;
        }

        _options.Open(_optionsButton);
    }

    private void OnOptionsClosed()
    {
        if (_buttons is not null)
        {
            _buttons.Visible = true;
        }

        // NO CaptureMouse HERE. Closing the options returns to the pause menu, which is unusable
        // without a cursor; Toggle is the only thing that should ever take it back.
        _optionsButton?.GrabFocus();
    }

    /// <summary>ToggleMenuPausa.</summary>
    public void Toggle()
    {
        if (_panel is null)
        {
            return;
        }

        bool paused = !_panel.Visible;
        _panel.Visible = paused;
        GetTree().Paused = paused;

        // Unity: lockState Locked <-> None with visibility flipped alongside. The button
        // is unusable without a cursor, and the camera is unusable with one.
        if (paused)
        {
            Gameplay.GameManager.Instance?.ReleaseMouse();

            if (_buttons is not null)
            {
                _buttons.Visible = true;
            }

            // NOTHING IS FOCUSED ON ENTRY, matching the title screen. Unity's ToggleMenuPausa
            // focused nothing either - it only flipped the panel active - and the main menu is
            // deliberately the same, because Main Menu.unity's EventSystem has m_FirstSelected null.
            // Having the pause panel open with a button already highlighted was the odd one out.
            //
            // What makes that safe rather than "unreachable without a mouse" is _Input below, which
            // arms the first button the moment the player pushes a direction. See MenuNavigation.
            GetViewport().GuiReleaseFocus();
        }
        else
        {
            // Resuming with the options screen still drawn would leave a panel over the game with
            // the mouse captured behind it. Reachable only by calling Toggle directly, since
            // _UnhandledInput refuses to while the options are open - so close it rather than
            // assume no caller ever will.
            if (_options is not null && _options.Visible)
            {
                _options.Close();
            }

            Gameplay.GameManager.Instance?.CaptureMouse();
        }
    }

    /// <summary>The exit button ("Salir" in Unity). Wired to this in the prefab.</summary>
    public void GoToMainMenu()
    {
        // Unpause first. SceneTree.Paused survives a scene change, so leaving it set
        // hands the main menu a frozen tree - its fade is a Tween and would never run.
        // Unity had the same latent problem, since Time.timeScale also persists across
        // LoadScene; it stayed invisible there because Unity's UI does not depend on the
        // time scale, and Godot's tweens do.
        GetTree().Paused = false;

        if (string.IsNullOrEmpty(MainMenuScenePath))
        {
            GD.Print($"{Name}: no MainMenuScenePath set; staying on this scene.");
            return;
        }

        Error error = GetTree().ChangeSceneToFile(MainMenuScenePath);
        if (error != Error.Ok)
        {
            GD.PushError($"{Name}: could not load '{MainMenuScenePath}': {error}.");
        }
    }
}
