using Godot;

namespace TheFirstDay.UI;

public partial class MainMenu : Control
{
    [Export]
    public string LevelScenePath { get; set; } = "res://scenes/level.tscn";

    private Button _playButton = null!;
    private Button _quitButton = null!;

    public override void _Ready()
    {
        _playButton = GetNode<Button>("%PlayButton");
        _quitButton = GetNode<Button>("%QuitButton");

        _playButton.Pressed += OnPlayPressed;
        _quitButton.Pressed += OnQuitPressed;

        // The level scene has not been ported yet.
        _playButton.Disabled = !ResourceLoader.Exists(LevelScenePath);

        _playButton.GrabFocus();
    }

    private void OnPlayPressed()
    {
        Error error = GetTree().ChangeSceneToFile(LevelScenePath);
        if (error != Error.Ok)
        {
            GD.PushError($"Could not load '{LevelScenePath}': {error}");
        }
    }

    private void OnQuitPressed()
    {
        GetTree().Quit();
    }
}
