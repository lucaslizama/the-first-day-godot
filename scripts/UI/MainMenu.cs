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
            _exitButton.GrabFocus();
        }
        else
        {
            _startButton.GrabFocus();
        }
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
