# Drives the pause menu and checks each consequence of Unity's ToggleMenuPausa.
#
#   godot-mono --headless --path . --script tools/verify_pause_menu.gd
#
# Unity flipped four things per toggle: the panel's active state, Time.timeScale between
# 1 and 0, the cursor lock between Locked and None, and cursor visibility. Godot's
# equivalents are Visible, SceneTree.paused, and Input.mouse_mode.
#
# The failure worth guarding against is a deadlock: SceneTree.paused stops every node
# whose process_mode is inherited, so if the pause menu itself is pausable then Escape
# pauses the game and is never heard again. That is why the node and the panel are
# ProcessMode.Always, and why this checks that a SECOND toggle actually resumes.
#
# Mouse mode is only meaningful with a real display server - the dummy one ignores it and
# reports Visible throughout - so those assertions are skipped unless one is present, and
# say so rather than passing vacuously. Run under xvfb-run to exercise them.
extends SceneTree

var level: Node3D
var menu: Node
var panel: Control
var frame := 0
var failures := 0
var checks := 0
var has_display := false


func _initialize() -> void:
	level = (load("res://scenes/level.tscn") as PackedScene).instantiate()
	root.add_child(level)
	menu = level.get_node("PauseMenu")
	panel = level.get_node("UI/PausePanel")
	has_display = DisplayServer.get_name() != "headless"
	print("display server: %s%s" % [
		DisplayServer.get_name(),
		"" if has_display else "  (mouse-mode checks will be skipped)"])


## Lets the level settle, then hands over to _run once.
##
## _run is a coroutine - the focus checks have to let a frame pass between injecting a key and
## reading the focus owner - and a coroutine cannot BE _process, because the truthy object it returns
## would read as "done" and quit on the first frame. So it is started and left to finish on its own,
## which works because returning false here keeps process_frame firing for it to await; _run prints
## the verdict and quits itself.
func _process(_d: float) -> bool:
	frame += 1
	if frame == 20:
		_run()
	return false


func _run() -> void:
	print("")
	_expect("before pausing", false, Input.MOUSE_MODE_CAPTURED)

	menu.call("Toggle")
	_expect("after one toggle", true, Input.MOUSE_MODE_VISIBLE)

	checks += 1
	if panel.process_mode == Node.PROCESS_MODE_ALWAYS and menu.process_mode == Node.PROCESS_MODE_ALWAYS:
		_ok("the menu and its panel are ProcessMode.Always, so the pause can be lifted")
	else:
		_fail("panel/menu process_mode is %d/%d; a pausable pause menu cannot un-pause itself"
			% [panel.process_mode, menu.process_mode])

	menu.call("Toggle")
	_expect("after a second toggle", false, Input.MOUSE_MODE_CAPTURED)

	# The button must exist and be wired, or the overlay is a dead end.
	checks += 1
	var button := panel.get_node_or_null("%QuitButton")
	if button == null:
		_fail("no %QuitButton under the panel")
	elif button.pressed.get_connections().is_empty():
		_fail("%QuitButton has nothing connected to `pressed`")
	else:
		_ok("%%QuitButton is wired, and reads %s" % [button.text])

	await _check_nothing_focused_until_a_direction()

	_check_options_from_the_pause_menu()

	# GoToMainMenu must clear the pause, or the menu it loads starts frozen: paused
	# survives a scene change, and the main menu's fade is a Tween.
	checks += 1
	menu.call("Toggle")
	menu.set("MainMenuScenePath", "")
	menu.call("GoToMainMenu")
	if paused:
		_fail("GoToMainMenu left the tree paused; the main menu would load frozen")
	else:
		_ok("GoToMainMenu clears the pause before leaving")

	print("")
	if failures == 0:
		print("PASS: %d checks" % checks)
	else:
		print("FAIL: %d of %d checks failed" % [failures, checks])
	quit(1 if failures > 0 else 0)


## The pause panel opens with NOTHING focused, exactly like the title screen, and becomes navigable
## the moment the player pushes a direction.
##
## Unity's ToggleMenuPausa focused nothing either, and Main Menu.unity's EventSystem has
## m_FirstSelected null - so a pause panel that opened with a button already highlighted was the odd
## one out in this project rather than the faithful behaviour.
##
## The half that is easy to get wrong is the second one, and verify_main_menu.gd's header records why:
## W and S are bound only to move_*, never to the ui_* actions Godot navigates on, so a menu can arm
## its first button and then be completely unable to reach the second. Both halves are asserted here,
## by name, for the same reason.
func _check_nothing_focused_until_a_direction() -> void:
	var options: Button = panel.get_node_or_null("%OptionsButton")
	var quit_button: Button = panel.get_node_or_null("%QuitButton")
	if options == null or quit_button == null:
		_fail("the pause panel is missing its buttons; the focus behaviour cannot be checked")
		return

	# Start from a resumed game with a stale focus owner, so "nothing focused" has to be the pause
	# doing it rather than an accident of the harness.
	quit_button.grab_focus()
	await process_frame

	menu.call("Toggle")
	await process_frame

	checks += 1
	var owner := root.gui_get_focus_owner()
	if owner == null:
		_ok("pausing focuses nothing, matching the title screen")
	else:
		_fail("pausing left %s focused; the panel should open with nothing highlighted" % owner.name)

	await _press(KEY_DOWN)
	checks += 1
	if root.gui_get_focus_owner() == options:
		_ok("the down arrow then arms Options, the first button")
	else:
		_fail("the down arrow armed %s, expected Options" % _name_of(root.gui_get_focus_owner()))

	# ARMING IS NOT ENOUGH. Focus must then move between named buttons.
	await _press(KEY_DOWN)
	checks += 1
	if root.gui_get_focus_owner() == quit_button:
		_ok("and a second press navigates on to Exit, so arming is not sticky")
	else:
		_fail("a second press left focus on %s" % _name_of(root.gui_get_focus_owner()))

	await _navigates("W", KEY_W, quit_button, options)
	await _navigates("S", KEY_S, options, quit_button)

	# A key that is not a direction must not arm anything, or this becomes "any key focuses".
	root.gui_release_focus()
	await process_frame
	await _press(KEY_P)
	checks += 1
	if root.gui_get_focus_owner() == null:
		_ok("a non-directional key is ignored")
	else:
		_fail("P armed %s" % _name_of(root.gui_get_focus_owner()))

	# And none of this may fire while the game is running, or a direction pressed to move the
	# character would drag focus onto a hidden pause button.
	menu.call("Toggle")
	await process_frame
	root.gui_release_focus()
	await process_frame
	await _press(KEY_DOWN)
	checks += 1
	if root.gui_get_focus_owner() == null:
		_ok("with the game running, a direction arms nothing - the panel is not listening")
	else:
		_fail("while unpaused, the down arrow focused %s" % _name_of(root.gui_get_focus_owner()))


func _navigates(label: String, code: int, from: Button, to: Button) -> void:
	root.gui_release_focus()
	await process_frame
	from.grab_focus()
	await process_frame
	await _press(code)

	checks += 1
	if root.gui_get_focus_owner() == to:
		_ok("%s moves focus %s -> %s" % [label, from.name, to.name])
	else:
		_fail("%s from %s landed on %s, expected %s"
			% [label, from.name, _name_of(root.gui_get_focus_owner()), to.name])


func _press(code: int) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.physical_keycode = code
		ev.pressed = pressed
		Input.parse_input_event(ev)
		await process_frame


func _name_of(control: Control) -> String:
	return "nothing" if control == null else control.name


## The options screen is a DELIBERATE ADDITION reachable from here, and the failure it must never
## cause is a specific one: Escape inside the options resuming the game with the options panel still
## drawn over it and the mouse captured behind it. Every claim below is about the player being able
## to get back out.
func _check_options_from_the_pause_menu() -> void:
	var button := panel.get_node_or_null("%OptionsButton")

	checks += 1
	if button == null:
		_fail("no %OptionsButton under the panel; the options screen is unreachable in game")
		return
	elif button.pressed.get_connections().is_empty():
		_fail("%OptionsButton has nothing connected to `pressed`")
		return
	else:
		_ok("%%OptionsButton is wired, and reads %s" % [button.text])

	# Moving QuitButton into a VBox must not break the unique-name lookup PauseMenu.cs relies on.
	checks += 1
	if panel.get_node_or_null("%QuitButton") != null:
		_ok("%QuitButton still resolves by unique name after being moved into the button column")
	else:
		_fail("%QuitButton no longer resolves; unique names are scoped to the scene owner, not the parent")

	var options: Control = null
	for child in panel.get_children():
		if child.name == "OptionsMenu":
			options = child

	checks += 1
	if options == null:
		_fail("the pause panel did not mount an OptionsMenu")
		return
	_ok("the pause menu mounts the same options scene the main menu uses")

	checks += 1
	if options.process_mode == Node.PROCESS_MODE_ALWAYS:
		_ok("and it is ProcessMode.Always, so it is not frozen by the pause that opened it")
	else:
		_fail("the options screen is process_mode %d; it would freeze the moment it opened"
			% options.process_mode)

	# Pause, then open options. The game must STAY paused.
	menu.call("Toggle")
	button.emit_signal("pressed")

	checks += 1
	if options.visible and panel.visible and self.paused:
		_ok("opening options from the pause menu leaves the game paused and the panel showing")
	else:
		_fail("opening options gave options=%s panel=%s paused=%s; all three should hold"
			% [options.visible, panel.visible, self.paused])

	checks += 1
	if not has_display or Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		_ok("the cursor stays visible, so the options screen is usable")
	else:
		_fail("mouse_mode is %d with the options open; the screen would be unclickable" % Input.mouse_mode)

	# With options open, Exit must be unreachable - hidden controls cannot take focus, so no
	# navigation can land on "quit to menu" from inside the options.
	checks += 1
	var quit_button := panel.get_node("%QuitButton")
	if not quit_button.is_visible_in_tree():
		_ok("Exit is hidden while options are open, so no focus walk can reach it")
	else:
		_fail("Exit is still visible behind the options screen and could be focused")

	# THE CHECK THIS WHOLE BLOCK EXISTS FOR. One Escape closes options and nothing else.
	options.call("Close")

	checks += 1
	if not options.visible and panel.visible and self.paused:
		_ok("closing options returns to the pause menu WITHOUT resuming the game")
	else:
		_fail("closing options gave options=%s panel=%s paused=%s; the game must still be paused"
			% [options.visible, panel.visible, self.paused])

	checks += 1
	if quit_button.is_visible_in_tree():
		_ok("and Exit comes back")
	else:
		_fail("Exit stayed hidden after the options closed; the pause menu is now a dead end")

	# And a second toggle still resumes, as it always did.
	menu.call("Toggle")
	_expect("after closing options and toggling again", false, Input.MOUSE_MODE_CAPTURED)


## `want_paused`, not `paused`: this script extends SceneTree, so a parameter called
## `paused` shadows the tree's own property and turns the comparison below into
## `paused == paused`, which passes no matter what the tree is doing. That happened.
func _expect(label: String, want_paused: bool, mouse: int) -> void:
	checks += 1
	if panel.visible == want_paused and self.paused == want_paused:
		_ok("%s: panel %s, tree %s" % [
			label, "shown" if want_paused else "hidden",
			"paused" if want_paused else "running"])
	else:
		_fail("%s: panel visible=%s tree paused=%s, expected both %s" % [
			label, panel.visible, self.paused, want_paused])

	if not has_display:
		return
	checks += 1
	if Input.mouse_mode == mouse:
		_ok("%s: mouse_mode=%d as expected" % [label, mouse])
	else:
		_fail("%s: mouse_mode=%d, expected %d" % [label, Input.mouse_mode, mouse])


func _ok(m: String) -> void:
	print("  ok    ", m)


func _fail(m: String) -> void:
	failures += 1
	print("  FAIL  ", m)
