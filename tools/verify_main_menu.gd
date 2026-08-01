# Drives the main menu's focus behaviour, which is deliberately in two halves.
#
#   godot-mono --headless --path . --script tools/verify_main_menu.gd
#
# NOTHING is focused when the menu opens - Main Menu.unity's EventSystem has
# m_FirstSelected null, so Unity highlighted no button either - but the menu must still be
# reachable without a mouse. It becomes reachable the moment the player pushes a DIRECTION:
# arrows, W/A/S/D, d-pad or stick all arm the first button. See MainMenu._Input.
#
# This exists because the bug it guards was invisible. The code once carried a comment
# asserting that Tab would focus the first control when nothing owned focus; it does not,
# Godot's navigation walk starts from the focus owner, and so the menu could only be
# operated with the mouse. Nothing failed, nothing logged, and no check covered it. Case
# "tab alone is inert" below is that false claim, written down as an assertion so it cannot
# be believed again - if a future Godot makes Tab self-starting, that case fails loudly and
# the _Input handler can be reconsidered.
extends SceneTree

# The scene root is a plain Node; MainMenu.cs sits on the Control beneath a CanvasLayer.
var menu: Node
var start_button: Button
var exit_button: Button
var viewport: Viewport
var failures := 0
var checks := 0


func _initialize() -> void:
	var scene := load("res://scenes/main_menu.tscn") as PackedScene
	if scene == null:
		print("FAIL: could not load res://scenes/main_menu.tscn")
		quit(1)
		return

	menu = scene.instantiate()
	root.add_child(menu)
	# root IS the viewport - Window extends Viewport - and root.get_viewport() returns null this
	# early in a --script run, before the tree has settled.
	viewport = root
	await process_frame
	await process_frame

	start_button = menu.get_node("%StartButton")
	exit_button = menu.get_node("%ExitButton")

	print("")
	if start_button.disabled:
		print("NOTE: the level scene is missing, so Start is disabled and Exit is the first button.")

	# The entry state Unity had.
	_expect_focus("nothing is focused when the menu opens", null)

	# The false claim, pinned. Tab cannot self-start, which is the whole reason _Input exists.
	await _tab()
	_expect_focus("tab alone is inert with no focus owner, so it cannot be the way in", null)

	# Each directional family arms the first button.
	await _reset()
	await _key(KEY_DOWN)
	_expect_focus("the down arrow arms the first button", _first_button())

	await _reset()
	await _key(KEY_UP)
	_expect_focus("the up arrow arms the first button", _first_button())

	await _reset()
	await _key(KEY_W)
	_expect_focus("W arms the first button, through the level's own move_forward binding", _first_button())

	await _reset()
	await _key(KEY_A)
	_expect_focus("A arms the first button", _first_button())

	await _reset()
	await _stick(JOY_AXIS_LEFT_Y, 1.0)
	_expect_focus("a push of the left stick arms the first button", _first_button())

	await _reset()
	await _dpad(JOY_BUTTON_DPAD_DOWN)
	_expect_focus("the d-pad arms the first button", _first_button())

	# Arming must not become sticky: once focused, navigation has to work normally, or the
	# menu would be stuck on its first button forever.
	await _reset()
	await _key(KEY_DOWN)
	var armed := viewport.gui_get_focus_owner()
	await _key(KEY_DOWN)
	checks += 1
	var moved := viewport.gui_get_focus_owner()
	if moved != null and moved != armed:
		_ok("a second press navigates on to %s, so arming is not sticky" % moved.name)
	else:
		_fail("a second press left focus on %s; arming is swallowing ordinary navigation"
			% ("nothing" if moved == null else moved.name))

	# ARMING IS NOT ENOUGH, and this half was missed the first time round. W and S are bound
	# only to move_*, never to the ui_* actions Godot navigates on, so they armed the first
	# button and then did nothing at all - the menu looked wired up but WASD could never reach
	# the second button. The stick and d-pad were fine throughout, because ui_down carries them.
	await _navigates("S", KEY_S, start_button, exit_button)
	await _navigates("W", KEY_W, exit_button, start_button)
	await _navigates("the down arrow", KEY_DOWN, start_button, exit_button)
	await _navigates("the up arrow", KEY_UP, exit_button, start_button)
	await _navigates("the stick", JOY_AXIS_LEFT_Y, start_button, exit_button, true)

	# At the end of the column there is nowhere to go, and that must not wrap or clear focus.
	await _reset()
	start_button.grab_focus()
	await process_frame
	await _key(KEY_W)
	_expect_focus("W at the top of the column stays put rather than wrapping", start_button)

	# A/D have no horizontal neighbour here; the press must be harmless, not focus-clearing.
	await _reset()
	start_button.grab_focus()
	await process_frame
	await _key(KEY_D)
	_expect_focus("D in a single column leaves focus alone", start_button)

	# The disabled-Start fallback the old GrabFocus pair also had.
	await _reset()
	var was_disabled := start_button.disabled
	start_button.disabled = true
	await _key(KEY_DOWN)
	_expect_focus("with Start disabled, the arrow arms Exit instead", exit_button)
	start_button.disabled = was_disabled

	# A key that is not a direction must be ignored, or this becomes "any key focuses".
	await _reset()
	await _key(KEY_P)
	_expect_focus("a non-directional key is ignored", null)

	print("")
	if failures > 0:
		print("FAIL: %d of %d checks failed" % [failures, checks])
		quit(1)
	else:
		print("PASS: %d checks" % checks)
		quit(0)


## Focus starts on `from`, the input fires, and focus must land on `to`. Distinct from arming:
## that is about the FIRST press, this is about every press after it.
func _navigates(label: String, code: int, from: Button, to: Button, is_stick := false) -> void:
	await _reset()
	from.grab_focus()
	await process_frame
	if is_stick:
		await _stick(code, 1.0 if to == exit_button else -1.0)
	else:
		await _key(code)
	_expect_focus("%s moves focus %s -> %s" % [label, from.name, to.name], to)


func _first_button() -> Button:
	return exit_button if start_button.disabled else start_button


func _reset() -> void:
	viewport.gui_release_focus()
	await process_frame


func _key(code: Key) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.physical_keycode = code
		ev.pressed = pressed
		Input.parse_input_event(ev)
		await process_frame


func _tab() -> void:
	await _key(KEY_TAB)


func _dpad(button: JoyButton) -> void:
	for pressed in [true, false]:
		var ev := InputEventJoypadButton.new()
		ev.device = 0
		ev.button_index = button
		ev.pressed = pressed
		Input.parse_input_event(ev)
		await process_frame


func _stick(axis: JoyAxis, value: float) -> void:
	for v in [value, 0.0]:
		var ev := InputEventJoypadMotion.new()
		ev.device = 0
		ev.axis = axis
		ev.axis_value = v
		Input.parse_input_event(ev)
		await process_frame


func _expect_focus(label: String, want: Control) -> void:
	checks += 1
	var got := viewport.gui_get_focus_owner()
	if got == want:
		_ok("%s (focus: %s)" % [label, "nothing" if got == null else got.name])
	else:
		_fail("%s - focus is %s, expected %s" % [
			label,
			"nothing" if got == null else got.name,
			"nothing" if want == null else want.name])


func _ok(m: String) -> void:
	print("  ok    ", m)


func _fail(m: String) -> void:
	failures += 1
	print("  FAIL  ", m)
