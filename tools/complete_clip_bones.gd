# Makes a clip specify every bone, so its pose does not depend on what played before.
#
#   godot-mono --headless --script tools/complete_clip_bones.gd -- [--dry]
#
# Unity's animator states all have m_WriteDefaultValues: 1, and Unity's own clips animate
# all 43 deformation bones, so entering a state there always produced the same pose. Our
# imported clips do not: `animation/remove_immutable_tracks` drops any track that never
# changes, and the extraction that produced models/fortunato/anims/*.res kept only what
# survived. So bones a clip holds still simply have no track, and they retain whatever the
# PREVIOUS clip left them at.
#
# Measured on the death clip, comparing the pose reached after walking against the pose
# reached after idling:
#
#     Scapula_L        45.7 deg apart
#     MiddleFinger1_L  31.9 deg
#     Scapula_R        25.9 deg
#
# A 45.7 degree scapula moves the whole arm, which is why dying looked wrong in one
# situation and not another. This fills each listed clip's missing bones with the bone's
# REST rotation, held for the clip's length, which is what a track removed for being
# immutable held.
#
# Only the clips listed below, deliberately:
#
#   fall, cry   one-shot poses that are entered and then HELD - fall for the three
#               seconds until the screen is black - so any leftover is on screen for a
#               long time and this matters most.
#
# NOT the airborne clips. jumpR1Frame carries 2 rotation tracks against Unity's 43, so it
# is far more incomplete than these - but the port currently relies on it holding the
# take-off pose from jumpR, which reads as an airborne tuck and has been confirmed to look
# right in play. Filling it would replace that with a rest-ish pose and change behaviour
# that is not being complained about. It is recorded as an outstanding issue instead.
#
# Rotation only. A bone's position and scale tracks are its rest offsets in practice, and
# the pose problem observed is entirely rotational.
extends SceneTree

const CLIPS := ["fall", "cry"]
const ANIM_DIR := "res://models/fortunato/anims"

func _init() -> void:
	var dry := "--dry" in OS.get_cmdline_user_args()
	var player := (load("res://scenes/player.tscn") as PackedScene).instantiate()
	var anim := player.get_node("AnimationPlayer") as AnimationPlayer
	var skel := _skeleton(player)
	if skel == null:
		printerr("FAIL: no Skeleton3D under the player")
		quit(1)
		return

	# The prefix every bone track shares, taken from a track that already exists so this
	# does not hardcode the scene's node layout.
	for clip_name in CLIPS:
		if not anim.has_animation(clip_name):
			printerr("FAIL: no '%s' clip" % clip_name)
			quit(1)
			return
		var clip := anim.get_animation(clip_name)

		var prefix := ""
		var have := {}
		for i in clip.get_track_count():
			var path := String(clip.track_get_path(i))
			if clip.track_get_type(i) != Animation.TYPE_ROTATION_3D or not ":" in path:
				continue
			var parts := path.split(":")
			prefix = parts[0]
			have[parts[1]] = true
		if prefix == "":
			printerr("FAIL: %s has no rotation tracks to take a node path from" % clip_name)
			quit(1)
			return

		var added := 0
		for b in skel.get_bone_count():
			var bone := skel.get_bone_name(b)
			if have.has(bone):
				continue
			var rest := skel.get_bone_rest(b)
			var track := clip.add_track(Animation.TYPE_ROTATION_3D)
			clip.track_set_path(track, NodePath("%s:%s" % [prefix, bone]))
			clip.rotation_track_insert_key(track, 0.0, rest.basis.get_rotation_quaternion())
			added += 1

		print("%-6s %d rotation tracks -> %d (added %d at rest)" % [
			clip_name, have.size(), have.size() + added, added])

		if dry:
			continue
		var path := "%s/%s.res" % [ANIM_DIR, clip_name]
		var err := ResourceSaver.save(clip, path)
		if err != OK:
			printerr("FAIL: could not save %s (error %d)" % [path, err])
			quit(1)
			return

	print("%s" % ("dry run, nothing written" if dry else "written"))
	quit()


func _skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var s := _skeleton(c)
		if s != null:
			return s
	return null
