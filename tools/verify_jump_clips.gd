# Checks the airborne clips against the Fortunato Controller's jump_land sub-machine.
#
#   godot-mono --headless --path . --script tools/verify_jump_clips.gd
#
# The animator's jump_land machine has six states in two sets, chosen by the LeftJump
# bool - its only use anywhere in the controller:
#
#   LeftJump false (default)  jump -> jumpR         fall -> jumpR1Frame        land -> jumpR1Frame
#   LeftJump true  (entry)    jump_moving -> jumpL  fall_moving -> jumpL1Frame land_moving -> jumpL1Frame
#
# while `death` -> fall.anim, which is NOT an airborne clip. Playing fall.anim while
# descending was the bug this exists to catch: a jump spends most of its arc falling, so
# every jump looked like dying.
#
# Driven through real simulated input rather than by poking state, because IsJumping and
# IsFalling have private setters and the point is to exercise the path the game uses.
# LeftJump comes from method tracks on walk and run, so the moving case walks first.
extends SceneTree

const DEATH_CLIP := "fall"
const JUMP_CLIPS := ["jumpL", "jumpR"]
const AIRBORNE_CLIPS := ["jumpL1Frame", "jumpR1Frame"]

var level: Node3D
var player: CharacterBody3D
var anim: AnimationPlayer

var frame := 0
var stage := "settle"
var stage_frame := 0
var seen := {}
var failures := 0
var checks := 0
var left_jump_seen := {"true": false, "false": false}


func _initialize() -> void:
	level = (load("res://scenes/level.tscn") as PackedScene).instantiate()
	root.add_child(level)
	player = level.get_node("Player")
	anim = player.get_node("AnimationPlayer")


func _physics_process(_delta: float) -> bool:
	frame += 1
	stage_frame += 1

	_record()

	match stage:
		"settle":
			# Let the opening fade and the ground settle before touching anything.
			if stage_frame > 40:
				_to("jump_still", "jumping from a standstill")
				Input.action_press("jump")
		"jump_still":
			if stage_frame == 4:
				Input.action_release("jump")
			if stage_frame > 90:
				_to("walk", "walking, so a footfall fires SetLeftJump/SetRightJump")
				Input.action_press("move_forward")
		"walk":
			# 60 physics ticks is 1.0 s at Godot's default 60 Hz, and the walk clip's
			# measured footfalls are at 0.783 s (left) and 1.533 s (right) - so the last
			# event to have fired is SetLeftJump, and the jump below must pick the left
			# clips. Deliberately not an arbitrary wait: an earlier version used 130
			# ticks, which lands after the right footfall, and the left case never ran.
			if stage_frame > 60:
				_to("jump_moving", "jumping 1.0 s into the walk cycle, just past the left footfall")
				Input.action_press("jump")
		"jump_moving":
			if stage_frame == 4:
				Input.action_release("jump")
			if stage_frame > 90:
				Input.action_release("move_forward")
				_report()
				quit(1 if failures > 0 else 0)
				return true
	return false


func _to(next: String, note: String) -> void:
	stage = next
	stage_frame = 0
	print("   [%s] %s" % [next, note])


func _record() -> void:
	var clip: String = anim.current_animation
	if clip == "":
		return
	if not seen.has(clip):
		seen[clip] = {"jumping": 0, "falling": 0, "grounded": 0}
	if player.IsJumping:
		seen[clip]["jumping"] += 1
	elif player.IsFalling:
		seen[clip]["falling"] += 1
	else:
		seen[clip]["grounded"] += 1
	# Which side the airborne clips picked, over the whole run.
	if clip in ["jumpL", "jumpL1Frame"]:
		left_jump_seen["true"] = true
	elif clip in ["jumpR", "jumpR1Frame"]:
		left_jump_seen["false"] = true


func _fail(m: String) -> void:
	failures += 1
	print("  FAIL  ", m)


func _ok(m: String) -> void:
	print("  ok    ", m)


func _airborne_ticks(clips: Array, state: String) -> int:
	var n := 0
	for c in clips:
		if seen.has(c):
			n += seen[c][state]
	return n


func _report() -> void:
	print("")
	print("clips used, by state (physics ticks):")
	for clip in seen:
		var s: Dictionary = seen[clip]
		print("   %-14s jumping=%-5d falling=%-5d grounded=%-5d" % [
			clip, s["jumping"], s["falling"], s["grounded"]])
	print("")

	checks += 1
	var bad := 0
	if seen.has(DEATH_CLIP):
		bad = seen[DEATH_CLIP]["falling"] + seen[DEATH_CLIP]["jumping"]
	if bad > 0:
		_fail("'%s' - the death clip - played for %d airborne ticks" % [DEATH_CLIP, bad])
	else:
		_ok("the death clip never plays while airborne")

	checks += 1
	var asc := _airborne_ticks(JUMP_CLIPS, "jumping")
	if asc > 0:
		_ok("ascending uses jumpL/jumpR (%d ticks)" % asc)
	else:
		_fail("ascending used neither jumpL nor jumpR")

	checks += 1
	var desc := _airborne_ticks(AIRBORNE_CLIPS, "falling")
	if desc > 0:
		_ok("descending uses jumpL1Frame/jumpR1Frame (%d ticks)" % desc)
	else:
		_fail("descending used neither jumpL1Frame nor jumpR1Frame")

	checks += 1
	if left_jump_seen["true"] and left_jump_seen["false"]:
		_ok("both feet selected across the run, so the walk/run events arrive")
	else:
		_fail("only the %s-foot clips were ever chosen; LeftJump is not being set from the clips"
			% ("left" if left_jump_seen["true"] else "right"))

	print("")
	if failures == 0:
		print("PASS: %d checks" % checks)
	else:
		print("FAIL: %d of %d checks failed" % [failures, checks])
