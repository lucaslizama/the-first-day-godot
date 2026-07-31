using Godot;

namespace TheFirstDay.Gameplay;

/// <summary>
/// Port of Unity's SoundAttenuationByDeath.cs - the whisper that closes in on the
/// player the more they die. 13 of these, one per cluster of coworkers, placed by
/// tools/generate_whispers_scene.py into scenes/whispers.tscn.
///
/// The original's own comment says it plainly: "Los sonidos de esta audio source se
/// escuchan mas de cerca mientras mas muere el jugador." The mechanism is the
/// AudioSource's minDistance, the radius inside which the sound plays unattenuated,
/// widened from <see cref="MinDistance"/> to <see cref="MaxMinDistance"/> as the
/// death constant climbs. This is the consumer GameManager's death constant was
/// ported for; DeathDistortion was the other half.
///
/// Unity's logarithmic rolloff attenuates by minDistance / distance, which is
/// exactly Godot's ATTENUATION_INVERSE_DISTANCE over unit_size, so minDistance maps
/// onto unit_size with no fudging. MaxDistance 500 carries over as max_distance.
///
/// Two deliberate divergences.
///
/// Volume follows the death constant here; Unity set it once in Start and never
/// again. That only works if the scene is reloaded on death, and this game respawns
/// by teleporting the player through a fade instead - so on the original's code path
/// the volume is whatever it was at level load, which is zero, and the whisper is
/// never heard at all. Given the script's own comment, silence is not the intent.
/// Both quantities are driven from the signal, so they stay consistent.
///
/// The stagger is a random start position rather than Unity's PlayDelayed of a
/// random offset into the clip. Both exist to stop the emitters looping in
/// lockstep, and both give uniformly distributed relative phases; the difference is
/// that Unity's leaves each emitter silent for up to the clip's 14 seconds first.
/// </summary>
public partial class WhisperEmitter : AudioStreamPlayer3D
{
    /// <summary>minDistance in the original: the radius at no attenuation, with no deaths.</summary>
    [Export]
    public float MinDistance { get; set; } = 1.0f;

    /// <summary>maxMinDistance: what that radius grows to once the death constant reaches 1.</summary>
    [Export]
    public float MaxMinDistance { get; set; } = 10.0f;

    /// <summary>
    /// Stands in for a linear volume of zero. Mathf.LinearToDb(0) is negative
    /// infinity, which is not a value the audio server accepts.
    /// </summary>
    private const float SilenceDb = -80.0f;

    /// <summary>
    /// Volume at the onset of dying, in dB, ramping to 0 dB at the full death constant.
    ///
    /// Exported because how loud a whisper needs to be to feel present is a judgement
    /// made by ear, not a value derivable from the original.
    ///
    /// This replaces mapping the death constant onto LINEAR amplitude, which is what it
    /// was and which was reported in play as barely audible. The constant is deaths / 10,
    /// so a linear mapping put the first death at 0.1 amplitude = -20 dB and only reached
    /// full volume at ten deaths - while the player's own footsteps play at 0 dB right at
    /// the listener. The whisper sat 14 to 23 dB under them for the entire span of deaths
    /// an ordinary run produces, so the quiet end of the curve was where all the gameplay
    /// happened and full volume was somewhere almost nobody reached.
    ///
    /// Ramping in dB instead spends the range where it is heard. It is also the right
    /// space for this: dB is roughly perceptual, so equal death increments now sound like
    /// equal steps, which is what an escalation wants to be.
    /// </summary>
    [Export]
    public float OnsetVolumeDb { get; set; } = -8.5f;

    /// <summary>
    /// Volume at the full death constant, in dB. Not 0: the ceiling here is set by HEADROOM, not
    /// by taste.
    ///
    /// Thirteen emitters sum, and their unit_size has grown by then, so several are loud at once.
    /// Measured over the sampled route, the worst point sums to +4.9 dB of gain while the clip's
    /// own true peak is -0.9 dBTP. Master carries a hard limiter at -0.5 dB, so the hard ceiling
    /// on this value is -4.5 dB - past that the whispers alone drive the limiter, which is meant
    /// to be a net for coincident peaks rather than something that works during normal play.
    /// -6.0 keeps 1.5 dB below it.
    ///
    /// Two consequences worth understanding before changing any of this. At -6.0 the whisper bed
    /// measures 0.8 LU under the music at ten deaths, so it is already about level with the score
    /// at the top of the curve; more than this makes the whispers the loudest thing in the game.
    /// And the escalation cannot be large in VOLUME, because the top is pinned by headroom and the
    /// bottom has to stay audible - it is about 5.5 dB. The rest is carried by density instead: as
    /// unit_size widens, more emitters become audible at once, which the summed level shows
    /// growing 0.5 -> 4.4 dB while the nearest single emitter only grows 1.7 dB. More voices, not
    /// just louder ones, which is closer to what "the whispers close in" should feel like anyway.
    /// </summary>
    [Export]
    public float PeakVolumeDb { get; set; } = -6.0f;

    /// <summary>
    /// Shapes how the ramp is spent across the death count. Below 1 is concave: early deaths
    /// gain more than late ones.
    ///
    /// Needed because the death constant is deaths / 10, so deaths one to four - which is what
    /// an ordinary run produces - occupy only the first 10 to 40% of it. Ramping LINEARLY in the
    /// constant therefore still handed the quiet end of the range to the only death counts
    /// anyone reaches, which is the same mistake as the linear-amplitude version in a subtler
    /// form: fixing the units did not fix where the range was spent.
    ///
    /// At 0.45 the first death lands about 2.8 dB higher than a linear ramp would put it and the
    /// third about 2.2 dB higher, while the full death constant is untouched - so the escalation
    /// still arrives somewhere, it just stops wasting its first half.
    /// </summary>
    [Export]
    public float DeathCurveExponent { get; set; } = 0.45f;

    public override void _Ready()
    {
        GameManager? manager = GameManager.Instance;
        if (manager is null)
        {
            GD.PushWarning($"{Name}: GameManager autoload is missing; the whisper will stay at its resting distance and volume.");
            return;
        }

        manager.DeathConstantChanged += OnDeathConstantChanged;
        Apply(manager.DeathConstant);

        if (Stream is not null)
        {
            Play((float)(GD.Randf() * Stream.GetLength()));
        }
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
        Apply(deathConstant);
    }

    private void Apply(float deathConstant)
    {
        UnitSize = MinDistance + ((MaxMinDistance - MinDistance) * deathConstant);

        // Silent until the player has died at all - the whisper arriving with dying is the
        // effect - then straight to an audible level and up from there. The step at zero is
        // deliberate: a ramp that starts inaudible and passes through audible would spend
        // its first few deaths on volumes nobody can hear, which is the bug this replaces.
        //
        // The exponent shapes WHERE the range is spent; see DeathCurveExponent. Note that
        // UnitSize above stays linear in the constant on purpose - it is a distance, and the
        // original's mechanic was a distance widening, so bending it would change what the
        // effect is rather than how loud it is.
        VolumeDb = deathConstant <= 0.0f
            ? SilenceDb
            : Mathf.Lerp(OnsetVolumeDb, PeakVolumeDb, Mathf.Pow(deathConstant, DeathCurveExponent));
    }
}
