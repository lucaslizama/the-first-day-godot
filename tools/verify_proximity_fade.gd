# Checks the proximity fade: configured consistently, and actually doing something.
#
#   xvfb-run -a godot-mono --path . --script tools/verify_proximity_fade.gd
#
# NOT --headless. The last check renders, and the headless dummy rasteriser cannot; it would
# report an all-black frame and "pass" for the wrong reason, so the render is compared
# against a control taken in the same run rather than against an absolute expectation.
#
# The feature: surfaces fade out as they approach the camera, so geometry between the camera
# and the player stops filling the screen. Needed because the camera holds a hard
# MinimumDistance of 2 m from the player and the starting room is smaller than that, so it
# cannot retreat - measured across the room, 11 to 15 of every 24 view angles put a wall
# between the camera and the player. This is an addition, not a port: the Unity original had
# no distance fade of any kind.
#
# Four things are checked, and the third is the one that would otherwise rot silently.
extends SceneTree

const PROPS_DIR := "res://materials/props"
const SHELL := ["res://materials/level_general.tres", "res://materials/level_transparent.tres"]

## StandardMaterial3D.DISTANCE_FADE_PIXEL_DITHER. Mode 1, PIXEL_ALPHA, is deliberately NOT
## used - it takes these surfaces off the opaque path and changes how the level is lit. See
## shaders/proximity_fade.gdshaderinc.
const WANT_MODE := 2

## The camera never comes closer than this to the player (ThirdPersonCamera.MinimumDistance),
## so anything at or beyond it is at the player's own distance or further. A fade reaching
## that far would start dissolving the ground the player is standing on.
const CAMERA_MINIMUM_DISTANCE := 2.0

## Camera and aim for the render test: half a metre from a wall of the starting room, facing
## it. Without the fade this wall fills the entire frame.
const WALL_CAMERA := Vector3(2.57, 2.0, 4.0)
const WALL_TARGET := Vector3(3.069, 2.0, 4.0)
## The wall covers essentially the whole frame, so removing it must change a large part of
## it. Set well below what was measured (17%) but far above render noise (~0.05%).
const MIN_CHANGED_FRACTION := 0.05
const SIZE := Vector2i(480, 360)
const SETTLE := 90

var near := -1.0
var far := -1.0
var checks := 0
var failures := 0

var vp: SubViewport
var cam: Camera3D
var scene_root: Node
var faded_image: Image
var frame := 0
var stage := 0


func _process(_delta: float) -> bool:
	frame += 1
	if frame == 1:
		_check_shell()
		_check_props()
		_check_range()
		return false

	# Render with the fade on, then again with every fade turned off at runtime, and require
	# the two to differ. Comparing two renders from the same run means no golden image to go
	# stale, and it cannot pass on an all-black frame.
	if frame == 2:
		vp = SubViewport.new()
		vp.size = SIZE
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(vp)
		scene_root = (load("res://scenes/level.tscn") as PackedScene).instantiate()
		vp.add_child(scene_root)
		_release_cameras(scene_root)
		cam = Camera3D.new()
		vp.add_child(cam)
		cam.global_position = WALL_CAMERA
		cam.look_at(WALL_TARGET, Vector3.UP)
		cam.make_current()
		return false

	if frame < SETTLE:
		return false

	if stage == 0:
		faded_image = vp.get_texture().get_image()
		_disable_every_fade()
		stage = 1
		frame = SETTLE - 30  # let the change settle before sampling again
		return false

	_check_effect(faded_image, vp.get_texture().get_image())

	print("")
	if failures == 0:
		print("PASS: %d checks" % checks)
	else:
		print("FAIL: %d of %d checks failed" % [failures, checks])
	quit(1 if failures > 0 else 0)
	return true


## Both shell materials must carry the same two distances, and they set the reference the
## props are then held to.
func _check_shell() -> void:
	checks += 1
	var problems: Array[String] = []
	for path in SHELL:
		var mat := load(path) as ShaderMaterial
		if mat == null:
			problems.append("%s is not a ShaderMaterial" % path)
			continue
		var n = mat.get_shader_parameter("proximity_fade_near")
		var f = mat.get_shader_parameter("proximity_fade_far")
		if n == null or f == null:
			problems.append("%s has no proximity_fade_near/far" % path)
			continue
		if near < 0.0:
			near = float(n)
			far = float(f)
		elif not is_equal_approx(float(n), near) or not is_equal_approx(float(f), far):
			problems.append("%s fades %.3f..%.3f, the others %.3f..%.3f" % [
				path, float(n), float(f), near, far])

	if problems.is_empty():
		_ok("both shell materials fade between %.3f m and %.3f m" % [near, far])
	else:
		_fail("the shell materials disagree or are unset: %s. Run tools/set_proximity_fade.py." % str(problems))


## Every prop material, not a sample: a material added later without a fade is the failure
## this is here to catch, since it would simply keep filling the screen and nothing else
## would complain.
func _check_props() -> void:
	checks += 1
	var dir := DirAccess.open(PROPS_DIR)
	if dir == null:
		_fail("cannot open %s" % PROPS_DIR)
		return

	var problems: Array[String] = []
	var count := 0
	for file in dir.get_files():
		if not file.ends_with(".tres"):
			continue
		var path := "%s/%s" % [PROPS_DIR, file]
		var mat := load(path) as StandardMaterial3D
		if mat == null:
			problems.append("%s is not a StandardMaterial3D" % file)
			continue
		count += 1
		if mat.distance_fade_mode != WANT_MODE:
			problems.append("%s is mode %d, want %d (dither)" % [file, mat.distance_fade_mode, WANT_MODE])
		if not is_equal_approx(mat.distance_fade_min_distance, near) \
				or not is_equal_approx(mat.distance_fade_max_distance, far):
			problems.append("%s fades %.3f..%.3f, the shell %.3f..%.3f" % [
				file, mat.distance_fade_min_distance, mat.distance_fade_max_distance, near, far])

	if problems.is_empty():
		_ok("all %d prop materials dither out between %.3f m and %.3f m, matching the shell" % [
			count, near, far])
	else:
		_fail("prop materials disagree with the shell: %s. Run tools/set_proximity_fade.py." % str(problems))


func _check_range() -> void:
	checks += 1
	if near <= 0.0 or near >= far:
		_fail("the fade range %.3f..%.3f is not increasing; Godot reads min >= max as fading out FAR geometry instead" % [near, far])
	elif far >= CAMERA_MINIMUM_DISTANCE:
		_fail("the fade reaches %.3f m but the camera never comes closer than %.3f m to the player, so the ground under him would dissolve" % [
			far, CAMERA_MINIMUM_DISTANCE])
	else:
		_ok("the fade ends at %.3f m, inside the camera's %.2f m minimum distance" % [
			far, CAMERA_MINIMUM_DISTANCE])


func _check_effect(with_fade: Image, without_fade: Image) -> void:
	checks += 1
	var changed := 0
	var total := with_fade.get_width() * with_fade.get_height()
	for y in with_fade.get_height():
		for x in with_fade.get_width():
			var a := with_fade.get_pixel(x, y)
			var b := without_fade.get_pixel(x, y)
			var diff := absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)
			if diff > 0.02:
				changed += 1
	var fraction := float(changed) / float(total)

	if fraction >= MIN_CHANGED_FRACTION:
		_ok("half a metre from a wall, the fade changes %.1f%% of the frame" % (fraction * 100.0))
	else:
		_fail("turning the fade off changed only %.2f%% of the frame; the wall is not fading. Expected a wall at 0.5 m to be all but gone." % (fraction * 100.0))


func _disable_every_fade() -> void:
	for path in SHELL:
		var mat := load(path) as ShaderMaterial
		if mat != null:
			# 0..0 is off: smoothstep with equal edges returns 1 for anything at or beyond.
			mat.set_shader_parameter("proximity_fade_near", 0.0)
			mat.set_shader_parameter("proximity_fade_far", 0.0)
	var dir := DirAccess.open(PROPS_DIR)
	if dir == null:
		return
	for file in dir.get_files():
		if not file.ends_with(".tres"):
			continue
		var mat := load("%s/%s" % [PROPS_DIR, file]) as StandardMaterial3D
		if mat != null:
			mat.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_DISABLED


func _release_cameras(n: Node) -> void:
	if n is Camera3D:
		(n as Camera3D).current = false
	for c in n.get_children():
		_release_cameras(c)


func _ok(m: String) -> void:
	print("  ok    ", m)


func _fail(m: String) -> void:
	failures += 1
	print("  FAIL  ", m)
