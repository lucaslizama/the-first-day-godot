using Godot;

namespace TheFirstDay.Gameplay;

/// <summary>
/// Port of Unity's GameManager.cs.
///
/// In the original this was a component on the level's Main Camera, not a
/// standalone manager: it drove a VignetteAndChromaticAberration image effect
/// sitting on the same object, and SoundAttenuationByDeath reached it through
/// Camera.main.GetComponent&lt;GameManager&gt;(). An autoload is the closer fit in
/// Godot, because the state it owns - the death count - outlives any one camera,
/// and the post-process is now a screen shader (see DeathDistortion) that reads
/// this rather than being reached into.
///
/// What the death count is for: dying raises it, reaching a new checkpoint
/// clears it, and everything derived from it makes the game feel worse the more
/// you die without progressing. The screen vignettes and smears, and the
/// coworkers' voices close in.
///
/// Wiring in nivelEscena, for reference:
///   CheckPointZone.onCheckPointCollision -> [InputManager.set_CanValidateInput(false),
///     Fortunato.Die(), player.set_parent(Temporal Target Parent),
///     GUIFadeEffect.FadeOut(), GameManager.SumarMuerte(), (a 6th SetActive call
///     with no target assigned - inert)]
///   Trigger Zone 1/2 .onTriggerEnter -> [CheckPointTeleport.SetCheckPoint(t),
///     GameManager.ResetDeaths()]
/// </summary>
public partial class GameManager : Node
{
    /// <summary>Death count at which the effects reach full strength.</summary>
    public const int MaxMeaningfulDeaths = 10;

    private const float ChromaticAberrationBase = 2.0f;
    private const float ChromaticAberrationRange = 8.0f;
    private const float VignetteIntensityBase = 0.1f;
    private const float VignetteIntensityRange = 0.3f;

    public static GameManager? Instance { get; private set; }

    /// <summary>Emitted when <see cref="Deaths"/> changes, with the new <see cref="DeathConstant"/>.</summary>
    [Signal]
    public delegate void DeathConstantChangedEventHandler(float deathConstant);

    /// <summary>
    /// Stands in for the onGameStart UnityEvent. Unity invoked it from the
    /// camera's Start, so it fires when the level begins, not when the process
    /// does - which is why this is a method rather than something in _Ready.
    /// </summary>
    [Signal]
    public delegate void GameStartedEventHandler();

    /// <summary>numeroMuertes in the original.</summary>
    public int Deaths { get; private set; }

    /// <summary>
    /// Deaths as a 0..1 ratio, clamped. Everything death-scaled derives from
    /// this: GetDeathConstant in the original.
    /// </summary>
    public float DeathConstant => Mathf.Clamp((float)Deaths / MaxMeaningfulDeaths, 0.0f, 1.0f);

    /// <summary>Value the original wrote into VignetteAndChromaticAberration.chromaticAberration.</summary>
    public float ChromaticAberration =>
        ChromaticAberrationBase + (ChromaticAberrationRange * DeathConstant);

    /// <summary>Value the original wrote into VignetteAndChromaticAberration.intensity.</summary>
    public float VignetteIntensity =>
        VignetteIntensityBase + (VignetteIntensityRange * DeathConstant);

    public override void _EnterTree()
    {
        Instance = this;
    }

    public override void _ExitTree()
    {
        if (Instance == this)
        {
            Instance = null;
        }
    }

    /// <summary>
    /// Begins a level: captures the mouse and announces the start. The original
    /// wired onGameStart to a single call, BloquearCursor on itself.
    /// </summary>
    public void StartGame()
    {
        CaptureMouse();
        EmitSignal(SignalName.GameStarted);
    }

    /// <summary>
    /// BloquearCursor in the original: Cursor.lockState = Locked, visible = false.
    ///
    /// Worth noting because it contradicts the camera port's comment about there
    /// being no cursor capture: the third-person camera's own CursorComponent was
    /// disabled, but the game locked the cursor here instead. Captured is the
    /// faithful behaviour.
    /// </summary>
    public void CaptureMouse()
    {
        Input.MouseMode = Input.MouseModeEnum.Captured;
    }

    public void ReleaseMouse()
    {
        Input.MouseMode = Input.MouseModeEnum.Visible;
    }

    /// <summary>SumarMuerte in the original.</summary>
    public void AddDeath()
    {
        Deaths++;
        EmitSignal(SignalName.DeathConstantChanged, DeathConstant);
    }

    public void ResetDeaths()
    {
        Deaths = 0;
        EmitSignal(SignalName.DeathConstantChanged, DeathConstant);
    }
}
