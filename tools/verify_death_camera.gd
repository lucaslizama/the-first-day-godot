# Checks that the camera lets go of the player on death, and takes him back after.
#
#   godot-mono --headless --path . --script tools/verify_death_camera.gd
#
# Reported in play: "in the original, when dying the camera would stop following the player
# once the dying animation started - it was intentional, to give a certain effect to death."
# The player is supposed to fall out of frame so you never watch the landing.
#
# The port had dropped it. nivelEscena's death chain reparents `Camera Target` out of
# Fortunato onto a static node, and that had been mis-read as reparenting the PLAYER to
# undo the moving-platform parenting, which this port does not need - so both calls were
# omitted as dead weight. See RespawnChain.
#
# What this measures is the effect, not the mechanism: the camera's target must stop
# tracking the player while dead, the player must keep moving while it does, and the target
# must be back on the player once the fade completes. It would pass equally if the port
# went back to reparenting.
#
# Note the negative control. "The target stopped moving" is worthless on its own - a target
# that never moves in the first place would pass it. So the same run first requires the
# target to FOLLOW the player before death, and requires the player to have travelled a
# real distance during the death window.
extends SceneTree

const DEATH_SETTLE := 45
const FALL_TICKS := 40
## Death only ever happens in the kill volume, so the player is always airborne when it
## fires. Standing on the spawn floor he does not move at all, which makes "the target
## stayed put" unfalsifiable - the negative control below catches exactly that. Lifting
## him well clear of any geometry reproduces the real conditions.
const LIFT_METRES := 60.0
const LIFT_SETTLE := 20
## The player travels metres in FALL_TICKS while dying; the target must not follow.
const FROZEN_TOLERANCE := 0.001
## Before death the target sits on the player and must track it closely.
const FOLLOW_TOLERANCE := 0.05
## The player must actually be falling for the frozen check to mean anything.
const MIN_PLAYER_TRAVEL := 0.5

var level: Node3D
var player: Node3D
var target: Node3D
var camera: Camera3D
var chain: Node

var frame := 0
var stage := 0
var follow_error := 0.0
var target_before := Vector3.ZERO
var camera_before := Vector3.ZERO
var player_before := Vector3.ZERO
var target_drift := 0.0
var camera_drift := 0.0
var player_travel := 0.0
var checks := 0
var failures := 0


func _physics_process(_delta: float) -> bool:
	frame += 1
	if frame == 2:
		level = (load("res://scenes/level.tscn") as PackedScene).instantiate()
		root.add_child(level)
		return false
	if frame < 20:
		return false

	if player == null:
		player = level.get_node_or_null("Player") as Node3D
		target = level.get_node_or_null("Player/CameraTargetParent/CameraTarget") as Node3D
		camera = level.get_node_or_null("Camera3D") as Camera3D
		if camera == null:
			for c in level.get_children():
				if c is Camera3D:
					camera = c
		chain = _find_chain(level)
		if player == null or target == null or chain == null:
			_fail("level.tscn is missing the player, its CameraTarget, or the RespawnChain")
			_finish()
			return true

	match stage:
		0:
			# The control: while alive the target must ride along with the player.
			follow_error = maxf(follow_error,
				target.global_position.distance_to(player.global_position + Vector3(0, 1.55, 0)))
			if frame > 60:
				checks += 1
				if follow_error <= FOLLOW_TOLERANCE:
					_ok("while alive the target tracks the player (worst %.4f m)" % follow_error)
				else:
					_fail("the target does not follow the player even when alive (%.3f m off); the frozen check below would be vacuous" % follow_error)
				player.global_position += Vector3(0, LIFT_METRES, 0)
				stage = 4
		4:
			# Airborne first, then die - the order death actually happens in.
			if frame > 60 + LIFT_SETTLE:
				_kill()
				_check_death_took_effect()
				stage = 1
		1:
			if frame > 60 + LIFT_SETTLE + DEATH_SETTLE:
				target_before = target.global_position
				player_before = player.global_position
				camera_before = camera.global_position if camera != null else Vector3.ZERO
				stage = 2
		2:
			target_drift = maxf(target_drift, target.global_position.distance_to(target_before))
			player_travel = maxf(player_travel, player.global_position.distance_to(player_before))
			if camera != null:
				camera_drift = maxf(camera_drift, camera.global_position.distance_to(camera_before))
			if frame > 60 + LIFT_SETTLE + DEATH_SETTLE + FALL_TICKS:
				_report_frozen()
				_revive()
				stage = 3
		3:
			if frame > 60 + LIFT_SETTLE + DEATH_SETTLE + FALL_TICKS + 20:
				_report_restored()
				_finish()
				return true
	return false


## Drives the real chain rather than poking the camera directly, so the wiring is covered.
func _kill() -> void:
	chain.call("OnDeath") if chain.has_method("OnDeath") else chain.call("_on_death")


func _revive() -> void:
	chain.call("OnFadeOutCompleted") if chain.has_method("OnFadeOutCompleted") \
		else chain.call("_on_fade_out_completed")


## Guards against a vacuous run. The chain's handlers are private C# methods reached
## through Object.call, so if that ever stops resolving, every measurement below would
## still "pass" while nothing had been driven at all.
func _check_death_took_effect() -> void:
	checks += 1
	var dead: bool = player.get("IsDead")
	if dead and target.top_level:
		_ok("OnDeath ran: the player is dead and the target is detached")
	else:
		_fail("OnDeath did not take effect (IsDead=%s, target.top_level=%s) - the rest of this run would prove nothing" % [
			str(dead), str(target.top_level)])


func _report_frozen() -> void:
	checks += 1
	if player_travel < MIN_PLAYER_TRAVEL:
		_fail("the player only moved %.3f m while dead, so 'the target stayed put' proves nothing. Raise FALL_TICKS or check that death lets him fall." % player_travel)
	else:
		_ok("the player fell %.2f m during the death window" % player_travel)

	checks += 1
	if target_drift <= FROZEN_TOLERANCE:
		_ok("the camera target stayed put while the player fell %.2f m (drift %.5f m)" % [
			player_travel, target_drift])
	else:
		_fail("the camera target followed the dying player %.3f m; it should hold still so he drops out of frame" % target_drift)


func _report_restored() -> void:
	checks += 1
	var gap: float = target.global_position.distance_to(player.global_position + Vector3(0, 1.55, 0))
	if not target.top_level and gap <= FOLLOW_TOLERANCE:
		_ok("after the fade the target is back on the player (%.4f m, top_level cleared)" % gap)
	else:
		_fail("after the fade the target is %.3f m from the player (top_level=%s); the camera never took him back" % [
			gap, str(target.top_level)])


func _find_chain(n: Node) -> Node:
	if n.get_script() != null and String(n.get_script().resource_path).ends_with("RespawnChain.cs"):
		return n
	for c in n.get_children():
		var f := _find_chain(c)
		if f != null:
			return f
	return null


func _finish() -> void:
	print("")
	if failures == 0:
		print("PASS: %d checks" % checks)
	else:
		print("FAIL: %d of %d checks failed" % [failures, checks])
	quit(1 if failures > 0 else 0)


func _ok(m: String) -> void:
	print("  ok    ", m)


func _fail(m: String) -> void:
	failures += 1
	print("  FAIL  ", m)
