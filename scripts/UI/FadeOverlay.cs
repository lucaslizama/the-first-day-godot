using Godot;

namespace TheFirstDay.UI;

/// <summary>
/// Port of Unity's GUIFadeEffect: a full-screen black overlay that fades the
/// view in (opaque to clear) or out (clear to opaque).
///
/// Speeds are alpha units per second, matching velocidadFadeIn/velocidadFadeOut.
/// As in the original, FadeOutDelay is waited *before* the fade and FadeInDelay
/// *after* it, and a fade already in progress swallows further requests.
/// </summary>
public partial class FadeOverlay : ColorRect
{
    [Signal]
    public delegate void FadeInCompletedEventHandler();

    [Signal]
    public delegate void FadeOutCompletedEventHandler();

    [Export]
    public float FadeInSpeed { get; set; } = 1.0f;

    [Export]
    public float FadeOutSpeed { get; set; } = 1.0f;

    [Export]
    public float FadeInDelay { get; set; }

    [Export]
    public float FadeOutDelay { get; set; }

    /// <summary>Start opaque and fade in, as GUIFadeEffect.Start() did.</summary>
    [Export]
    public bool FadeInOnReady { get; set; } = true;

    public bool Fading { get; private set; }

    private Tween? _tween;

    public override void _Ready()
    {
        // Never eat clicks meant for the menu underneath.
        MouseFilter = MouseFilterEnum.Ignore;

        if (FadeInOnReady)
        {
            SetAlpha(1.0f);
            FadeIn();
        }
    }

    public void FadeIn()
    {
        StartFade(0.0f, FadeInSpeed, FadeInDelay, delayFirst: false, SignalName.FadeInCompleted);
    }

    public void FadeOut()
    {
        StartFade(1.0f, FadeOutSpeed, FadeOutDelay, delayFirst: true, SignalName.FadeOutCompleted);
    }

    private void StartFade(float targetAlpha, float speed, float delay, bool delayFirst, StringName completedSignal)
    {
        if (Fading)
        {
            return;
        }

        Fading = true;
        Visible = true;

        _tween?.Kill();
        _tween = CreateTween();

        if (delayFirst && delay > 0.0f)
        {
            _tween.TweenInterval(delay);
        }

        float duration = speed > 0.0f ? Mathf.Abs(targetAlpha - Color.A) / speed : 0.0f;
        _tween.TweenProperty(this, "color:a", targetAlpha, duration);

        if (!delayFirst && delay > 0.0f)
        {
            _tween.TweenInterval(delay);
        }

        _tween.TweenCallback(Callable.From(() =>
        {
            Fading = false;
            // A fully transparent overlay still costs a draw call; hide it.
            Visible = targetAlpha > 0.0f;
            EmitSignal(completedSignal);
        }));
    }

    private void SetAlpha(float alpha)
    {
        Color color = Color;
        color.A = alpha;
        Color = color;
        Visible = alpha > 0.0f;
    }
}
