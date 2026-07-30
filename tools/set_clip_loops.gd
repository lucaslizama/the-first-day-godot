# Sets each Fortunato clip's loop_mode from Unity's own m_LoopTime.
#
#   godot-mono --headless --script tools/set_clip_loops.gd -- [--dry]
#
# The FBX import gives every clip loop_mode NONE, which is wrong for the locomotion
# ones. Unity stores the answer per clip as m_LoopTime, transcribed below:
#
#   idle.anim   1     walk.anim   1     run.anim    1
#   cry.anim    0     fall.anim   0     jumpL.anim  0   jumpR.anim  0
#   jumpL1Frame 0     jumpR1Frame 0
#
# idle was the one that mattered and was missed: at 12.7 s it is long enough that the
# stutter when it ended and restarted looked like a hitch rather than a loop bug.
#
# A non-looping clip is not a problem by itself - it should end and hold its last pose.
# It becomes one if the code re-triggers it, which is what PlayerCharacter used to do:
# Godot clears current_animation when a non-looping clip finishes, so comparing against
# it re-played the clip forever. That is fixed in PlayerCharacter, not here.
#
# tools/add_footstep_events.gd also sets LOOP_LINEAR on walk and run, for the same
# reason and to the same value, so the two agree.
extends SceneTree

## Unity's m_LoopTime, per clip.
const LOOPS := {
	"idle": true,
	"walk": true,
	"run": true,
	"cry": false,
	"fall": false,
	"jumpL": false,
	"jumpR": false,
	"jumpL1Frame": false,
	"jumpR1Frame": false,
}

func _init() -> void:
	var dry := "--dry" in OS.get_cmdline_user_args()
	var player := (load("res://scenes/player.tscn") as PackedScene).instantiate()
	var anim := player.get_node("AnimationPlayer") as AnimationPlayer

	var changed := 0
	var missing: Array[String] = []
	for name in LOOPS:
		if not anim.has_animation(name):
			missing.append(name)
			continue
		var clip := anim.get_animation(name)
		var want: int = Animation.LOOP_LINEAR if LOOPS[name] else Animation.LOOP_NONE
		var state := "ok" if clip.loop_mode == want else "CHANGED"
		if clip.loop_mode != want:
			changed += 1
			clip.loop_mode = want
			if not dry:
				var path := "res://models/fortunato/anims/%s.res" % name
				var err := ResourceSaver.save(clip, path)
				if err != OK:
					printerr("FAIL: could not save %s (error %d)" % [path, err])
					quit(1)
					return
		print("  %-14s loop=%-6s %s" % [name, "yes" if LOOPS[name] else "no", state])

	for name in anim.get_animation_list():
		if not LOOPS.has(name):
			print("  %-14s NOT IN THE TABLE - decide its loop from Unity's m_LoopTime" % name)

	if not missing.is_empty():
		printerr("FAIL: clips in the table but not in the library: %s" % ", ".join(missing))
		quit(1)
		return

	print("%d clip(s) %s" % [changed, "would change" if dry else "changed"])
	quit()
