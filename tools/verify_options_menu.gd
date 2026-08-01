# Drives the options screen the way a player without a mouse would.
#
#   godot-mono --headless --path . --script tools/verify_options_menu.gd
#
# The options screen is a DELIBERATE ADDITION; GameSettings owns the state and verify_settings.gd
# and verify_rebind.gd cover it. What is left, and what this file is for, is whether a player can
# actually OPERATE the screen - which is exactly the class of bug verify_main_menu.gd's header warns
# about, where eleven checks passed while WASD navigation was completely broken because every one of
# them asked "did the first press do something" rather than "can the player reach the second row".
#
# So the navigation checks here assert that focus moved FROM A NAMED CONTROL TO A NAMED CONTROL, and
# that A and D change a slider's VALUE rather than moving focus off it. Both halves matter: the
# arrows and the stick adjust a slider for free because Range handles ui_left/ui_right itself, while
# A and D reach nothing at all without MenuNavigation - the same asymmetry, one layer down.
extends SceneTree

const SECTIONS := ["GameSection", "SoundSection", "VideoSection", "InputSection"]
const TABS := ["GameTab", "SoundTab", "VideoTab", "InputTab"]

const SCRATCH := "user://settings_options_verify.cfg"

var menu: Control
var settings: Node
var failures := 0
var checks := 0


func _initialize() -> void:
	menu = (load("res://scenes/options_menu.tscn") as PackedScene).instantiate()
	root.add_child(menu)
	# root IS the viewport - Window extends Viewport - and root.get_viewport() returns null this
	# early in a --script run. Same note as verify_main_menu.gd.
	await process_frame
	await process_frame

	settings = root.get_node_or_null("/root/GameSettings")

	# THIS SCREEN DRIVES THE REAL AUTOLOAD, so it would otherwise save to the real
	# user://settings.cfg - dragging a slider here marks the settings dirty and the debounce writes
	# them out. The first run of this file did exactly that and overwrote the developer's own file.
	# GameSettings deliberately loads nothing under --script, but SAVING is a separate path and the
	# guard does not cover it, which is the whole reason ConfigPath is settable.
	if settings != null:
		settings.set("ConfigPath", SCRATCH)

	print("")
	_check_process_mode()
	await _check_open_focuses_something()
	await _check_tabs_switch_sections()
	await _check_rows_are_reachable()
	await _check_ad_adjusts_a_slider()
	await _check_slider_reaches_the_engine()
	await _check_bindings_are_readable()
	await _check_reset_button()
	await _check_escape_closes()
	await _check_back_returns_focus()

	# Put the mix and the bindings back, then make sure NOTHING IS STILL PENDING before we finish.
	#
	# The order here is load-bearing and was got wrong first time. Restoring ConfigPath at the end
	# looked tidy and was the bug: GameSettings flushes on _ExitTree, so the pending write from these
	# very resets landed on the real user://settings.cfg after the path had been handed back. Save to
	# the scratch path instead - which clears the dirty flag - and leave ConfigPath alone. The process
	# is exiting, so there is nothing left to restore it for.
	if settings != null:
		settings.call("ResetSection", 1)
		settings.call("ResetAllBindings")
		settings.call("Save")
		if FileAccess.file_exists(SCRATCH):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRATCH))

	print("")
	if failures == 0:
		print("PASS: %d checks" % checks)
	else:
		print("FAIL: %d of %d checks failed" % [failures, checks])
	quit(1 if failures > 0 else 0)


## Reached from the pause menu this runs while SceneTree.paused is true, and a pausable options
## screen could never be closed again - the same deadlock verify_pause_menu.gd guards.
func _check_process_mode() -> void:
	checks += 1
	if menu.process_mode == Node.PROCESS_MODE_ALWAYS:
		_ok("the options screen is ProcessMode.Always, so it works while the game is paused")
	else:
		_fail("process_mode is %d; opened from the pause menu it would freeze and never close"
			% menu.process_mode)


func _check_open_focuses_something() -> void:
	menu.call("Open", null)
	await process_frame

	checks += 1
	var owner := root.gui_get_focus_owner()
	if owner != null:
		_ok("opening the screen focuses %s, so a gamepad can use it immediately" % owner.name)
	else:
		_fail("nothing is focused after opening; a stray Enter would do something unpredictable")


func _check_tabs_switch_sections() -> void:
	for i in TABS.size():
		var tab: Button = menu.get_node("%" + TABS[i])
		tab.emit_signal("pressed")
		await process_frame

		var wrong: Array[String] = []
		for j in SECTIONS.size():
			var section: Control = menu.get_node("%" + SECTIONS[j])
			if section.visible != (i == j):
				wrong.append("%s visible=%s" % [SECTIONS[j], section.visible])

		checks += 1
		if wrong.is_empty():
			_ok("%s shows %s and hides the other three" % [TABS[i], SECTIONS[i]])
		else:
			_fail("%s left the wrong sections showing: %s" % [TABS[i], str(wrong)])

		# THE ACTIVE TAB MUST BE MARKED INDEPENDENTLY OF FOCUS. Focus moves to a slider the moment
		# the player adjusts anything, and when the highlight was only the focus ring the previously
		# focused tab stayed lit over a different section's rows. Every headless check passed while
		# that was true; it took a screenshot to see it.
		var marked: Array[String] = []
		for j in TABS.size():
			var other: Button = menu.get_node("%" + TABS[j])
			if other.button_pressed:
				marked.append(TABS[j])

		checks += 1
		if marked == [TABS[i]]:
			_ok("and %s is the only tab marked active, whatever has focus" % TABS[i])
		else:
			_fail("with %s showing, the tabs marked active are %s" % [SECTIONS[i], str(marked)])


## THE CHECK THAT MATTERS FOR NAVIGATION. Not "a key did something" but "focus moved from this named
## slider to that named slider", in both directions.
func _check_rows_are_reachable() -> void:
	_show("SoundSection")
	await process_frame

	var sliders := _controls_of("SoundSection", "HSlider")
	checks += 1
	if sliders.size() < 3:
		_fail("expected at least three volume sliders to navigate between, found %d" % sliders.size())
		return
	_ok("the Sound section has %d volume sliders" % sliders.size())

	await _navigates("S", KEY_S, sliders[0], sliders[1])
	await _navigates("S", KEY_S, sliders[1], sliders[2])
	await _navigates("W", KEY_W, sliders[2], sliders[1])
	await _navigates("the down arrow", KEY_DOWN, sliders[0], sliders[1])
	await _navigates("the up arrow", KEY_UP, sliders[1], sliders[0])


## A and D must reach the slider. Left unhandled they do nothing at all; handled as navigation they
## would move focus off the slider and it could never be adjusted with WASD.
func _check_ad_adjusts_a_slider() -> void:
	_show("SoundSection")
	await process_frame

	var slider: Range = _controls_of("SoundSection", "HSlider")[1]
	slider.value = 0.5
	slider.grab_focus()
	await process_frame

	await _press(KEY_D)
	checks += 1
	if slider.value > 0.5:
		_ok("D raises the focused slider (%.2f -> %.2f)" % [0.5, slider.value])
	else:
		_fail("D left the slider at %.2f; WASD cannot adjust it" % slider.value)

	checks += 1
	if root.gui_get_focus_owner() == slider:
		_ok("and focus stays on the slider rather than walking off sideways")
	else:
		_fail("D moved focus to %s instead of adjusting the slider"
			% ["nothing" if root.gui_get_focus_owner() == null else root.gui_get_focus_owner().name])

	var raised := slider.value
	await _press(KEY_A)
	checks += 1
	if slider.value < raised:
		_ok("A lowers it again (%.2f -> %.2f)" % [raised, slider.value])
	else:
		_fail("A did not lower the slider; it sat at %.2f" % slider.value)


## A slider that moves but changes nothing is the failure a screenshot cannot catch.
func _check_slider_reaches_the_engine() -> void:
	if settings == null:
		_fail("the GameSettings autoload is missing; the sliders cannot reach anything")
		return

	_show("SoundSection")
	await process_frame

	var index := AudioServer.get_bus_index("Music")
	var authored: float = settings.call("AuthoredBusDb", "Music")

	# The Music row is the second slider: Master, Music, Ambience, Whispers, Footsteps.
	var slider: Range = _controls_of("SoundSection", "HSlider")[1]
	slider.value = 0.25
	await process_frame

	checks += 1
	var db := AudioServer.get_bus_volume_db(index)
	if db < authored - 1.0:
		_ok("dragging the Music slider to 25%% actually moves the bus (%.2f -> %.2f dB)" % [authored, db])
	else:
		_fail("the Music bus is still at %.2f dB after the slider moved; the row is decorative" % db)

	slider.value = 1.0
	await process_frame

	checks += 1
	if abs(AudioServer.get_bus_volume_db(index) - authored) < 0.01:
		_ok("and putting it back to 100%% restores the layout's %.4f dB exactly" % authored)
	else:
		_fail("returning the slider to 100%% left the bus at %.4f, not %.4f"
			% [AudioServer.get_bus_volume_db(index), authored])


## A binding row that reads "—" or a raw number tells the player nothing about which key to press.
func _check_bindings_are_readable() -> void:
	_show("InputSection")
	await process_frame

	var buttons := _controls_of("InputSection", "Button")
	checks += 1
	if buttons.size() < 16:
		_fail("expected two binding buttons for each of the eight actions, found %d" % buttons.size())
		return
	_ok("every remappable action has a keyboard and a gamepad button (%d in total)" % buttons.size())

	var unreadable: Array[String] = []
	for b in buttons:
		var text: String = b.text
		if text.is_empty() or text == "—" or text.is_valid_int():
			unreadable.append(text)

	checks += 1
	if unreadable.is_empty():
		_ok("all of them read as a named input (first four: %s)"
			% str([buttons[0].text, buttons[1].text, buttons[2].text, buttons[3].text]))
	else:
		_fail("these binding buttons are unreadable: %s" % str(unreadable))


func _check_reset_button() -> void:
	if settings == null:
		return

	_show("SoundSection")
	await process_frame

	var slider: Range = _controls_of("SoundSection", "HSlider")[1]
	slider.value = 0.3
	await process_frame

	menu.get_node("%ResetButton").emit_signal("pressed")
	await process_frame

	checks += 1
	if abs(slider.value - 1.0) < 0.001:
		_ok("Reset This Section puts the Sound sliders back to 100% and the control shows it")
	else:
		_fail("after a reset the slider still reads %.2f; the control and the setting disagree"
			% slider.value)


## The deadlock this screen must never cause. Escape has to close the options and nothing else.
func _check_escape_closes() -> void:
	menu.call("Open", null)
	await process_frame

	await _press(KEY_ESCAPE)

	checks += 1
	if not menu.visible:
		_ok("Escape closes the options screen")
	else:
		_fail("Escape left the options screen open; there would be no way out without a mouse")


func _check_back_returns_focus() -> void:
	# Stands in for the button that opened the screen in either host.
	var opener := Button.new()
	opener.text = "Options"
	root.add_child(opener)
	await process_frame

	menu.call("Open", opener)
	await process_frame

	menu.get_node("%BackButton").emit_signal("pressed")
	await process_frame

	checks += 1
	if not menu.visible:
		_ok("Back closes the screen")
	else:
		_fail("Back left the screen open")

	checks += 1
	if root.gui_get_focus_owner() == opener:
		_ok("and hands focus back to the button that opened it, so a pad player keeps their place")
	else:
		_fail("focus went to %s rather than back to the opening button"
			% ["nothing" if root.gui_get_focus_owner() == null else root.gui_get_focus_owner().name])

	opener.queue_free()


# ------------------------------------------------------------------ helpers

func _show(section: String) -> void:
	var tab := "GameTab"
	match section:
		"SoundSection": tab = "SoundTab"
		"VideoSection": tab = "VideoTab"
		"InputSection": tab = "InputTab"
	menu.call("Open", null)
	menu.get_node("%" + tab).emit_signal("pressed")


## The rows are built in code, so they are found by walking rather than by path.
func _controls_of(section: String, type: String) -> Array:
	var out: Array = []
	_collect(menu.get_node("%" + section + "/Rows"), type, out)
	return out


func _collect(node: Node, type: String, out: Array) -> void:
	for child in node.get_children():
		if child.get_class() == type:
			out.append(child)
		_collect(child, type, out)


func _navigates(label: String, code: int, from: Control, to: Control) -> void:
	root.gui_release_focus()
	await process_frame
	from.grab_focus()
	await process_frame
	await _press(code)

	checks += 1
	var got := root.gui_get_focus_owner()
	if got == to:
		_ok("%s moves focus %s -> %s" % [label, _describe(from), _describe(to)])
	else:
		_fail("%s from %s landed on %s, expected %s"
			% [label, _describe(from), _describe(got), _describe(to)])


## Generated controls have engine-assigned names, so identify them by row instead.
func _describe(control: Control) -> String:
	if control == null:
		return "nothing"
	var row := control.get_parent()
	if row != null and row.get_child_count() > 0 and row.get_child(0) is Label:
		return "the \"%s\" row" % row.get_child(0).text
	return control.name


func _press(code: int) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.physical_keycode = code
		ev.pressed = pressed
		Input.parse_input_event(ev)
		await process_frame


func _ok(m: String) -> void:
	print("  ok    ", m)


func _fail(m: String) -> void:
	failures += 1
	print("  FAIL  ", m)
