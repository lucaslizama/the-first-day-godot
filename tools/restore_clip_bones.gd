# Restores the bone rotations our clips are missing, from Unity's own values.
#
#   python3 tools/extract_unity_bone_poses.py <unity Animaciones dir>   # first
#   godot-mono --headless --script tools/restore_clip_bones.gd -- [--dry] [clip ...]
#
# Our imported clips are short of bones that Unity's have. Two different causes, and they
# need different answers:
#
#   * `animation/remove_immutable_tracks` dropped tracks that never change. Those bones
#     held one value for the whole clip, so one key restores them exactly.
#   * jumpR1Frame's export is genuinely broken - 2 rotation tracks, Hip_L and Scapula_L,
#     against Unity's 43. A body pose where only those two bones differ is not plausible,
#     so this is missing source data rather than a compression artefact. tools/
#     complete_clip_bones.gd fills with the bone's REST rotation, which is right for the
#     first case and wrong for this one: it would put the character in a rest stance
#     mid-air instead of Unity's airborne pose.
#
# This uses Unity's actual values for both, so it is correct either way and supersedes
# rest-filling.
#
# The conversion from Unity is (x, y, z, w) -> (x, -y, -z, w), the diag(-1, 1, 1)
# conjugation the whole port uses. MEASURED, not assumed: it reproduces all 35 bones our
# jumpL1Frame shares with Unity's. This script re-validates it on every shared bone of
# every clip it touches and refuses to write if the agreement breaks, because a silent
# coordinate error here would put limbs in arbitrary places.
extends SceneTree

const ANIM_DIR := "res://models/fortunato/anims"
const POSES := "bone_poses.json"
## Shared bones must agree this closely, allowing for q == -q.
##
## 5 degrees, not a tight fraction of one, because a legitimate mismatch exists on MOVING
## bones: `animation/trimming` is on, so our clip's t = 0 is not necessarily Unity's first
## key, and a bone mid-motion differs by however far it travels in that offset. Measured at
## 2.42 degrees on run's Hip_R. What this needs to catch is a coordinate-system error,
## which shows up as tens of degrees - the rest-filled values this supersedes were 42 and
## 72 degrees out - so the threshold sits well clear of both.
const VALIDATE_DEGREES := 5.0

var failures := 0


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var dry := "--dry" in args
	var only: Array[String] = []
	for a in args:
		if not a.begins_with("--"):
			only.append(a)

	var sp := OS.get_environment("SP")
	var path := (sp if sp != "" else "/tmp") + "/" + POSES
	if not FileAccess.file_exists(path):
		printerr("FAIL: %s not found. Run tools/extract_unity_bone_poses.py first." % path)
		quit(1)
		return
	var unity: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))

	var player := (load("res://scenes/player.tscn") as PackedScene).instantiate()
	var anim := player.get_node("AnimationPlayer") as AnimationPlayer

	for clip_name in anim.get_animation_list():
		if not only.is_empty() and not clip_name in only:
			continue
		if not unity.has(clip_name):
			print("%-14s no Unity data; skipped" % clip_name)
			continue
		_restore(anim, clip_name, unity[clip_name], dry)

	if failures > 0:
		printerr("")
		printerr("FAIL: %d clip(s) failed validation; nothing was written for them." % failures)
		quit(1)
		return
	print("")
	print(("dry run, nothing written" if dry else "written"))
	quit()


func _restore(anim: AnimationPlayer, clip_name: String, unity: Dictionary, dry: bool) -> void:
	var clip := anim.get_animation(clip_name)

	var prefix := ""
	var have := {}
	for i in clip.get_track_count():
		var p := String(clip.track_get_path(i))
		if clip.track_get_type(i) != Animation.TYPE_ROTATION_3D or not ":" in p:
			continue
		var parts := p.split(":")
		prefix = parts[0]
		have[parts[1]] = i
	if prefix == "":
		printerr("FAIL: %s has no rotation track to take a node path from" % clip_name)
		failures += 1
		return

	# Validate the conversion on every bone we already have.
	var checked := 0
	var worst := 0.0
	var worst_bone := ""
	for bone in have:
		if not unity.has(bone):
			continue
		var u: Array = unity[bone]
		var uq := Quaternion(u[0], u[1], u[2], u[3])
		var ours: Quaternion = clip.rotation_track_interpolate(have[bone], 0.0)
		# q and -q are the same rotation, so compare the smaller of the two angles.
		var d: float = minf(rad_to_deg(ours.angle_to(uq)), rad_to_deg(ours.angle_to(-uq)))
		checked += 1
		if d > worst:
			worst = d
			worst_bone = bone

	if checked > 0 and worst > VALIDATE_DEGREES:
		printerr("FAIL: %s - the Unity conversion does not reproduce '%s' (%.2f deg off). Not writing." % [
			clip_name, worst_bone, worst])
		failures += 1
		return

	var added := 0
	for bone in unity:
		if have.has(bone):
			continue
		var u: Array = unity[bone]
		var track := clip.add_track(Animation.TYPE_ROTATION_3D)
		clip.track_set_path(track, NodePath("%s:%s" % [prefix, bone]))
		clip.rotation_track_insert_key(track, 0.0, Quaternion(u[0], u[1], u[2], u[3]))
		added += 1

	print("%-14s validated %-3d shared bones (worst %.3f deg on %-14s) added %d" % [
		clip_name, checked, worst, worst_bone if worst_bone != "" else "-", added])

	if dry or added == 0:
		return
	var out := "%s/%s.res" % [ANIM_DIR, clip_name]
	var err := ResourceSaver.save(clip, out)
	if err != OK:
		printerr("FAIL: could not save %s (error %d)" % [out, err])
		failures += 1
