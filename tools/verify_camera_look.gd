# Checks that the camera looks where the mouse says, in both axes.
#
#   godot-mono --headless --path . --script tools/verify_camera_look.gd
#
# The vertical axis was inverted - pushing the mouse down looked up, aeroplane style.
# The cause is a sign that cancels wrong between the engines rather than a typo:
#
#   Unity's "Mouse Y" is positive when the mouse moves UP.
#   Godot's InputEventMouseMotion.Relative.Y is positive when it moves DOWN.
#
# Unity's scene sets Invert.Vertical = 1, which in the asset means "multiply the input by
# -1". Since RotateVertically(degrees) pitches DOWN for positive degrees, that flag is
# what gave the original mouse-up = look-up. Copying the flag across on top of Godot's
# already-opposite axis inverted it a second time. So the port needs InvertVertical
# false to match, and the whole point of this check is that "matches Unity's flag" and
# "matches Unity's feel" are not the same thing here.
#
# Asserted as a direction, not a sign: where the camera's forward vector actually points
# after a synthetic mouse move. That survives any future refactor of how pitch is stored.
extends SceneTree

const NUDGE := 40.0

var level: Node3D
var camera: Camera3D
var frame := 0
var failures := 0
var checks := 0


func _initialize() -> void:
	level = (load("res://scenes/level.tscn") as PackedScene).instantiate()
	root.add_child(level)
	camera = level.get_node("Camera")


func _process(_d: float) -> bool:
	frame += 1
	if frame < 20:
		return false

	_check_axis("mouse DOWN", Vector2(0.0, NUDGE), "down")
	_check_axis("mouse UP", Vector2(0.0, -NUDGE), "up")
	_check_axis("mouse RIGHT", Vector2(NUDGE, 0.0), "right")
	_check_axis("mouse LEFT", Vector2(-NUDGE, 0.0), "left")

	print("")
	if failures == 0:
		print("PASS: %d checks" % checks)
	else:
		print("FAIL: %d of %d checks failed" % [failures, checks])
	quit(1 if failures > 0 else 0)
	return true


## Feeds one synthetic mouse motion and reports which way the forward vector moved.
func _check_axis(label: String, relative: Vector2, expect: String) -> void:
	checks += 1
	var before := -camera.global_transform.basis.z

	var event := InputEventMouseMotion.new()
	event.relative = relative
	camera._unhandled_input(event)
	# _Process drives ApplyRotation; call the tick directly so this is deterministic.
	camera._process(1.0 / 60.0)

	var after := -camera.global_transform.basis.z
	var dy := after.y - before.y
	# Horizontal: signed angle change about Y, positive meaning the view swung left.
	var yaw_before := atan2(before.x, before.z)
	var yaw_after := atan2(after.x, after.z)
	var dyaw := wrapf(yaw_after - yaw_before, -PI, PI)

	var got := ""
	if absf(relative.y) > 0.0:
		got = "down" if dy < 0.0 else ("up" if dy > 0.0 else "nothing")
		print("   %-12s forward.y %+.4f -> %+.4f  (%s)" % [label, before.y, after.y, got])
	else:
		got = "left" if dyaw > 0.0 else ("right" if dyaw < 0.0 else "nothing")
		print("   %-12s yaw %+.2f deg  (%s)" % [label, rad_to_deg(dyaw), got])

	if got != expect:
		failures += 1
		print("  FAIL  %s should look %s, got %s" % [label, expect, got])
	else:
		print("  ok    %s looks %s" % [label, expect])
