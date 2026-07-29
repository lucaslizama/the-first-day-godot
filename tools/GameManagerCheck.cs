using Godot;
using TheFirstDay.Gameplay;

namespace TheFirstDay.Tools;

/// <summary>
/// Checks GameManager's death model against the formulas in Unity's
/// GameManager.cs, including the clamp above 10 deaths and the signal firing.
///
/// Written in C# rather than GDScript because C# property getters are not
/// exposed to GDScript's call(), so a script probe cannot read DeathConstant,
/// ChromaticAberration or VignetteIntensity.
///
///   godot-mono --headless --path . tools/gamemanager_check.tscn
/// </summary>
public partial class GameManagerCheck : Node
{
    private int _signalCount;

    public override void _Ready()
    {
        GameManager? manager = GameManager.Instance;
        if (manager is null)
        {
            GD.PrintErr("FAIL: GameManager autoload is not present.");
            GetTree().Quit(1);
            return;
        }

        manager.DeathConstantChanged += _ => _signalCount++;

        GD.Print("expected: k = clamp(deaths / 10, 0, 1), chroma = 2 + 8k, vignette = 0.1 + 0.3k");
        GD.Print("deaths     k       chroma    vignette   verdict");

        int failures = 0;
        int applied = 0;
        foreach (int target in new[] { 0, 1, 3, 5, 9, 10, 11, 25 })
        {
            while (applied < target)
            {
                manager.AddDeath();
                applied++;
            }

            float expectedK = Mathf.Min(target / 10.0f, 1.0f);
            bool ok = manager.Deaths == target
                && Mathf.IsEqualApprox(manager.DeathConstant, expectedK)
                && Mathf.IsEqualApprox(manager.ChromaticAberration, 2.0f + (8.0f * expectedK))
                && Mathf.IsEqualApprox(manager.VignetteIntensity, 0.1f + (0.3f * expectedK));

            if (!ok)
            {
                failures++;
            }

            GD.Print($"  {manager.Deaths,3}   {manager.DeathConstant,6:F4}   {manager.ChromaticAberration,7:F3}   {manager.VignetteIntensity,7:F4}   {(ok ? "ok" : "MISMATCH")}");
        }

        manager.ResetDeaths();
        bool resetOk = manager.Deaths == 0
            && Mathf.IsEqualApprox(manager.DeathConstant, 0.0f)
            && Mathf.IsEqualApprox(manager.ChromaticAberration, 2.0f)
            && Mathf.IsEqualApprox(manager.VignetteIntensity, 0.1f);
        GD.Print($"after ResetDeaths: deaths={manager.Deaths} k={manager.DeathConstant:F4} chroma={manager.ChromaticAberration:F3} vignette={manager.VignetteIntensity:F4}   {(resetOk ? "ok" : "MISMATCH")}");
        if (!resetOk)
        {
            failures++;
        }

        // 25 AddDeath calls plus the one ResetDeaths.
        bool signalsOk = _signalCount == 26;
        GD.Print($"DeathConstantChanged fired {_signalCount} times (expected 26)   {(signalsOk ? "ok" : "MISMATCH")}");
        if (!signalsOk)
        {
            failures++;
        }

        GD.Print(failures == 0 ? "ALL CHECKS PASSED" : $"{failures} CHECK(S) FAILED");
        GetTree().Quit(failures == 0 ? 0 : 1);
    }
}
