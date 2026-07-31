# Checks that the character walks up the stairs before the end line, and that the step-up which
# lets him do it does not also let him climb things he should not.
#
#   godot-mono --headless --path . --script tools/verify_stairs.gd
#
# Reported in play as getting stuck on those steps. Measured rather than guessed: raycasting the
# floor there gives flat treads - every hit reads 0.0 degrees - with eight risers of 0.19 to 0.27 m
# carrying the player from y = 10.0 at z = -162 to y = 12.0 at z = -168. So it is a staircase, not
# a slope, and the slope limit was never involved.
#
# Godot's CharacterBody3D has NO step-offset property. Without one the limit is capsule geometry
# alone: contact is on the step's top edge, the normal runs from that edge to the bottom sphere's
# centre at y = radius, and move_and_slide only slides UP a surface classified as floor. That puts
# the tallest walkable step at r * (1 - 1/sqrt(2)) = 0.088 m for the 0.3 m capsule; measured
# between 0.09 and 0.10 m against a real box. The risers are two to three times that, which is why
# it is a hard stop, and why neither speed nor safe_margin changed anything.
#
# Unity's CharacterController had m_StepOffset: 0, so THE ORIGINAL COULD NOT STEP EITHER - those
# stairs had to be jumped, and a JumpForce of 10 against Gravity 20 gives 2.5 m, which clears a
# riser without trying. PlayerCharacter.StepHeight is therefore a deliberate addition rather than a
# port fix, and the second check below exists because adding it is not free: a step-up will climb
# anything shorter than its threshold, ledges and props included.
#
# Drives the real PlayerCharacter.TryStepUp. Physics processing is switched off on the player so
# PlayerInput does not zero the velocity every frame - the input path is not what is under test
# here, the manoeuvre is. Re-implementing that manoeuvre in this file would be the surest way to
# have it drift away from the code it is supposed to be checking.
extends SceneTree

const LEVEL := "res://scenes/level.tscn"

## Bottom of the staircase, a little above the tread so the first frame settles rather than
## starting embedded.
const STAIRS_START := Vector3(0.0, 10.05, -161.0)
const STAIRS_TOP_Y := 12.0

## Player values, read off the node where possible; these are the fallbacks.
const WALK_SPEED := 2.5
const RUN_SPEED := 4.5
const GRAVITY := 20.0
const TICK := 1.0 / 60.0
const RUN_FRAMES := 420

## Must NOT be climbable. Comfortably over StepHeight, and the height of something the level would
## expect you to jump onto.
const TOO_TALL := 0.6

## Must NOT be climbable either, despite being well UNDER StepHeight, because nothing tags it.
## This is the only case that distinguishes opt-in from opt-out - every other one here behaves the
## same whether the filter exists or not.
const UNTAGGED_STEP := 0.2

## Walking DOWN, from the top of the stairs back toward the level. Finishes once he is past the
## bottom of the flight.
##
## z = -168.5 deliberately, not -167: the floor profile reads 12.000 at -168.5 but 11.777 at -167,
## so starting there would drop him 0.27 m before he took a step and count that as airborne.
const DESCEND_START := Vector3(0.0, 12.05, -168.5)
const DESCEND_END_Z := -161.5

## Frames to let him settle before counting airborne ones, since he starts a few centimetres above
## the floor and the first contact would otherwise register as a fall.
const SETTLE_FRAMES := 10

## Metres the camera target may rise in one frame. Walking up this staircase gains 2 m over about
## 6 m of travel, so at run speed that is roughly 0.025 m per frame; 0.05 leaves room for the settle
## without admitting a teleport, which lands a whole 0.24 m riser at once.
const MAX_CAMERA_RISE_PER_FRAME := 0.05

## PlayerCharacter.TicksToWaitForFall, the number of consecutive frames off the floor that turns into
## a committed fall - and so into a clip change.
const TICKS_TO_WAIT_FOR_FALL := 5

var airborne_frames := 0
var airborne_bursts := 0
var current_burst := 0
var longest_burst := 0
var was_airborne := false
var worst_camera_rise := 0.0
var last_camera_y := INF
var camera_target: Node3D

var frame := 0
var level: Node3D
var player: CharacterBody3D
var checks := 0
var failures := 0

var cases: Array = []
var case_index := -1
var run_frame := 0
var best_y := 0.0
var obstacle: StaticBody3D


func _process(_delta: float) -> bool:
	frame += 1
	if frame == 1:
		level = (load(LEVEL) as PackedScene).instantiate()
		root.add_child(level)
		return false
	if frame < 8:
		return false
	if frame == 8:
		player = level.get_node_or_null("Player") as CharacterBody3D
		if player == null:
			_fail("the level has no Player")
			_finish()
			return true
		# Stop _PhysicsProcess overwriting Velocity from PlayerInput every frame.
		player.set_physics_process(false)
		# What ThirdPersonCamera aims at, so the camera-jump measurement watches the real thing.
		camera_target = player.get_node_or_null("CameraTargetParent/CameraTarget") as Node3D
		if camera_target == null:
			_fail("the player has no CameraTargetParent/CameraTarget to measure")
		_enable_backfaces(level)
		_check_tagging()
		cases = [
			{"name": "walk up the stairs", "speed": WALK_SPEED, "at": STAIRS_START, "ledge": 0.0, "expect": true},
			{"name": "run up the stairs", "speed": RUN_SPEED, "at": STAIRS_START, "ledge": 0.0, "expect": true},
			{"name": "a %.2f m ledge stays unclimbable" % TOO_TALL, "speed": RUN_SPEED,
				"at": Vector3(0.0, 12.05, -172.0), "ledge": TOO_TALL, "expect": false},
			# An UNTAGGED step, well under StepHeight, must still refuse. This is the whole point of
			# opt-in and the only check that can tell it apart from opt-out: every other case here
			# passes identically whether the filter exists or not.
			{"name": "an untagged %.2f m step is refused" % UNTAGGED_STEP, "speed": WALK_SPEED,
				"at": Vector3(0.0, 12.05, -172.0), "ledge": UNTAGGED_STEP, "expect": false},
			# Descending, driven the other way along z. Covers both reported regressions at once.
			{"name": "walk down the stairs", "speed": -WALK_SPEED, "at": DESCEND_START,
				"ledge": 0.0, "expect": true, "descend": true},
		]
		_start_next()
		return false


	if case_index >= cases.size():
		return true

	_tick()
	run_frame += 1
	var case: Dictionary = cases[case_index]
	if bool(case.get("descend", false)):
		if run_frame >= RUN_FRAMES or player.global_position.z > DESCEND_END_Z:
			_report_descent(case)
			_start_next()
		return false

	var target: float = float((case["at"] as Vector3).y) + (
		STAIRS_TOP_Y - STAIRS_START.y if float(case["ledge"]) == 0.0 else float(case["ledge"]))
	if run_frame >= RUN_FRAMES or best_y >= target - 0.05:
		_report(case, target)
		_start_next()
	return false


## Two things the step-up broke, both reported in play and both measured here.
##
## Going DOWN, the walk clip restarted on every step. UpdateAnimation only replays on a change of
## clip, so the clip was not the problem - the STATE was flickering. Descending a 0.24 m riser under
## gravity 20 takes sqrt(2*0.24/20) = 0.155 s, about 9 frames, and CheckForFall commits to a fall
## after 5 - so every single step went walk -> airborne -> walk. The cause is that nothing kept him
## on the ground: floor_snap_length has to exceed the tallest riser or the body simply leaves the
## floor on the way down. Measured as is_on_floor() flickering, which is the physical cause rather
## than the animation symptom.
##
## Going UP, the camera jumped. The step-up is a teleport, so the whole vertical gain lands in one
## frame and the camera target goes with it. Measured as the largest single-frame rise of the camera
## target, against what ordinary walking on this staircase would produce.
func _report_descent(case: Dictionary) -> void:
	checks += 1
	# The bound is burst LENGTH, not total airborne frames, and that is the meaningful test rather
	# than a softened one. CheckForFall commits to a fall after TICKS_TO_WAIT_FOR_FALL consecutive
	# frames off the floor, and only a committed fall changes the clip - UpdateAnimation replays on a
	# change and nothing else. A one-frame gap is invisible.
	#
	# It cannot be zero, either: TryStepDown places the body with move_and_collide, which does not set
	# is_on_floor(). That flag only comes back on the next move_and_slide, so a successful step down
	# still reads as one airborne frame by construction.
	if longest_burst < TICKS_TO_WAIT_FOR_FALL:
		_ok("walking down, the longest gap off the floor is %d frame(s) over %d, under the %d that CheckForFall treats as a fall (%d gaps, %d frames total)" % [
			longest_burst, run_frame, TICKS_TO_WAIT_FOR_FALL, airborne_bursts, airborne_frames])
	else:
		_fail("walking down, he was off the floor for %d consecutive frames - CheckForFall commits after %d, and every commit restarts the walk clip. %d gaps over %d frames. floor_snap_length is %.2f m; note Godot's snap does not fire at the moment the tread is lost, which is why TryStepDown exists." % [
			longest_burst, TICKS_TO_WAIT_FOR_FALL, airborne_bursts, run_frame, player.floor_snap_length])


## Checked on the way UP, where the teleport happens; descending it only ever falls.
func _check_camera_smoothness(label: String) -> void:
	checks += 1
	if worst_camera_rise <= MAX_CAMERA_RISE_PER_FRAME:
		_ok("%s: the camera target never rises more than %.3f m in a frame (limit %.3f)" % [
			label, worst_camera_rise, MAX_CAMERA_RISE_PER_FRAME])
	else:
		_fail("%s: the camera target jumped %.3f m in a single frame (limit %.3f). The step-up is a teleport, so its vertical gain has to be smoothed out of the camera target rather than handed to it whole." % [
			label, worst_camera_rise, MAX_CAMERA_RISE_PER_FRAME])


## The filter is opt-in, so a typo in LevelShell.ClimbableMeshes silently disables the feature and
## the character sticks with nothing to explain it. Assert the tags reached real bodies.
func _check_tagging() -> void:
	checks += 1
	var group := String(player.get("ClimbableGroup"))
	var names: Array[String] = []
	for n in root.get_tree().get_nodes_in_group(group):
		names.append(String(n.name))
	names.sort()

	var wanted := ["polySurface18_col", "polySurface32_col"]
	var found_all := true
	for w in wanted:
		if not names.has(w):
			found_all = false

	if found_all:
		_ok("group '%s' holds %s" % [group, str(names)])
	else:
		_fail("group '%s' holds %s, expected %s. A name in LevelShell.ClimbableMeshes that matches no mesh is silent - check it against the node names in level.tscn." % [
			group, str(names), str(wanted)])


## One frame of movement, using the same order as PlayerCharacter._PhysicsProcess.
func _tick() -> void:
	var speed: float = float((cases[case_index] as Dictionary)["speed"])
	var v := player.velocity
	v.x = 0.0
	v.z = -speed
	v.y -= GRAVITY * TICK
	player.velocity = v

	var before := player.global_transform
	var intended := Vector3(v.x, 0.0, v.z) * TICK

	# Same order as PlayerCharacter._PhysicsProcess: slide, step, then let the camera catch up.
	# DrainStepSmoothing has to be driven explicitly here because _PhysicsProcess is switched off,
	# and without it the camera-jump check would measure a smoothing that never runs.
	var was_on_floor := player.is_on_floor()
	player.move_and_slide()
	if not player.call("TryStepUp", intended, before):
		player.call("TryStepDown", was_on_floor)
	player.call("DrainStepSmoothing", TICK)

	if player.is_on_floor():
		var settled := player.velocity
		settled.y = 0.0
		player.velocity = settled
	best_y = maxf(best_y, player.global_position.y)

	# Leaving the floor is what restarts the walk clip on the way down; count frames and bursts so a
	# failure says whether it is one long fall or one per step.
	var airborne := not player.is_on_floor()
	if airborne and run_frame > SETTLE_FRAMES:
		airborne_frames += 1
		current_burst += 1
		longest_burst = maxi(longest_burst, current_burst)
		if not was_airborne:
			airborne_bursts += 1
	else:
		current_burst = 0
	was_airborne = airborne

	# What the camera actually follows.
	if camera_target != null:
		var y := camera_target.global_position.y
		if last_camera_y != INF:
			worst_camera_rise = maxf(worst_camera_rise, y - last_camera_y)
		last_camera_y = y


func _report(case: Dictionary, target: float) -> void:
	checks += 1
	var climbed := best_y >= target - 0.05
	var expect := bool(case["expect"])
	var start_y := float((case["at"] as Vector3).y)
	if float(case["ledge"]) == 0.0:
		_check_camera_smoothness(String(case["name"]))

	if climbed == expect:
		if expect:
			_ok("%s: reached y=%.2f from %.2f (needed %.2f)" % [case["name"], best_y, start_y, target])
		else:
			_ok("%s: got no higher than y=%.2f from %.2f, %.2f m short of the top" % [
				case["name"], best_y, start_y, target - best_y])
	elif expect:
		_fail("%s: stopped at y=%.2f, %.2f m short of %.2f. StepHeight is %.2f m and the tallest riser is 0.27 m." % [
			case["name"], best_y, target - best_y, target, float(player.get("StepHeight"))])
	else:
		_fail("%s: climbed to y=%.2f, which it should not reach. StepHeight of %.2f m is letting the character mount things the level expects him to jump onto." % [
			case["name"], best_y, float(player.get("StepHeight"))])


func _start_next() -> void:
	if obstacle != null:
		obstacle.queue_free()
		obstacle = null
	case_index += 1
	if case_index >= cases.size():
		_finish()
		return

	var case: Dictionary = cases[case_index]
	var at: Vector3 = case["at"]
	var ledge := float(case["ledge"])
	if ledge > 0.0:
		# A wall across the corridor on the flat run past the top of the stairs, so the only way
		# past is up it.
		obstacle = StaticBody3D.new()
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(30.0, ledge, 4.0)
		shape.shape = box
		obstacle.add_child(shape)
		level.add_child(obstacle)
		obstacle.global_position = Vector3(at.x, at.y - 0.05 + ledge * 0.5, at.z - 4.0)

	player.velocity = Vector3.ZERO
	player.global_position = at
	best_y = at.y
	run_frame = 0
	airborne_frames = 0
	airborne_bursts = 0
	current_burst = 0
	longest_burst = 0
	was_airborne = false
	worst_camera_rise = 0.0
	last_camera_y = INF


func _finish() -> void:
	print("")
	if failures == 0:
		print("PASS: %d checks" % checks)
	else:
		print("FAIL: %d of %d checks failed" % [failures, checks])
	quit(1 if failures > 0 else 0)


func _enable_backfaces(n: Node) -> void:
	if n is CollisionShape3D and (n as CollisionShape3D).shape is ConcavePolygonShape3D:
		((n as CollisionShape3D).shape as ConcavePolygonShape3D).backface_collision = true
	for c in n.get_children():
		_enable_backfaces(c)


func _ok(m: String) -> void:
	print("  ok    ", m)


func _fail(m: String) -> void:
	failures += 1
	print("  FAIL  ", m)
