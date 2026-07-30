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


func _process(_d: float) -> bool:
	frame += 1
	if frame < 20:
		return false

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
	return true


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
