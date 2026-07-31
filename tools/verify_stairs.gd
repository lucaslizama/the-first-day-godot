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
		]
		_start_next()
		return false


	if case_index >= cases.size():
		return true

	_tick()
	run_frame += 1
	var case: Dictionary = cases[case_index]
	var target: float = float((case["at"] as Vector3).y) + (
		STAIRS_TOP_Y - STAIRS_START.y if float(case["ledge"]) == 0.0 else float(case["ledge"]))
	if run_frame >= RUN_FRAMES or best_y >= target - 0.05:
		_report(case, target)
		_start_next()
	return false


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

	player.move_and_slide()
	player.call("TryStepUp", intended, before)

	if player.is_on_floor():
		var settled := player.velocity
		settled.y = 0.0
		player.velocity = settled
	best_y = maxf(best_y, player.global_position.y)


func _report(case: Dictionary, target: float) -> void:
	checks += 1
	var climbed := best_y >= target - 0.05
	var expect := bool(case["expect"])
	var start_y := float((case["at"] as Vector3).y)
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
