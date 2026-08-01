using Godot;
using TheFirstDay.Gameplay;

namespace TheFirstDay.UI;

/// <summary>
/// Drives death_distortion.gdshader from the death count, replacing the
/// ApplyDeathEffects half of Unity's GameManager.Update.
///
/// Unity recomputed and wrote both values every frame. Doing it on the signal
/// instead is equivalent, not a shortcut: numeroMuertes only ever changes inside
/// SumarMuerte and ResetDeaths, so every other frame's write was identical to
/// the last.
///
/// Expects to be a full-rect ColorRect above the 3D view - a CanvasLayer child
/// works - with death_distortion.gdshader as its material.
/// </summary>
public partial class DeathDistortion : ColorRect
{
    private static readonly StringName VignetteIntensity = "vignette_intensity";
    private static readonly StringName ChromaticAberration = "chromatic_aberration";

    private ShaderMaterial? _shader;

    public override void _Ready()
    {
        _shader = Material as ShaderMaterial;
        if (_shader is null)
        {
            GD.PushError($"{Name}: needs a ShaderMaterial using death_distortion.gdshader; the effect is inert without one.");
            return;
        }

        GameManager? manager = GameManager.Instance;
        if (manager is null)
        {
            GD.PushWarning($"{Name}: GameManager autoload is missing; the distortion will stay at its resting values.");
            return;
        }

        manager.DeathConstantChanged += OnDeathConstantChanged;

        if (Utils.GameSettings.Instance is Utils.GameSettings settings)
        {
            settings.SectionChanged += OnSettingsSectionChanged;
        }

        Apply(manager);
    }

    public override void _ExitTree()
    {
        if (GameManager.Instance is GameManager manager)
        {
            manager.DeathConstantChanged -= OnDeathConstantChanged;
        }

        if (Utils.GameSettings.Instance is Utils.GameSettings settings)
        {
            settings.SectionChanged -= OnSettingsSectionChanged;
        }
    }

    private void OnSettingsSectionChanged(int section)
    {
        if (section == (int)Utils.GameSettings.Section.Game && GameManager.Instance is GameManager manager)
        {
            Apply(manager);
        }
    }

    private void OnDeathConstantChanged(float deathConstant)
    {
        if (GameManager.Instance is GameManager manager)
        {
            Apply(manager);
        }
    }

    /// <summary>
    /// Writes both uniforms, scaled by the player's screen-effects setting.
    ///
    /// THE SETTING SCALES THE DEATH-DRIVEN RANGE, NOT THE WHOLE VALUE. GameManager's curves are
    /// 2.0 + 8.0k and 0.1 + 0.3k; only the k terms are attenuated, so the screen keeps its resting
    /// look at every setting and merely stops escalating. At 1.0 - the default - the arithmetic
    /// collapses to the original two writes exactly, which is what lets verify_death_shader.gd and
    /// verify_death_effect.gd keep passing unchanged.
    ///
    /// Scaling the whole value instead would fade out the resting vignette too, which is part of
    /// how the level looks rather than part of the death feedback.
    /// </summary>
    private void Apply(GameManager manager)
    {
        float strength = Utils.GameSettings.Instance?.ScreenEffects ?? 1.0f;

        float vignette = GameManager.VignetteIntensityBase
            + ((manager.VignetteIntensity - GameManager.VignetteIntensityBase) * strength);
        float aberration = GameManager.ChromaticAberrationBase
            + ((manager.ChromaticAberration - GameManager.ChromaticAberrationBase) * strength);

        _shader?.SetShaderParameter(VignetteIntensity, vignette);
        _shader?.SetShaderParameter(ChromaticAberration, aberration);
    }
}
