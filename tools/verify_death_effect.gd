# Checks that the death post-process is actually IN the level and reacts to dying.
#
#   godot-mono --headless --path . --script tools/verify_death_effect.gd
#
# WHY THIS EXISTS, SEPARATELY FROM verify_death_shader.gd. That one renders
# death_distortion.gdshader through a synthetic SubViewport and checks its arithmetic against
# an unshaded render. It passed for as long as the shader has existed - and for that whole time
# NOTHING IN THE GAME USED IT. The shader was written, the driving script was written, the
# ledger recorded the effect as done, and no scene ever instantiated either, so the vignette
# and chromatic aberration that Unity's camera carried never appeared on screen once. It was
# reported from play as a detail still missing, not by any check.
#
# The gap was structural: every assertion was about the shader in isolation, so no amount of
# running them could notice that the level did not have it. These assertions are about the
# LEVEL - the node exists, it carries the material and the script, it sits under the fade so a
# fade to black still covers it, and its uniforms move when the player dies.
extends SceneTree

var level: Node3D
var overlay: ColorRect
var material: ShaderMaterial
var manager: Node
var failures := 0
var checks := 0


func _initialize() -> void:
	level = (load("res://scenes/level.tscn") as PackedScene).instantiate()
	root.add_child(level)
	await process_frame
	await process_frame

	print("")

	var node := level.get_node_or_null("UI/DeathDistortion")
	checks += 1
	if node == null:
		_fail("the level has no UI/DeathDistortion node; the effect cannot run however good the shader is")
		_finish()
		return
	_ok("the level carries a UI/DeathDistortion node")

	overlay = node as ColorRect
	checks += 1
	if overlay != null:
		_ok("it is a ColorRect, which is what the shader needs to cover the screen")
	else:
		_fail("UI/DeathDistortion is a %s, not a ColorRect" % node.get_class())
		_finish()
		return

	# The script alone is not enough, and neither is the material alone.
	checks += 1
	var script: Script = overlay.get_script()
	if script != null and script.resource_path.ends_with("DeathDistortion.cs"):
		_ok("it runs DeathDistortion.cs, so the death count reaches the uniforms")
	else:
		_fail("it has no DeathDistortion.cs script; the uniforms would never be written")

	material = overlay.material as ShaderMaterial
	checks += 1
	if material != null and material.shader != null \
			and material.shader.resource_path.ends_with("death_distortion.gdshader"):
		_ok("it uses death_distortion.gdshader")
	else:
		_fail("it has no ShaderMaterial using death_distortion.gdshader; the rect would draw flat")

	# It has to cover the view, or it distorts a corner of it.
	var view := root.get_visible_rect().size
	checks += 1
	if overlay.size.x >= view.x and overlay.size.y >= view.y:
		_ok("it covers the whole %d x %d viewport" % [view.x, view.y])
	else:
		_fail("it is %s over a %s viewport; part of the screen would be undistorted"
			% [overlay.size, view])

	# DRAW ORDER. A fade to black has to black out the distortion too, and the pause menu has to
	# sit on top of both. Later children of a CanvasLayer draw over earlier ones, so this must be
	# the first of the three.
	var ui := level.get_node("UI")
	var fade := ui.get_node_or_null("FadeOverlay")
	var pause := ui.get_node_or_null("PausePanel")
	checks += 1
	if fade != null and overlay.get_index() < fade.get_index():
		_ok("it draws under FadeOverlay, so fading to black still covers it")
	else:
		_fail("it draws over FadeOverlay; the fade to black would be distorted rather than black")
	checks += 1
	if pause != null and overlay.get_index() < pause.get_index():
		_ok("it draws under the pause panel")
	else:
		_fail("it draws over the pause panel")

	# Mouse events must pass through a full-screen rect.
	checks += 1
	if overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE:
		_ok("it ignores the mouse, so a full-screen rect does not swallow clicks")
	else:
		_fail("its mouse_filter is %d; a full-screen rect would eat input" % overlay.mouse_filter)

	# ...and now the part that matters to a player: it gets WORSE as they die.
	manager = root.get_node_or_null("GameManager")
	checks += 1
	if manager == null:
		_fail("the GameManager autoload is missing, so nothing drives the effect")
		_finish()
		return
	_ok("the GameManager autoload is present to drive it")

	manager.call("ResetDeaths")
	await process_frame
	var v0: float = material.get_shader_parameter("vignette_intensity")
	var c0: float = material.get_shader_parameter("chromatic_aberration")

	# GameManager writes 0.1 + 0.3 * deathConstant and 2.0 + 8.0 * deathConstant.
	checks += 1
	if is_equal_approx(v0, 0.1) and is_equal_approx(c0, 2.0):
		_ok("at zero deaths it rests at Unity's baseline: vignette %.2f, aberration %.1f px" % [v0, c0])
	else:
		_fail("at zero deaths it is vignette %.3f, aberration %.3f; expected 0.1 and 2.0" % [v0, c0])

	var previous_v := v0
	var previous_c := c0
	var monotonic := true
	for deaths in range(1, 11):
		manager.call("AddDeath")
		await process_frame
		var v: float = material.get_shader_parameter("vignette_intensity")
		var c: float = material.get_shader_parameter("chromatic_aberration")
		if v < previous_v - 0.0001 or c < previous_c - 0.0001:
			monotonic = false
			_fail("death %d made the effect WEAKER: vignette %.3f -> %.3f, aberration %.2f -> %.2f"
				% [deaths, previous_v, v, previous_c, c])
			break
		previous_v = v
		previous_c = c

	checks += 1
	if monotonic:
		_ok("ten deaths only ever worsen it: vignette %.2f -> %.2f, aberration %.1f -> %.1f px"
			% [v0, previous_v, c0, previous_c])

	# The far end, which is where Unity's own numbers land.
	checks += 1
	if is_equal_approx(previous_v, 0.4) and is_equal_approx(previous_c, 10.0):
		_ok("at the death count the curve saturates on, it reaches vignette 0.40, aberration 10.0 px")
	else:
		_fail("saturates at vignette %.3f, aberration %.3f; expected 0.4 and 10.0"
			% [previous_v, previous_c])

	# Dying is not permanent - a reset has to take the screen back.
	manager.call("ResetDeaths")
	await process_frame
	checks += 1
	if is_equal_approx(float(material.get_shader_parameter("vignette_intensity")), 0.1):
		_ok("resetting the deaths clears the effect back to baseline")
	else:
		_fail("after a reset the vignette is %.3f, not back to 0.1"
			% float(material.get_shader_parameter("vignette_intensity")))

	_finish()


func _finish() -> void:
	print("")
	if failures > 0:
		print("FAIL: %d of %d checks failed" % [failures, checks])
		quit(1)
	else:
		print("PASS: %d checks" % checks)
		quit(0)


func _ok(m: String) -> void:
	print("  ok    ", m)


func _fail(m: String) -> void:
	failures += 1
	print("  FAIL  ", m)
