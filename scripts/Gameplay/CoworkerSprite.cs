using Godot;

namespace TheFirstDay.Gameplay;

/// <summary>
/// Port of Unity's RandomizeMonoAnimStart.cs - 74 coworkers use it, one per sprite.
///
/// The original set an Animator float called "offset" to Random.Range(0, 1), and
/// the animator state fed that parameter into its Cycle Offset. So every coworker
/// plays the same looping clip from a random phase, which is the whole reason a
/// roomful of identical office workers does not look like a chorus line.
///
/// Godot has no cycle-offset parameter, but AnimatedSprite3D exposes the frame and
/// the progress within it, which is the same quantity: a phase in [0, 1) scaled by
/// the clip length. One random draw per coworker, at _Ready, exactly as Unity drew
/// one in Start.
///
/// Unity's Random.Range is unseeded, so the phases differed every run. Godot seeds
/// its global RNG at startup too, so that carries over without asking for it.
///
/// YBillboardFollow, the other script on every coworker, has no counterpart here:
/// it yawed the sprite toward the camera every frame, which is what
/// billboard = BILLBOARD_FIXED_Y does in the material. See coworker_mono1.tscn.
/// </summary>
public partial class CoworkerSprite : AnimatedSprite3D
{
    public override void _Ready()
    {
        if (SpriteFrames is null)
        {
            GD.PushError($"{Name}: no SpriteFrames assigned; the coworker will not animate.");
            return;
        }

        Play();

        int count = SpriteFrames.GetFrameCount(Animation);
        if (count > 0)
        {
            // Frame plus sub-frame progress, rather than just a frame index: at 30 fps
            // a whole-frame offset would quantise 74 coworkers onto 81 phases, and any
            // two sharing a frame would then stay locked together forever.
            SetFrameAndProgress(GD.RandRange(0, count - 1), GD.Randf());
        }
    }
}
