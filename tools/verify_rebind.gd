# Drives key remapping and checks the things that would make the game unplayable if they broke.
#
#   godot-mono --headless --path . --script tools/verify_rebind.gd
#
# Remapping is a DELIBERATE ADDITION - the 2016 original had no such screen - and it is the most
# dangerous part of the options menu, because every bug in it is silent and permanent. A player who
# ends up with `pause` unbound cannot reach the menu to fix it, and a player whose joypad events
# were erased by a keyboard rebind just thinks the controller support is broken.
#
# So the claims here are player-facing, not structural. "Press F and the character jumps, press
# Space and he does not" is the check; "InputMap contains an InputEventKey" is not - that would pass
# while the action carried the key with a `keycode` set instead of a `physical_keycode`, which is the
# bug an AZERTY player would report and a QWERTY developer would never see.
#
# THREE TRAPS THIS FILE PINS, each of which was designed around rather than discovered:
#
#   1. A keyboard rebind must not touch the joypad event beside it, or verify_gamepad.gd's axis
#      assertions become false and controllers stop working.
#   2. Rebuilding an action must not reset its deadzone. ActionEraseAction + ActionAddAction does
#      exactly that, silently, and this project's deadzones are deliberate: 0.2 on the four move_*
#      actions and 0.5 on the rest.
#   3. Bindings must stay physical-only - physical_keycode set, keycode zero - which is how every
#      binding in project.godot is written.
#
# The pristine map is snapshotted from InputMap at the top of this file rather than from GameSettings,
# so the two definitions are compared against each other instead of against themselves. That works
# because the autoload deliberately applies nothing under --script (see GameSettings._Ready), so
# InputMap here is exactly what project.godot shipped.
extends SceneTree

const SCRATCH := "user://settings_rebind_verify.cfg"

const FAMILY_KEYBOARD := 0
const FAMILY_GAMEPAD := 1

const SECTION_INPUT := 3

const ACTIONS := [
	"move_forward", "move_back", "move_left", "move_right",
	"jump", "run", "attack", "pause",
]

var settings: Node
var shipped := {}
var deadzones := {}
var failures := 0
var checks := 0


func _initialize() -> void:
	for action in ACTIONS:
		shipped[action] = _fingerprint(action)
		deadzones[action] = InputMap.action_get_deadzone(action)

	settings = load("res://scripts/Utils/GameSettings.cs").new()
	settings.set("ConfigPath", SCRATCH)
	root.add_child(settings)
	await process_frame
	_clear_scratch()

	print("")
	await _check_rebound_key_moves_the_character()
	_check_joypad_survives_a_keyboard_rebind()
	_check_deadzones_survive()
	_check_binding_is_layout_independent()
	_check_reserved_keys_are_refused()
	_check_duplicates_are_refused()
	_check_nothing_can_be_left_unbound()
	_check_gamepad_side_is_remappable()
	await _check_round_trip()
	_check_reset_restores_project_godot()
	await _check_menu_still_navigable_after_remap()

	# Save FIRST, then delete - GameSettings flushes on _ExitTree, so deleting while a change was
	# still pending had the file written straight back after this script finished.
	settings.call("Save")
	_clear_scratch()

	print("")
	if failures == 0:
		print("PASS: %d checks" % checks)
	else:
		print("FAIL: %d of %d checks failed" % [failures, checks])
	quit(1 if failures > 0 else 0)


## THE CHECK THAT MATTERS. Not "the map changed" but "the game answers the new key and stops
## answering the old one", driven through PlayerInput - the autoload PlayerCharacter actually reads.
func _check_rebound_key_moves_the_character() -> void:
	var input := root.get_node_or_null("/root/PlayerInput")
	if input == null:
		_fail("PlayerInput autoload is missing; the rebind cannot be checked end to end")
		return

	_reset_bindings()

	# Space is jump in project.godot. Confirm that first, or a later pass proves nothing.
	checks += 1
	if await _jumps_on(KEY_SPACE, input):
		_ok("before any rebind, Space makes the game read a jump")
	else:
		_fail("Space does not read as a jump even before rebinding; the harness is not driving PlayerInput")
		return

	var refusal: String = settings.call("Rebind", "jump", _key_event(KEY_F))
	checks += 1
	if refusal == "":
		_ok("Jump accepts F as a new binding")
	else:
		_fail("rebinding Jump to F was refused: %s" % refusal)
		return

	checks += 1
	if await _jumps_on(KEY_F, input):
		_ok("after rebinding, pressing F makes the game read a jump")
	else:
		_fail("F was accepted as the Jump binding but does not make the game jump")

	checks += 1
	if not await _jumps_on(KEY_SPACE, input):
		_ok("and Space no longer does - the old binding is really gone, not merely joined")
	else:
		_fail("Space still reads as a jump after being rebound away; the action kept both keys")

	_reset_bindings()


## verify_gamepad.gd asserts move_left/right on axis 0 and move_forward/back on axis 1. A keyboard
## rebind that erased those would make this game's controller support silently disappear.
func _check_joypad_survives_a_keyboard_rebind() -> void:
	_reset_bindings()

	settings.call("Rebind", "jump", _key_event(KEY_F))
	settings.call("Rebind", "move_forward", _key_event(KEY_I))

	var problems: Array[String] = []
	for action in ACTIONS:
		var want := _events_of_family(shipped[action], "joy")
		var got := _events_of_family(_fingerprint(action), "joy")
		if want != got:
			problems.append("%s: %s -> %s" % [action, str(want), str(got)])

	checks += 1
	if problems.is_empty():
		_ok("rebinding the keyboard leaves every action's gamepad event exactly as project.godot set it")
	else:
		_fail("a keyboard rebind changed gamepad events: %s" % str(problems))

	_reset_bindings()


func _check_deadzones_survive() -> void:
	_reset_bindings()
	settings.call("Rebind", "move_forward", _key_event(KEY_I))
	settings.call("Rebind", "run", _key_event(KEY_G))

	var problems: Array[String] = []
	for action in ACTIONS:
		var got := InputMap.action_get_deadzone(action)
		if abs(got - deadzones[action]) > 0.0001:
			problems.append("%s %.2f -> %.2f" % [action, deadzones[action], got])

	checks += 1
	if problems.is_empty():
		_ok("rebuilding an action leaves its deadzone alone (0.2 on the move_* four, 0.5 elsewhere)")
	else:
		_fail("a rebind reset a deadzone, which changes how far a stick must travel: %s" % str(problems))

	_reset_bindings()


## project.godot writes every key as physical_keycode with "keycode": 0. A rebind that stored a
## keycode would work on the developer's QWERTY board and put the binding on the wrong physical key
## for an AZERTY or Dvorak player.
func _check_binding_is_layout_independent() -> void:
	_reset_bindings()
	settings.call("Rebind", "jump", _key_event(KEY_F))

	var bound: InputEvent = settings.call("BindingFor", "jump", FAMILY_KEYBOARD)

	checks += 1
	if bound is InputEventKey and bound.physical_keycode == KEY_F and bound.keycode == 0:
		_ok("a rebound key is stored physically (physical_keycode=%d, keycode=0), as project.godot writes them"
			% bound.physical_keycode)
	else:
		_fail("the rebound Jump event is %s; expected physical_keycode=%d with keycode 0"
			% [bound, KEY_F])

	# Modifiers must be stripped. `run` is bare Shift, so capturing a key while Shift happens to be
	# held is one keystroke away at all times, and a Shift+W binding cannot be reproduced on purpose.
	var shifted := _key_event(KEY_C)
	shifted.shift_pressed = true
	shifted.ctrl_pressed = true
	settings.call("Rebind", "attack", shifted)
	var attack: InputEvent = settings.call("BindingFor", "attack", FAMILY_KEYBOARD)

	checks += 1
	if attack is InputEventKey and not attack.shift_pressed and not attack.ctrl_pressed:
		_ok("a key captured while Shift and Ctrl were held is stored without them")
	else:
		_fail("modifier flags leaked into the binding: %s" % attack)

	_reset_bindings()


## Binding a gameplay action to Up would make Up move focus DOWN in the menus, because
## MainMenu.NavigateWithMoveKeys matches the move_* action and consumes the event before Godot's own
## ui_up ever runs. Enter is worse: it would fire the action and press the focused button at once.
func _check_reserved_keys_are_refused() -> void:
	_reset_bindings()

	var refused_all := true
	var accepted: Array[String] = []
	for code in [KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_ENTER, KEY_ESCAPE]:
		var refusal: String = settings.call("Rebind", "move_forward", _key_event(code))
		if refusal == "":
			refused_all = false
			accepted.append(OS.get_keycode_string(code))

	checks += 1
	if refused_all:
		_ok("the arrow keys, Enter and Escape are refused as gameplay bindings, so the menus stay operable")
	else:
		_fail("these menu keys were accepted as gameplay bindings: %s" % str(accepted))

	checks += 1
	if _fingerprint("move_forward") == shipped["move_forward"]:
		_ok("a refused rebind leaves the binding exactly as it was")
	else:
		_fail("a refused rebind still changed move_forward: %s" % _fingerprint("move_forward"))

	# Space stays allowed: it is already both jump and ui_accept in the shipped game, so sharing it
	# with a menu key is a collision the port has always had rather than one a rebind introduces.
	#
	# Jump is moved off Space FIRST. Without that this check failed - correctly - with "Space is
	# already used by Jump", which is the duplicate rule doing its job and says nothing at all about
	# whether Space is reserved. The test's premise was wrong, not the code.
	settings.call("Rebind", "jump", _key_event(KEY_F))

	checks += 1
	var space: String = settings.call("Rebind", "run", _key_event(KEY_SPACE))
	if space == "":
		_ok("Space is still bindable once free, since jump and ui_accept have always shared it")
	else:
		_fail("Space was refused (%s); ui_accept sharing it is not a reason to reserve it" % space)

	_reset_bindings()


func _check_duplicates_are_refused() -> void:
	_reset_bindings()

	# W is move_forward in project.godot. Binding jump to it must be refused, not swapped.
	var refusal: String = settings.call("Rebind", "jump", _key_event(KEY_W))

	checks += 1
	if refusal != "" and refusal.contains("Move Forward"):
		_ok("a key already in use is refused and names the row that holds it (\"%s\")" % refusal)
	else:
		_fail("binding Jump to W returned '%s'; expected a refusal naming Move Forward" % refusal)

	checks += 1
	if _fingerprint("jump") == shipped["jump"] and _fingerprint("move_forward") == shipped["move_forward"]:
		_ok("and BOTH bindings are untouched, so no player has to go discover a swap")
	else:
		_fail("a refused duplicate still modified something: jump %s, move_forward %s"
			% [_fingerprint("jump"), _fingerprint("move_forward")])

	# Rebinding an action to the key it already holds is a no-op, not a self-conflict.
	checks += 1
	var same: String = settings.call("Rebind", "move_forward", _key_event(KEY_W))
	if same == "":
		_ok("rebinding an action to the key it already has is accepted rather than reported as a clash")
	else:
		_fail("rebinding move_forward to its own W was refused: %s" % same)

	_reset_bindings()


## Losing `pause` is the unrecoverable one: no menu, no way back, no way to reach these settings
## again. But an empty action is a bug for any of them, so the guard is not special-cased.
func _check_nothing_can_be_left_unbound() -> void:
	_reset_bindings()

	# Rebind everything that will take a rebind, then assert nothing came out empty.
	var codes := [KEY_I, KEY_K, KEY_J, KEY_L, KEY_F, KEY_G, KEY_H, KEY_P]
	for i in ACTIONS.size():
		settings.call("Rebind", ACTIONS[i], _key_event(codes[i]))

	var empty: Array[String] = []
	var no_pad: Array[String] = []
	for action in ACTIONS:
		var events := InputMap.action_get_events(action)
		if events.is_empty():
			empty.append(action)
		if _events_of_family(_fingerprint(action), "joy").is_empty():
			no_pad.append(action)

	checks += 1
	if empty.is_empty():
		_ok("after rebinding all %d actions, not one is left with nothing bound to it" % ACTIONS.size())
	else:
		_fail("these actions ended up unbound: %s" % str(empty))

	checks += 1
	if no_pad.is_empty():
		_ok("and every one still has its gamepad event, so a pad-only player is never stranded either")
	else:
		_fail("these actions lost their gamepad event: %s" % str(no_pad))

	checks += 1
	var pause_events := InputMap.action_get_events("pause")
	if not pause_events.is_empty():
		_ok("pause is still reachable (%d event(s)), so the player can always get back to the menu"
			% pause_events.size())
	else:
		_fail("pause has no events; the game would be unrecoverable")

	_reset_bindings()


func _check_gamepad_side_is_remappable() -> void:
	_reset_bindings()

	var pad := InputEventJoypadButton.new()
	pad.button_index = JOY_BUTTON_RIGHT_SHOULDER
	pad.pressed = true

	var refusal: String = settings.call("Rebind", "jump", pad)
	checks += 1
	if refusal == "":
		_ok("the gamepad side of a binding can be remapped too")
	else:
		_fail("rebinding Jump's gamepad button was refused: %s" % refusal)

	var bound: InputEvent = settings.call("BindingFor", "jump", FAMILY_GAMEPAD)
	checks += 1
	if bound is InputEventJoypadButton and bound.button_index == JOY_BUTTON_RIGHT_SHOULDER:
		_ok("Jump now answers RB on the pad")
	else:
		_fail("Jump's gamepad binding is %s, expected button %d" % [bound, JOY_BUTTON_RIGHT_SHOULDER])

	checks += 1
	var keyboard := _events_of_family(_fingerprint("jump"), "key")
	var shipped_keyboard := _events_of_family(shipped["jump"], "key")
	if keyboard == shipped_keyboard:
		_ok("and the keyboard side is untouched, so the two families really are independent")
	else:
		_fail("a gamepad rebind changed the keyboard binding: %s -> %s" % [shipped_keyboard, keyboard])

	# Four of the eight actions are bound to stick axes, so "the gamepad is remappable" would be
	# false without axis capture.
	var stick := InputEventJoypadMotion.new()
	stick.axis = JOY_AXIS_RIGHT_Y
	stick.axis_value = -1.0

	checks += 1
	var axis_refusal: String = settings.call("Rebind", "move_forward", stick)
	var axis_bound: InputEvent = settings.call("BindingFor", "move_forward", FAMILY_GAMEPAD)
	if axis_refusal == "" and axis_bound is InputEventJoypadMotion \
			and axis_bound.axis == JOY_AXIS_RIGHT_Y and axis_bound.axis_value < 0.0:
		_ok("a stick push can be bound, so the four axis-bound movement actions are remappable as well")
	else:
		_fail("binding move_forward to the right stick gave '%s' and %s" % [axis_refusal, axis_bound])

	# A lazy drift near the deadzone must not be captured as a binding.
	checks += 1
	var drift := InputEventJoypadMotion.new()
	drift.axis = JOY_AXIS_LEFT_X
	drift.axis_value = 0.2
	var drift_refusal: String = settings.call("Rebind", "attack", drift)
	if drift_refusal != "":
		_ok("stick drift inside the deadzone is not captured as a binding")
	else:
		_fail("a 0.2 axis nudge was accepted as a deliberate binding")

	_reset_bindings()


func _check_round_trip() -> void:
	_reset_bindings()
	settings.call("Rebind", "jump", _key_event(KEY_F))
	settings.call("Rebind", "move_forward", _key_event(KEY_I))
	settings.call("Save")

	_reset_bindings()

	var reloaded = load("res://scripts/Utils/GameSettings.cs").new()
	reloaded.set("ConfigPath", SCRATCH)
	root.add_child(reloaded)
	await process_frame
	reloaded.call("Load")

	checks += 1
	var jump: InputEvent = reloaded.call("BindingFor", "jump", FAMILY_KEYBOARD)
	var forward: InputEvent = reloaded.call("BindingFor", "move_forward", FAMILY_KEYBOARD)
	if jump is InputEventKey and jump.physical_keycode == KEY_F \
			and forward is InputEventKey and forward.physical_keycode == KEY_I:
		_ok("rebound keys survive a restart, and come back still physical (keycode=%d)" % jump.keycode)
	else:
		_fail("bindings did not survive the round trip: jump %s, move_forward %s" % [jump, forward])

	# A corrupt binding line must leave the default in force, never an unbound action.
	var file := FileAccess.open(SCRATCH, FileAccess.WRITE)
	file.store_string("[input]\njump=\"wat:nonsense\"\nmove_back=\"key:notanumber\"\n")
	file.close()
	reloaded.call("Load")

	checks += 1
	var recovered := _events_of_family(_fingerprint("jump"), "key")
	if recovered == _events_of_family(shipped["jump"], "key"):
		_ok("an unreadable binding line falls back to project.godot's default rather than unbinding the action")
	else:
		_fail("a corrupt binding line left jump as %s" % str(recovered))

	reloaded.call("ResetAllBindings")
	reloaded.queue_free()
	await process_frame
	_reset_bindings()


## Reset must reproduce project.godot exactly - every event of every action, and every deadzone -
## rather than an approximation of it.
func _check_reset_restores_project_godot() -> void:
	for i in ACTIONS.size():
		settings.call("Rebind", ACTIONS[i], _key_event([KEY_Z, KEY_X, KEY_C, KEY_V, KEY_B, KEY_N, KEY_M, KEY_Q][i]))

	settings.call("ResetAllBindings")

	var problems: Array[String] = []
	for action in ACTIONS:
		if _fingerprint(action) != shipped[action]:
			problems.append("%s: %s != %s" % [action, str(_fingerprint(action)), str(shipped[action])])
		if abs(InputMap.action_get_deadzone(action) - deadzones[action]) > 0.0001:
			problems.append("%s deadzone %.2f != %.2f"
				% [action, InputMap.action_get_deadzone(action), deadzones[action]])

	checks += 1
	if problems.is_empty():
		_ok("Reset reproduces project.godot event-for-event and deadzone-for-deadzone across all %d actions"
			% ACTIONS.size())
	else:
		_fail("Reset did not restore the shipped bindings: %s" % str(problems))


## The consequence a player would notice most and complain about least usefully: the main menu
## navigates on the move_* ACTIONS, so rebinding movement also rebinds menu navigation. That is
## intended - a player who moves with IK should navigate with IK - and what must stay true is that
## the arrows and the pad are unconditional, so the menu can never become unreachable.
func _check_menu_still_navigable_after_remap() -> void:
	_reset_bindings()
	settings.call("Rebind", "move_forward", _key_event(KEY_I))
	settings.call("Rebind", "move_back", _key_event(KEY_K))

	var scene := load("res://scenes/main_menu.tscn") as PackedScene
	var menu := scene.instantiate()
	root.add_child(menu)
	await process_frame
	await process_frame

	var first: Button = menu.get_node("%StartButton")
	if first.disabled:
		first = menu.get_node("%CreditsButton")

	root.gui_release_focus()
	await process_frame
	await _press(KEY_DOWN)
	checks += 1
	if root.gui_get_focus_owner() == first:
		_ok("with movement rebound to I/K, the down arrow still arms the menu's first button")
	else:
		_fail("the down arrow no longer arms the menu after a movement rebind (focus: %s)"
			% root.gui_get_focus_owner())

	root.gui_release_focus()
	await process_frame
	await _press(KEY_K)
	checks += 1
	if root.gui_get_focus_owner() == first:
		_ok("and K, the new move_back, arms it too - menu navigation follows the player's own keys")
	else:
		_fail("K does not arm the menu though move_back is bound to it (focus: %s)"
			% root.gui_get_focus_owner())

	root.gui_release_focus()
	await process_frame
	await _press(KEY_S)
	checks += 1
	if root.gui_get_focus_owner() == null:
		_ok("S no longer does anything, because move_back is no longer bound to it")
	else:
		_fail("S still armed the menu after being rebound away (focus: %s)"
			% root.gui_get_focus_owner())

	menu.queue_free()
	await process_frame
	_reset_bindings()


# ------------------------------------------------------------------ helpers

## A comparable description of everything InputMap holds for an action. Strings rather than the
## events themselves, because two InputEventKeys with identical fields are different objects.
func _fingerprint(action: StringName) -> Array:
	var out: Array[String] = []
	for e in InputMap.action_get_events(action):
		if e is InputEventKey:
			out.append("key:%d:%d:%s" % [e.physical_keycode, e.keycode, e.shift_pressed])
		elif e is InputEventMouseButton:
			out.append("mouse:%d" % e.button_index)
		elif e is InputEventJoypadButton:
			out.append("joyb:%d" % e.button_index)
		elif e is InputEventJoypadMotion:
			out.append("joyaxis:%d:%.1f" % [e.axis, e.axis_value])
		else:
			out.append("other:%s" % e)
	out.sort()
	return out


func _events_of_family(fingerprint: Array, prefix: String) -> Array:
	var out: Array[String] = []
	for entry in fingerprint:
		if prefix == "joy" and entry.begins_with("joy"):
			out.append(entry)
		elif prefix == "key" and (entry.begins_with("key:") or entry.begins_with("mouse:")):
			out.append(entry)
	return out


func _key_event(code: int) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = true
	return ev


func _reset_bindings() -> void:
	settings.call("ResetAllBindings")


## Holds a key, lets PlayerInput poll it on a physics tick, then releases. PlayerInput derives Jump
## from held state in _PhysicsProcess rather than from IsActionJustPressed, so a press and release
## inside one frame would never be seen.
func _jumps_on(code: int, input: Node) -> bool:
	var down := InputEventKey.new()
	down.physical_keycode = code
	down.keycode = code
	down.pressed = true
	Input.parse_input_event(down)

	await physics_frame
	await physics_frame
	var jumped := bool(input.get("Jump"))

	var up := InputEventKey.new()
	up.physical_keycode = code
	up.keycode = code
	up.pressed = false
	Input.parse_input_event(up)
	await physics_frame
	await physics_frame

	return jumped


func _press(code: int) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.physical_keycode = code
		ev.pressed = pressed
		Input.parse_input_event(ev)
		await process_frame


func _clear_scratch() -> void:
	if FileAccess.file_exists(SCRATCH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRATCH))


func _ok(m: String) -> void:
	print("  ok    ", m)


func _fail(m: String) -> void:
	failures += 1
	print("  FAIL  ", m)
