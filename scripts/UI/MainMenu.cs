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

    private Button _startButton = null!;
    private Button _exitButton = null!;
    private FadeOverlay _fade = null!;

    public override void _Ready()
    {
        // The level captures the mouse, and the credits come back here, so without
        // this the menu would be unclickable on the second visit - the cursor would
        // still be captured from the run that just finished. Unity had the same shape:
        // BloquearCursor ran when a level began, and only the level ever locked it.
        Gameplay.GameManager.Instance?.ReleaseMouse();

        _startButton = GetNode<Button>("%StartButton");
        _exitButton = GetNode<Button>("%ExitButton");
        _fade = GetNode<FadeOverlay>("%FadeOverlay");

        _startButton.Pressed += OnStartPressed;
        _exitButton.Pressed += OnExitPressed;
        _fade.FadeOutCompleted += LoadLevel;

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
        // Keyboard and gamepad still reach the menu: with no focus owner, ui_focus_next (Tab, and the
        // gamepad's mapped equivalent) focuses the first control in the container. Note that the ARROW
        // keys do not, because Control's focus_neighbour walk needs somewhere to start from - so the
        // first press has to be Tab. Unity had the same shape, sending navigation events with nothing
        // selected.
        GetViewport().GuiReleaseFocus();
    }

    private void OnStartPressed()
    {
        // Fade to black first; LoadLevel runs when the overlay is opaque.
        _fade.FadeOut();
    }

    private void LoadLevel()
    {
        Error error = GetTree().ChangeSceneToFile(LevelScenePath);
        if (error != Error.Ok)
        {
            GD.PushError($"Could not load '{LevelScenePath}': {error}");
            _fade.FadeIn();
        }
    }

    private void OnExitPressed()
    {
        GetTree().Quit();
    }
}
