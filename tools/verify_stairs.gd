# Checks that the character walks up the stairs before the end line, and that the step-up which
# lets him do it does not also let him climb things he should not.
#
#   godot-mono --headless --path . tools/verify_stairs.tscn
#
# NOTE THE COMMAND: this is a SCENE, not a --script. That is the whole point of the rewrite and it
# is not cosmetic.
#
# The previous version was a SceneTree script that called move_and_slide() from _process. There is
# no fixed physics delta there, and it showed: measured on FLAT FLOOR, before any stairs, the body
# advanced 0.070 to 0.149 m per tick where walking is 0.0417, varying frame to frame.
# PlayerCharacter derives its step direction from the intended motion, so an overspeeding harness
# makes the body travel further than intended, which reversed the derived direction and drove the
# step-up backwards. The old file therefore reported the ascent as broken - 1.95 m short - while the
# real game climbed the flight without trouble. It was measuring its own harness.
#
# Two rules came out of that, and both are load-bearing:
#
#   1. DRIVE THE GAME, DO NOT SIMULATE IT. Input arrives through Input.action_press and the player's
#      own _PhysicsProcess does the moving, inside a real physics loop. The old version switched
#      _PhysicsProcess off and hand-rolled the movement, so PlayerInput, gravity, the animation
#      state and the camera smoothing were all outside what it tested.
#   2. RELOAD THE LEVEL BETWEEN CASES. Resetting position and velocity is not isolation. An
#      intermediate version of this harness reused one level across cases and reported four
#      different approaches ending at byte-identical positions, one of them a metre above the top
#      of the staircase - the giveaway that the cases were not independent at all.
#
# What the checks are for, unchanged from the version that found them:
#
# Reported in play as getting stuck on those steps. Measured rather than guessed: raycasting the
# floor there gives flat treads - every hit reads 0.0 degrees - with eight risers of 0.19 to 0.27 m
# carrying the player from y = 10.0 at z = -162 to y = 12.0 at z = -168. So it is a staircase, not
# a slope, and the slope limit was never involved.
#
# Godot's CharacterBody3D has NO step-offset property; confirmed against the class reference, which
# documents no step offset and no stair support at all. Without one the limit is capsule geometry
# alone: contact is on the step's top edge, the normal runs from that edge to the bottom sphere's
# centre at y = radius, and move_and_slide only slides UP a surface classified as floor. That puts
# the tallest walkable step at r * (1 - 1/sqrt(2)) = 0.088 m for the 0.3 m capsule; measured
# between 0.09 and 0.10 m against a real box. The risers are two to three times that.
#
# Unity's CharacterController had m_StepOffset: 0, so THE ORIGINAL COULD NOT STEP EITHER - those
# stairs had to be jumped. PlayerCharacter.StepHeight is a deliberate addition rather than a port
# fix, and the ledge checks exist because adding it is not free: a step-up will climb anything
# shorter than its threshold, ledges and props included.
extends Node3D

const LEVEL := "res://scenes/level.tscn"

## Bottom of the staircase, a little above the tread so the first tick settles rather than starting
## embedded. The flight is only 2 m wide - polySurface18 spans x in [-1, +1] - so x stays at 0:
## holding a diagonal walks off the side and out of the level, which is a level-design question
## rather than a step-up one.
const STAIRS_START := Vector3(0.0, 10.05, -161.0)
const STAIRS_TOP_Y := 12.0

## Must NOT be climbable. Comfortably over StepHeight, and the height of something the level would
## expect you to jump onto.
const TOO_TALL := 0.6

## Must NOT be climbable either, despite being well UNDER StepHeight, because nothing tags it.
## This is the only case that distinguishes opt-in from opt-out - every other one here passes
## identically whether the filter exists or not.
const UNTAGGED_STEP := 0.2

## Walking DOWN, from the top of the stairs back toward the level.
##
## z = -168.5 deliberately, not -167: the floor profile reads 12.000 at -168.5 but 11.777 at -167,
## so starting there would drop him 0.27 m before he took a step and count that as airborne.
const DESCEND_START := Vector3(0.0, 12.05, -168.5)
const DESCEND_END_Z := -161.5

## Ticks to let him settle before measuring, since he starts a few centimetres above the floor and
## the first contact would otherwise register as a fall.
const SETTLE_TICKS := 12

## Metres per second the camera target may rise, measured on the RENDER clock.
##
## A RATE, not a per-frame distance, and that is the point: PlayerCharacter drains the step offset in
## _Process so the camera - which samples its target in _Process - sees a continuous ramp rather than
## 60 Hz stair-steps. A per-frame bound would then be meaningless, because it would tighten or
## loosen with whatever frame rate the machine happens to render at. Under xvfb this project renders
## at roughly 17 fps against 60 physics ticks; on the user's machine it is the other way round.
##
## The separation is wide, so the bound does not need to be delicate. Walking the flight gains 2 m
## over about 2.4 s, i.e. ~0.8 m/s of honest climbing. A raw un-smoothed teleport is a 0.24 m riser
## inside one tick, which is 14.4 m/s. 3.0 m/s sits an order of magnitude below the teleport and
## comfortably above the smoothed easing.
##
## NOTE WHAT THIS CANNOT DO: it proves the offset is being eased rather than handed over whole. It
## cannot prove the result LOOKS smooth, because that depends on the render rate and this environment
## cannot reproduce the user's. Stutter is confirmed by eye.
const MAX_CAMERA_RISE_PER_SECOND := 3.0

## PlayerCharacter.TicksToWaitForFall, the consecutive ticks off the floor that turn into a
## committed fall - and so into a clip change.
const TICKS_TO_WAIT_FOR_FALL := 5

var checks := 0
var failures := 0
var reported := 0

var level: Node3D
var player: CharacterBody3D
var camera: Camera3D
var camera_target: Node3D
var obstacle: StaticBody3D

## Render-clock sampling of the camera target, driven from _process. See MAX_CAMERA_RISE_PER_SECOND.
var _sampling := false
var _worst_rise_rate := 0.0
var _last_target_y := INF
var _window_elapsed := 0.0


## Averaged over a fixed WINDOW rather than differentiated frame to frame.
##
## Dividing by a single frame's delta makes the peak an artefact of frame pacing: with the smoothing
## code untouched, the per-frame form measured 1.51 and 2.04 m/s on one run and 2.27 and 4.00 on the
## next, because this environment renders at a variable ~17 fps and a short frame inflates the
## quotient. That is a bound the measurement can take by luck, which is the definition of a flaky
## check. A window of RATE_WINDOW seconds spans several frames, so pacing averages out - and it is
## also closer to what "a jolt" means to a player than an instantaneous derivative is.
const RATE_WINDOW := 0.1


func _process(delta: float) -> void:
	if not _sampling or camera_target == null or delta <= 0.0:
		return
	var y := camera_target.global_position.y
	if _last_target_y == INF:
		_last_target_y = y
		_window_elapsed = 0.0
		return

	_window_elapsed += delta
	if _window_elapsed >= RATE_WINDOW:
		_worst_rise_rate = maxf(_worst_rise_rate, (y - _last_target_y) / _window_elapsed)
		_last_target_y = y
		_window_elapsed = 0.0


func _ready() -> void:
	_run()


func _run() -> void:
	# Case 1 of the ascent doubles as the tagging check's level, so load once up front.
	if not await _load_level():
		_finish()
		return
	_check_tagging()

	await _ascent("walk up the stairs", false)
	await _ascent("run up the stairs", true)
	await _ledge("a %.2f m ledge stays unclimbable" % TOO_TALL, TOO_TALL)
	await _ledge("an untagged %.2f m step is refused" % UNTAGGED_STEP, UNTAGGED_STEP)
	await _descent()

	_finish()


## Fresh level per case. See rule 2 in the header - this is the isolation, and nothing weaker was
## sufficient.
func _load_level() -> bool:
	if level != null:
		level.queue_free()
		level = null
		# Two frames: one for the free to happen, one for the C# side to settle before the next
		# instance starts calling into GameManager.
		await get_tree().process_frame
		await get_tree().process_frame

	obstacle = null
	level = (load(LEVEL) as PackedScene).instantiate() as Node3D
	add_child(level)
	await get_tree().physics_frame

	player = level.get_node_or_null("Player") as CharacterBody3D
	camera = level.get_node_or_null("Camera") as Camera3D
	if player == null:
		_fail("the level has no Player")
		return false
	if camera == null:
		_fail("the level has no Camera")
		return false

	camera_target = player.get_node_or_null("CameraTargetParent/CameraTarget") as Node3D
	if camera_target == null:
		_fail("the player has no CameraTargetParent/CameraTarget to measure")
		return false

	# The trimesh shells are one-sided, so without this the floors are invisible from above and
	# every raycast and settle finds nothing. Re-applied per load.
	_enable_backfaces(level)

	# The level opens with input disabled behind a fade; force it on rather than wait 3 s.
	var input := get_node_or_null("/root/PlayerInput")
	if input != null:
		input.set("CanValidateInput", true)
	return true


## Pins the camera so "forward" means a known world direction. ThirdPersonCamera would otherwise
## orbit as the character turns, and movement is camera-relative, so the walk direction would drift.
## Its script is left in place: clearing it disposes the C# object while other nodes still hold a
## reference, which floods the log with ObjectDisposedException.
func _pin_camera(looking_at_minus_z: bool) -> void:
	camera.set_process(false)
	camera.set_physics_process(false)
	var basis := Basis.IDENTITY if looking_at_minus_z else Basis.from_euler(Vector3(0.0, PI, 0.0))
	camera.global_transform = Transform3D(basis, player.global_position + Vector3(0.0, 1.5, 3.0))


func _place(at: Vector3) -> void:
	player.velocity = Vector3.ZERO
	player.global_position = at
	player.call("Revive")


## Walks or runs up the real staircase and reports both what it reached and how the camera behaved.
func _ascent(label: String, running: bool) -> void:
	if not await _load_level():
		return
	_place(STAIRS_START)

	var best_y := STAIRS_START.y
	var ticks := 0
	Input.action_press("move_forward")
	if running:
		Input.action_press("run")

	# Sampled on the render clock, because that is both where the offset is drained and what the
	# camera reads. _sample_camera_rate is connected for the duration of the case.
	_worst_rise_rate = 0.0
	_last_target_y = INF
	_window_elapsed = 0.0
	_sampling = true

	while ticks < 420:
		_pin_camera(true)
		await get_tree().physics_frame
		ticks += 1
		best_y = maxf(best_y, player.global_position.y)
		if best_y >= STAIRS_TOP_Y - 0.05:
			break

	_sampling = false
	var worst_rate := _worst_rise_rate
	Input.action_release("move_forward")
	Input.action_release("run")

	checks += 1
	if best_y >= STAIRS_TOP_Y - 0.05:
		_ok("%s: reached y=%.2f from %.2f in %d ticks" % [label, best_y, STAIRS_START.y, ticks])
	else:
		_fail("%s: stopped at y=%.2f, %.2f m short of %.2f. StepHeight is %.2f m and the tallest riser is 0.27 m." % [
			label, best_y, STAIRS_TOP_Y - best_y, STAIRS_TOP_Y, float(player.get("StepHeight"))])

	checks += 1
	if worst_rate <= MAX_CAMERA_RISE_PER_SECOND:
		_ok("%s: the camera target rises at no more than %.2f m/s (limit %.2f; an unsmoothed riser would be 14.4)" % [
			label, worst_rate, MAX_CAMERA_RISE_PER_SECOND])
	else:
		_fail("%s: the camera target rose at %.2f m/s (limit %.2f). A step-up is a teleport, so its vertical gain has to be eased out of the camera target rather than handed to it whole - see PlayerCharacter._Process and StepSmoothingHalfLife." % [
			label, worst_rate, MAX_CAMERA_RISE_PER_SECOND])


## A wall across the corridor past the top of the stairs, so the only way on is up it. Nothing tags
## it, so both heights must be refused - the short one is the case that proves opt-in.
func _ledge(label: String, height: float) -> void:
	if not await _load_level():
		return
	var at := Vector3(0.0, 12.05, -172.0)
	_place(at)

	obstacle = StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(30.0, height, 4.0)
	shape.shape = box
	obstacle.add_child(shape)
	level.add_child(obstacle)
	obstacle.global_position = Vector3(at.x, at.y - 0.05 + height * 0.5, at.z - 4.0)

	var best_y := at.y
	var ticks := 0
	Input.action_press("move_forward")
	Input.action_press("run")
	while ticks < 240:
		_pin_camera(true)
		await get_tree().physics_frame
		ticks += 1
		best_y = maxf(best_y, player.global_position.y)
	Input.action_release("move_forward")
	Input.action_release("run")

	var target := at.y + height
	checks += 1
	if best_y < target - 0.05:
		_ok("%s: got no higher than y=%.2f from %.2f, %.2f m short of the top" % [
			label, best_y, at.y, target - best_y])
	else:
		_fail("%s: climbed to y=%.2f, which it should not reach. StepHeight of %.2f m is letting the character mount things the level expects him to jump onto." % [
			label, best_y, float(player.get("StepHeight"))])


## Descending, driven the other way along z. The bound is burst LENGTH rather than total airborne
## ticks, and that is the meaningful test rather than a softened one: CheckForFall commits to a fall
## after TICKS_TO_WAIT_FOR_FALL consecutive ticks off the floor, and only a committed fall changes
## the clip - UpdateAnimation replays on a change and nothing else. A one-tick gap is invisible.
##
## It cannot be zero either: TryStepDown places the body with move_and_collide, which does not set
## is_on_floor(). That flag only returns on the next move_and_slide, so a successful step down still
## reads as one airborne tick by construction.
func _descent() -> void:
	if not await _load_level():
		return
	_place(DESCEND_START)

	var airborne_ticks := 0
	var bursts := 0
	var current := 0
	var longest := 0
	var was_airborne := false
	var ticks := 0

	# Camera pinned looking +Z and "back" held, so he walks down the flight the way he came up.
	Input.action_press("move_back")
	while ticks < 420:
		_pin_camera(true)
		await get_tree().physics_frame
		ticks += 1
		if ticks > SETTLE_TICKS:
			var airborne := not player.is_on_floor()
			if airborne:
				airborne_ticks += 1
				current += 1
				longest = maxi(longest, current)
				if not was_airborne:
					bursts += 1
			else:
				current = 0
			was_airborne = airborne
		if player.global_position.z > DESCEND_END_Z:
			break
	Input.action_release("move_back")

	# One check, one verdict. An earlier version counted the progress guard as a check of its own and
	# then said nothing when it passed, which the never-reported-a-verdict tally caught.
	checks += 1
	if player.global_position.z <= DESCEND_END_Z:
		_fail("walking down: only reached z=%.2f of %.2f in %d ticks, so the descent was never measured" % [
			player.global_position.z, DESCEND_END_Z, ticks])
	elif longest < TICKS_TO_WAIT_FOR_FALL:
		_ok("walking down, the longest gap off the floor is %d tick(s) over %d, under the %d that CheckForFall treats as a fall (%d gaps, %d ticks total)" % [
			longest, ticks, TICKS_TO_WAIT_FOR_FALL, bursts, airborne_ticks])
	else:
		_fail("walking down, he was off the floor for %d consecutive ticks - CheckForFall commits after %d, and every commit restarts the walk clip. %d gaps over %d ticks. floor_snap_length is %.2f m; note Godot's snap does not fire at the moment the tread is lost, which is why TryStepDown exists." % [
			longest, TICKS_TO_WAIT_FOR_FALL, bursts, ticks, player.floor_snap_length])


## The filter is opt-in, so a typo in LevelShell.ClimbableMeshes silently disables the feature and
## the character sticks with nothing to explain it. Assert the tags reached real bodies.
func _check_tagging() -> void:
	checks += 1
	var group := String(player.get("ClimbableGroup"))
	var names: Array[String] = []
	for n in get_tree().get_nodes_in_group(group):
		names.append(String(n.name))
	names.sort()

	var wanted := ["polySurface18_col", "polySurface32_col"]
	var missing: Array[String] = []
	for w in wanted:
		if not names.has(w):
			missing.append(w)

	if missing.is_empty():
		_ok("group '%s' holds %s" % [group, str(names)])
	else:
		_fail("group '%s' is missing %s; it holds %s. A name in LevelShell.ClimbableMeshes that matches no mesh is silent - the character just sticks." % [
			group, str(missing), str(names)])


func _enable_backfaces(n: Node) -> void:
	if n is CollisionShape3D and (n as CollisionShape3D).shape is ConcavePolygonShape3D:
		((n as CollisionShape3D).shape as ConcavePolygonShape3D).backface_collision = true
	for c in n.get_children():
		_enable_backfaces(c)


func _finish() -> void:
	print("")
	if reported < checks:
		print("  FAIL  %d of %d checks never reported a verdict - one aborted partway through." % [
			checks - reported, checks])
		failures += checks - reported
	if failures == 0:
		print("PASS: %d checks" % checks)
	else:
		print("FAIL: %d of %d checks failed" % [failures, checks])
	get_tree().quit(1 if failures > 0 else 0)


func _ok(m: String) -> void:
	reported += 1
	print("  ok    ", m)


func _fail(m: String) -> void:
	failures += 1
	reported += 1
	print("  FAIL  ", m)
