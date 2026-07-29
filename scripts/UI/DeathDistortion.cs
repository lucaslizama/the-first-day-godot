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
        Apply(manager);
    }

    public override void _ExitTree()
    {
        if (GameManager.Instance is GameManager manager)
        {
            manager.DeathConstantChanged -= OnDeathConstantChanged;
        }
    }

    private void OnDeathConstantChanged(float deathConstant)
    {
        if (GameManager.Instance is GameManager manager)
        {
            Apply(manager);
        }
    }

    private void Apply(GameManager manager)
    {
        _shader?.SetShaderParameter(VignetteIntensity, manager.VignetteIntensity);
        _shader?.SetShaderParameter(ChromaticAberration, manager.ChromaticAberration);
    }
}
