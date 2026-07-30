extends SceneTree
## Checks the three claims the platform port rests on.
##
## 1. The animation in moving_platform.tscn is plataforma_anim. Unity's six
##    Hermite keys are evaluated here independently and compared against the
##    Bezier track Godot actually stores, sampled every 1/60 s.
##
## 2. An AnimatableBody3D with sync_to_physics carries a CharacterBody3D standing
##    on it, which is what replaced Unity's ParentPlayer script. A rider is stood
##    on a moving platform and its drift compared with the platform's own. If this
##    fails, ParentPlayer has to come back in some form, so it is the check that
##    matters most.
##
## 3. falling_platform.tscn triggers, waits delayCaida, descends at velocidadCaida,
##    snaps back after distanciaDesactivacion, and takes its rider down with it.
##
## Physics here runs in real time, so the whole run takes about ten seconds.
##
## Run: godot --headless --script tools/verify_platforms.gd

## Unity plataforma_anim keys: time, value, inSlope, outSlope.
const KEYS := [
	[0.0, -5.0, -4.4408924e-13, -4.4408924e-13],
	[1.6333334, -0.09493145, 4.5561953, 4.556296],
	[3.3, 5.0, 4.3585947e-05, 4.837529e-05],
	[4.9333334, 0.14997986, -4.4980445, -4.4983535],
	[5.0000005, -0.149982, -4.4983535, -4.4983506],
	[6.633333, -5.0, 4.837633e-05, 4.837633e-05],
]

const RIDE_SECONDS := 2.0

## delayCaida 0.5 + distanciaDesactivacion 10 at velocidadCaida 2, plus margin to
## see the snap back.
const FALL_SECONDS := 6.0

var _frames := 0
var _phase := -1
var _elapsed := 0.0
var _failed := false

var _rider: CharacterBody3D
var _body: Node3D
var _rider_start := 0.0
var _body_start := 0.0
var _max_gap := 0.0

var _platform: Node3D
var _fall_root: Node3D
var _fall_body: Node3D
var _fall_rider: CharacterBody3D
var _moved_at := -1.0
var _descent_from := 0.0
var _descent_start_t := 0.0
var _lowest := 0.0
var _reset_at := -1.0
var _rider_lowest := 0.0

func _process(_d: float) -> bool:
	_frames += 1
	if _frames == 4:
		_check_curve()
		_build_ride()
		_phase = 0
	return false

func _physics_process(delta: float) -> bool:
	if _phase < 0:
		return false

	_elapsed += delta

	if _phase == 0:
		_tick_ride()
		if _elapsed >= RIDE_SECONDS:
			_report_ride()
			_teardown_ride()
			_build_fall()
			_elapsed = 0.0
			_phase = 1
		return false

	_tick_fall()
	if _elapsed >= FALL_SECONDS:
		_report_fall()
		quit(1 if _failed else 0)
		return true
	return false

func _hermite(t: float) -> float:
	for i in KEYS.size() - 1:
		if t < KEYS[i][0] or t > KEYS[i + 1][0]:
			continue
		var dt: float = KEYS[i + 1][0] - KEYS[i][0]
		var u: float = (t - KEYS[i][0]) / dt
		var p0: float = KEYS[i][1]
		var p1: float = p0 + KEYS[i][3] * dt / 3.0
		var p3: float = KEYS[i + 1][1]
		var p2: float = p3 - KEYS[i + 1][2] * dt / 3.0
		var v := 1.0 - u
		return v * v * v * p0 + 3.0 * v * v * u * p1 + 3.0 * v * u * u * p2 + u * u * u * p3
	return KEYS[KEYS.size() - 1][1]

func _check_curve() -> void:
	var n := (load("res://scenes/moving_platform.tscn") as PackedScene).instantiate()
	root.add_child(n)
	var player: AnimationPlayer = n.get_node("AnimationPlayer")
	var clip := player.get_animation("slide")
	var worst := 0.0
	var worst_at := 0.0
	var lo := INF
	var hi := -INF

	# The stored curve is sampled directly rather than by seeking the player: with
	# callback_mode_process on physics, an idle seek does not write the property,
	# so reading Body.position.x here would only ever return its rest value. That
	# the track is actually wired to Body is covered by the ride check, which moves
	# it for real.
	if clip.track_get_path(0) != NodePath("Body:position:x"):
		printerr("FAIL: track 0 targets '%s', not Body:position:x." % clip.track_get_path(0))
		_failed = true

	var steps := int(clip.length * 60.0)
	for i in steps + 1:
		var t: float = minf(float(i) / 60.0, clip.length)
		var got: float = clip.bezier_track_interpolate(0, t)
		lo = minf(lo, got)
		hi = maxf(hi, got)
		var err: float = absf(got - _hermite(t))
		if err > worst:
			worst = err
			worst_at = t

	print("curve: length=%.6f s (Unity 6.633333), loop=%d, range=[%.4f, %.4f] (Unity [-5, 5])" % [
		clip.length, clip.loop_mode, lo, hi,
	])
	print("curve: worst deviation from Unity's Hermite = %.6f m at t=%.3f s" % [worst, worst_at])
	if worst > 0.001:
		printerr("FAIL: the Bezier track does not reproduce plataforma_anim.")
		_failed = true
	n.queue_free()

## Same collider the player scene uses: a 0.3 m capsule whose bottom sits on the
## node origin, so the rider can be dropped a few cm onto a platform's top face.
func _make_rider() -> CharacterBody3D:
	var rider := CharacterBody3D.new()
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.3
	shape.shape = capsule
	shape.position = Vector3(0.0, 1.0, 0.0)
	rider.add_child(shape)
	# FallingPlatform gates on the player, either by type or by this group - the
	# convention CheckpointTeleport established. A bare CharacterBody3D is ignored,
	# correctly, so the stand-in has to join the group to be seen.
	rider.add_to_group("player")
	return rider

## Mirrors PlayerCharacter's grounded state: no horizontal input at all, a
## constant -1 downward bias, one move_and_slide per tick. If a platform only
## carried a rider that was already moving, this would not catch it.
func _drive(rider: CharacterBody3D) -> void:
	rider.velocity = Vector3(0.0, -1.0, 0.0)
	rider.move_and_slide()

func _build_ride() -> void:
	_platform = (load("res://scenes/moving_platform.tscn") as PackedScene).instantiate()
	root.add_child(_platform)
	_body = _platform.get_node("Body")

	_rider = _make_rider()
	root.add_child(_rider)
	_rider.global_position = _body.global_position + Vector3(0.0, 0.05, 0.0)
	_rider_start = _rider.global_position.x
	_body_start = _body.global_position.x

func _tick_ride() -> void:
	_drive(_rider)
	_max_gap = maxf(_max_gap, absf(
		(_rider.global_position.x - _rider_start) - (_body.global_position.x - _body_start)
	))

func _report_ride() -> void:
	var body_moved: float = _body.global_position.x - _body_start
	var rider_moved: float = _rider.global_position.x - _rider_start
	print("ride: over %.2f s the platform moved %.4f m in x, the rider %.4f m (worst gap %.4f m)" % [
		_elapsed, body_moved, rider_moved, _max_gap,
	])
	print("ride: rider grounded=%s, y=%.4f" % [_rider.is_on_floor(), _rider.global_position.y])
	if absf(body_moved) < 0.5:
		printerr("FAIL: the platform barely moved; the animation is not driving it.")
		_failed = true
	elif absf(rider_moved - body_moved) > 0.15:
		printerr("FAIL: the rider did not follow the platform. sync_to_physics does not")
		printerr("      replace ParentPlayer here, and the port needs a carry mechanism.")
		_failed = true
	else:
		print("ride: OK - sync_to_physics carries the rider, ParentPlayer is not needed.")

func _teardown_ride() -> void:
	root.remove_child(_platform)
	root.remove_child(_rider)
	_platform.queue_free()
	_rider.queue_free()

func _build_fall() -> void:
	_fall_root = (load("res://scenes/falling_platform.tscn") as PackedScene).instantiate()
	root.add_child(_fall_root)
	# The root is the AnimatableBody3D itself here, not a wrapper around one.
	_fall_body = _fall_root

	_fall_rider = _make_rider()
	root.add_child(_fall_rider)
	_fall_rider.global_position = _fall_body.global_position + Vector3(0.0, 0.05, 0.0)
	_rider_lowest = _fall_rider.global_position.y

func _tick_fall() -> void:
	_drive(_fall_rider)
	var y: float = _fall_root.position.y

	# First tick where it has actually left its rest height: that is delayCaida.
	if _moved_at < 0.0 and y < -0.001:
		_moved_at = _elapsed
		_descent_from = y
		_descent_start_t = _elapsed

	if y < _lowest:
		_lowest = y
	# Back at rest after having descended: the snap.
	if _moved_at >= 0.0 and _reset_at < 0.0 and _lowest < -1.0 and y >= -0.001:
		_reset_at = _elapsed

	_rider_lowest = minf(_rider_lowest, _fall_rider.global_position.y)

func _report_fall() -> void:
	print("fall: triggered and started moving at t=%.3f s (Unity delayCaida 0.5)" % _moved_at)
	print("fall: lowest point %.3f m (Unity distanciaDesactivacion 10), snapped back at t=%.3f s" % [
		_lowest, _reset_at,
	])
	print("fall: rider followed down to y=%.3f m" % _rider_lowest)

	if _moved_at < 0.0:
		printerr("FAIL: the platform never fell. The trigger did not see the rider.")
		_failed = true
		return
	if absf(_moved_at - 0.5) > 0.1:
		printerr("FAIL: the delay was %.3f s, not delayCaida's 0.5 s." % _moved_at)
		_failed = true
	# The descent covers 10 m at 2 m/s, so it should bottom out just past -10 and
	# never much further: overshooting means the reset never fired.
	if _lowest > -9.9 or _lowest < -10.2:
		printerr("FAIL: descended to %.3f m, expected just past -10." % _lowest)
		_failed = true
	if _reset_at < 0.0:
		printerr("FAIL: the platform never snapped back to its rest position.")
		_failed = true
	elif absf(_reset_at - (_moved_at + 5.0)) > 0.15:
		printerr("FAIL: snapped back at %.3f s; 10 m at 2 m/s puts it at %.3f s." % [
			_reset_at, _moved_at + 5.0,
		])
		_failed = true
	# The stand-in is driven at a fixed -1 m/s, so if the platform did not carry it
	# the most it could sink in the five second descent is about 5 m; carried, it
	# goes down with the platform at 2 m/s and reaches -10. The threshold sits
	# between the two, which is what makes this discriminating rather than decorative.
	if _rider_lowest > -8.0:
		printerr("FAIL: the rider only reached y=%.3f; the platform dropped without it." % _rider_lowest)
		_failed = true
	if not _failed:
		print("fall: OK - delay, speed, reset and carry all match the prefab.")
