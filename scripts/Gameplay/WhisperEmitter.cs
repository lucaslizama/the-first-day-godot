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
    public float OnsetVolumeDb { get; set; } = -10.0f;

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
        VolumeDb = deathConstant <= 0.0f
            ? SilenceDb
            : Mathf.Lerp(OnsetVolumeDb, 0.0f, deathConstant);
    }
}
