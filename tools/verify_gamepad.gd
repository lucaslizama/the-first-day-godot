# Checks the gamepad movement path: analog speed, analog direction, and the device switch.
#
#   godot-mono --headless --path . --script tools/verify_gamepad.gd
#
# Unity had TWO movement modules, YelenaKeyboardMovement and YelenaGamePadMovement, chosen every
# frame by InputManager.CurrentType. Only the keyboard one was ported at first; this covers the other.
#
# The difference that matters is not "a controller works" but that the gamepad path is ANALOG:
#
#   keyboard   eight-way direction, speed is WalkSpeed or RunSpeed by a held button
#   gamepad    continuous direction, speed is RunSpeed * Clamp01(stick magnitude)
#
# So a half-pushed stick walks by arithmetic rather than by a separate constant, and that is what the
# speed checks below measure - at three magnitudes, not just at full deflection, because a bug that
# ignores magnitude passes any test taken with the stick at 1.0.
#
# Input is injected as real InputEventJoypadMotion events through Input.parse_input_event, so the
# whole chain runs: the event sets PlayerInput.UsingGamepad, the action map turns the axes into
# MoveVector, and PlayerCharacter consumes it. Poking the fields directly would test nothing about
# the wiring, and the wiring is where this feature can fail.
extends SceneTree

const PLAYER := "res://scenes/player.tscn"

## project.godot binds move_left/right to joypad axis 0 and move_forward/back to axis 1.
const AXIS_X := 0
const AXIS_Y := 1

## The action deadzone in project.godot. A stick inside this reads as nothing.
const DEADZONE := 0.2

## Magnitudes to drive the stick to, and the speed each should produce as a fraction of RunSpeed.
## Godot's GetVector rescales the deadzone out, so the effective magnitude is not the raw axis value;
## the expectation is computed from the same rescaling rather than assumed to be the raw number.
const MAGNITUDES := [0.5, 0.75, 1.0]

const SPEED_TOLERANCE := 0.35

var checks := 0
var failures := 0
var player: CharacterBody3D
var input: Node
var frame := 0

## Frames to let the engine run between injecting input and measuring, so the event reaches the
## action state and the player's own _PhysicsProcess has consumed it.
const SETTLE := 8

var _step := 0
var _next_at := 0
var _measured := {}


func _process(_delta: float) -> bool:
	frame += 1
	if frame == 1:
		player = (load(PLAYER) as PackedScene).instantiate() as CharacterBody3D
		root.add_child(player)
		input = root.get_node_or_null("/root/PlayerInput")
		if input == null:
			_fail("PlayerInput autoload is missing")
			return _finish()
		input.set("CanValidateInput", true)
		_next_at = frame + SETTLE
		return false
	if frame < _next_at:
		return false

	# Each step injects input and then yields SETTLE frames before the next one measures what the
	# previous injection produced.
	match _step:
		0:
			_stick(0.0, -1.0)
		1:
			_measured["pad_after_axis"] = input.get("UsingGamepad")
			_key(true)
		2:
			_measured["pad_after_key"] = input.get("UsingGamepad")
			_measured["keyboard_speed"] = Vector2(player.velocity.x, player.velocity.z).length()
			_key(false)
			_stick(0.0, -0.5)
		3:
			_record_speed(0.5)
			_stick(0.0, -0.75)
		4:
			_record_speed(0.75)
			_stick(0.0, -1.0)
		5:
			_record_speed(1.0)
			_stick(0.3827, -0.9239)
		6:
			_measured["diagonal"] = Vector2(player.velocity.x, player.velocity.z)
			_stick(0.0, 0.0)
		_:
			_check_switch()
			_check_speed()
			_check_direction()
			_check_keyboard_still_discrete()
			return _finish()

	_step += 1
	_next_at = frame + SETTLE
	return false


func _record_speed(raw: float) -> void:
	_measured[raw] = {
		"magnitude": (input.get("MoveVector") as Vector2).length(),
		"speed": Vector2(player.velocity.x, player.velocity.z).length(),
	}


func _stick(x: float, y: float) -> void:
	for pair in [[AXIS_X, x], [AXIS_Y, y]]:
		var e := InputEventJoypadMotion.new()
		e.device = 0
		e.axis = int(pair[0])
		e.axis_value = float(pair[1])
		Input.parse_input_event(e)


func _key(pressed: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = KEY_W
	e.physical_keycode = KEY_W
	e.pressed = pressed
	Input.parse_input_event(e)


# Nothing here calls _physics_process by hand. Two reasons it cannot: calling it through `call` does
# not invoke a C# override, and an event handed to Input.parse_input_event does not reach the action
# state until the engine processes it on a later frame. So the checks are spread across REAL frames,
# driven by the step table in _process, and the engine ticks both nodes itself.


func _check_switch() -> void:
	checks += 1
	var on_pad: bool = _measured.get("pad_after_axis", false)
	var on_key: bool = _measured.get("pad_after_key", true)
	if on_pad and not on_key:
		_ok("the device switches both ways: a joypad axis selects the gamepad, a key selects keyboard")
	else:
		_fail("device switch is wrong: gamepad=%s after an axis event, gamepad=%s after a key" % [
			on_pad, on_key])


## Speed must scale with the stick, which is the entire difference from the keyboard path.
func _check_speed() -> void:
	var run: float = float(player.get("RunSpeed"))
	for raw in MAGNITUDES:
		checks += 1
		var got: Dictionary = _measured.get(raw, {})
		var magnitude: float = got.get("magnitude", 0.0)
		var horizontal: float = got.get("speed", 0.0)
		var want: float = run * magnitude
		if magnitude <= 0.0:
			_fail("stick at %.2f produced no MoveVector; is the deadzone %.2f or the axis binding wrong?" % [
				raw, DEADZONE])
		elif absf(horizontal - want) <= SPEED_TOLERANCE:
			_ok("stick %.2f -> magnitude %.2f -> %.2f m/s, which is RunSpeed %.1f times the magnitude" % [
				raw, magnitude, horizontal, run])
		else:
			_fail("stick %.2f gave %.2f m/s, expected %.2f (RunSpeed %.1f * magnitude %.2f). A path that ignores magnitude reads full speed at every deflection." % [
				raw, horizontal, want, run, magnitude])


## Direction must be continuous, not snapped to eight compass points.
func _check_direction() -> void:
	checks += 1
	# 22.5 degrees off the axis - halfway between two of the keyboard's eight directions, so a
	# discrete path cannot produce it.
	var v: Vector2 = _measured.get("diagonal", Vector2.ZERO)
	if v.length() < 0.01:
		_fail("no movement from a diagonal stick")
		return
	var degrees: float = rad_to_deg(atan2(v.x, -v.y))
	var nearest_eighth: float = roundf(degrees / 45.0) * 45.0
	if absf(degrees - nearest_eighth) > 5.0:
		_ok("a 22.5 degree stick moves at %.1f degrees, off the eight-way grid, so the direction is continuous" % degrees)
	else:
		_fail("a 22.5 degree stick moved at %.1f degrees, which is on the eight-way grid - the analog direction is being snapped" % degrees)


## And the keyboard must be untouched: eight-way, WalkSpeed unless run is held.
func _check_keyboard_still_discrete() -> void:
	checks += 1
	var using_gamepad: bool = _measured.get("pad_after_key", true)
	var horizontal: float = _measured.get("keyboard_speed", 0.0)
	var walk: float = float(player.get("WalkSpeed"))
	if using_gamepad:
		_fail("a key did not switch back to the keyboard scheme")
	elif absf(horizontal - walk) <= SPEED_TOLERANCE:
		_ok("the keyboard still walks at %.2f m/s (WalkSpeed %.1f), unaffected by the analog path" % [
			horizontal, walk])
	else:
		_fail("the keyboard moved at %.2f m/s, expected WalkSpeed %.1f" % [horizontal, walk])


func _finish() -> bool:
	print("")
	if failures == 0:
		print("PASS: %d checks" % checks)
	else:
		print("FAIL: %d of %d checks failed" % [failures, checks])
	quit(1 if failures > 0 else 0)
	return true


func _ok(m: String) -> void:
	print("  ok    ", m)


func _fail(m: String) -> void:
	failures += 1
	print("  FAIL  ", m)
