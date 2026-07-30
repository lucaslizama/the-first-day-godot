using Godot;

namespace TheFirstDay.UI;

/// <summary>
/// Port of Credits: scrolls the credits text upward for a fixed time, then returns to
/// the main menu.
///
/// Unity's routine, verbatim:
///
///     while (creditsTime > 0f) {
///         creditsTime -= Time.deltaTime;
///         self.anchoredPosition += Vector2.up * Time.deltaTime * scrollspeed;
///         yield return null;
///     }
///     onCreditsEnd.Invoke();
///
/// with scrollspeed 3 and creditsTime 10 on the instance in UI.prefab, and
/// onCreditsEnd wired to GoToMainMenu.
///
/// Note the two things this does NOT do, both faithful. It is a **timed** scroll, not
/// a scroll-until-offscreen: after creditsTime the text stops wherever it has reached,
/// which at 3 units/s for 10 s is only 30 units. That is a slow crawl rather than a
/// full roll, and it is what the original does - the numbers are the instance's, not
/// invented. And Unity's `creditsTime` is a serialised field decremented in place, so
/// a second call would fall straight through the loop and return to the menu at once;
/// that is preserved by not resetting it.
///
/// Godot's Y axis runs the other way from Unity's anchoredPosition: up on screen is
/// decreasing Position.Y here, increasing anchoredPosition.y there. Hence the
/// subtraction.
/// </summary>
public partial class Credits : Control
{
    [Export]
    public float ScrollSpeed { get; set; } = 3.0f;

    [Export]
    public float CreditsTime { get; set; } = 10.0f;

    [Export]
    public string MainMenuScenePath { get; set; } = "res://scenes/main_menu.tscn";

    private bool _rolling;

    public void RollCredits()
    {
        _rolling = true;
    }

    public override void _Process(double delta)
    {
        if (!_rolling)
        {
            return;
        }

        if (CreditsTime > 0.0f)
        {
            CreditsTime -= (float)delta;
            Position -= new Vector2(0.0f, ScrollSpeed * (float)delta);
            return;
        }

        _rolling = false;
        GoToMainMenu();
    }

    /// <summary>Credits.onCreditsEnd, wired in UI.prefab to the UI's GoToMainMenu.</summary>
    public void GoToMainMenu()
    {
        // An empty path means "stay put" rather than an error. Harness scenes that
        // drive the ending clear it so the tree is not torn down mid-test, and an
        // export left unset should not spam a resource failure either.
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
