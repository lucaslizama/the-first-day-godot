using Godot;

namespace TheFirstDay.UI;

/// <summary>
/// Port of PauseMenu. Escape toggles a translucent overlay with one button, "Salir",
/// which returns to the main menu.
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

    private Control? _panel;
    private Button? _quitButton;

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
    }

    public override void _UnhandledInput(InputEvent @event)
    {
        if (@event.IsActionPressed("pause"))
        {
            Toggle();
            GetViewport().SetInputAsHandled();
        }
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
            _quitButton?.GrabFocus();
        }
        else
        {
            Gameplay.GameManager.Instance?.CaptureMouse();
        }
    }

    /// <summary>The "Salir" button. Unity wired it to this in the prefab.</summary>
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
