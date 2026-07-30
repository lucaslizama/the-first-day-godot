# Checks that the death pose is the same however the player got there.
#
#   godot-mono --headless --path . --script tools/verify_death_pose.gd
#
# Reported in play as "the death animation looks weird". It was not the clip choice: the
# animator's `death` state really does use fall.anim, and ours is that clip - 0.300 s, the
# same length, and falling.anim (the other similarly named file) turns out to be EMPTY,
# 0 curve paths, referenced by no state.
#
# The cause was missing data. Unity's clips animate all 43 deformation bones and every
# animator state has m_WriteDefaultValues: 1, so entering `death` there always produced the
# same pose. Our imported clips do not: `animation/remove_immutable_tracks` drops tracks
# that never change, so bones the clip holds still had no track at all and retained
# whatever the PREVIOUS clip left. Measured on the death pose, walking versus idling:
#
#     Scapula_L 45.7 deg, MiddleFinger1_L 31.9 deg, Scapula_R 25.9 deg
#
# A 45.7 degree scapula moves the whole arm, which is why dying looked wrong sometimes and
# not others. tools/complete_clip_bones.gd fills the gaps with each bone's rest rotation.
#
# This drives the same comparison so it cannot come back: reach the death pose from three
# different prior clips and require the result to be identical.
extends SceneTree

const PRIORS := ["walk", "idle", "run"]
const DEATH_CLIP := "fall"
const TOLERANCE := 0.5
const EXPECTED_BLEND := 0.1

var frame := 0
var player: CharacterBody3D
var anim: AnimationPlayer
var skel: Skeleton3D
var poses := {}
var index := 0
var failures := 0
var checks := 0


func _process(_delta: float) -> bool:
	frame += 1
	if frame == 2:
		player = (load("res://scenes/player.tscn") as PackedScene).instantiate()
		root.add_child(player)
		# The player picks its own clip every physics tick; in an empty scene it is
		# falling, so it would replace the clip under test within a few ticks.
		player.set_physics_process(false)
		anim = player.get_node("AnimationPlayer")
		skel = _skeleton(player)
		return false
	if frame < 6:
		return false

	if index < PRIORS.size():
		_capture(PRIORS[index])
		index += 1
		return false

	_check_coverage()
	_check_history()
	_check_blend()

	print("")
	if failures == 0:
		print("PASS: %d checks" % checks)
	else:
		print("FAIL: %d of %d checks failed" % [failures, checks])
	quit(1 if failures > 0 else 0)
	return true


func _capture(prior: String) -> void:
	skel.reset_bone_poses()
	anim.play(prior)
	anim.seek(1.0, true)
	anim.play(DEATH_CLIP)
	anim.seek(0.3, true)
	var snap := {}
	for i in skel.get_bone_count():
		snap[skel.get_bone_name(i)] = skel.get_bone_pose_rotation(i)
	poses[prior] = snap


## Every bone must be specified, or the pose depends on history by construction.
func _check_coverage() -> void:
	checks += 1
	var clip := anim.get_animation(DEATH_CLIP)
	var have := {}
	for i in clip.get_track_count():
		var path := String(clip.track_get_path(i))
		if clip.track_get_type(i) == Animation.TYPE_ROTATION_3D and ":" in path:
			have[path.split(":")[1]] = true
	var missing: Array[String] = []
	for i in skel.get_bone_count():
		if not have.has(skel.get_bone_name(i)):
			missing.append(skel.get_bone_name(i))
	if missing.is_empty():
		_ok("'%s' specifies all %d bones" % [DEATH_CLIP, skel.get_bone_count()])
	else:
		_fail("'%s' leaves %d bones unspecified, so its pose depends on history: %s" % [
			DEATH_CLIP, missing.size(), str(missing)])


func _check_history() -> void:
	checks += 1
	var base: Dictionary = poses[PRIORS[0]]
	var worst := 0.0
	var offenders: Array[String] = []
	for other in PRIORS.slice(1):
		var b: Dictionary = poses[other]
		for name in base:
			var d: float = rad_to_deg((base[name] as Quaternion).angle_to(b[name] as Quaternion))
			if d > TOLERANCE:
				offenders.append("%s (%s vs %s) %.1f deg" % [name, PRIORS[0], other, d])
			worst = maxf(worst, d)
	if offenders.is_empty():
		_ok("the death pose is identical from %s (worst %.4f deg)" % [str(PRIORS), worst])
	else:
		_fail("the death pose depends on the previous clip: %s" % str(offenders))


## Unity's Any State -> death transition has m_TransitionDuration 0.1.
func _check_blend() -> void:
	checks += 1
	var script := FileAccess.get_file_as_string("res://scripts/Gameplay/PlayerCharacter.cs")
	if script.contains("DeathBlendSeconds = %.1ff" % EXPECTED_BLEND) \
			and script.contains("Play(DeathClip, DeathBlendSeconds)"):
		_ok("Die blends over %.2f s, matching the transition's m_TransitionDuration" % EXPECTED_BLEND)
	else:
		_fail("Die does not blend over %.2f s; Unity's death transition is not an instant cut" % EXPECTED_BLEND)


func _skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var s := _skeleton(c)
		if s != null:
			return s
	return null


func _ok(m: String) -> void:
	print("  ok    ", m)


func _fail(m: String) -> void:
	failures += 1
	print("  FAIL  ", m)
