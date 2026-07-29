extends SceneTree

## Numeric checks on the three level shaders.
##
## Stage 1  level_lit    - sphere under one directional light on +X, viewed
##                         orthographically, so the equator sweeps N.L from -1
##                         to 1 against a CPU model of shader_general.
## Stage 2  level_fade   - a vertex-coloured quad with a red ramp, wobble frozen
##                         at speed 0, drawn over an unshaded black backdrop so
##                         blend_mix reduces to src * alpha and the vertex-colour
##                         alpha can be read straight out.
## Stage 3  cake_glow    - sphere, checked by same-frame ratios: the sin(t) pulse
##                         is a common factor across every pixel of one frame, so
##                         ratios isolate the rim exponent regardless of time.
## Stage 4  level_fade   - wobble at speed 2, to confirm the vertex actually
##                         displaces and stays inside its analytic bound.
##
##   godot --path . --script res://tools/verify_level_shaders.gd -- <out_dir>

const SIZE := 800
const ORTHO := 2.4
const SUN_COLOR := Color(1.0, 0.95686275, 0.8392157)

var _viewport: SubViewport
var _out := "/tmp"
var _frame := 0
var _stage := 0
var _repeat := 0
var _stages: Array[Callable] = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]

	_viewport = SubViewport.new()
	_viewport.size = Vector2i(SIZE, SIZE)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)

	_stages = [_stage_lit, _stage_fade_static, _stage_cake, _stage_fade_wobble]
	print("size=%d center=%d radius_px=%.4f ortho=%.2f" % [
		SIZE, SIZE / 2, (1.0 / (ORTHO * 0.5)) * (SIZE * 0.5), ORTHO,
	])
	_stages[0].call()


func _clear() -> void:
	for child in _viewport.get_children():
		_viewport.remove_child(child)
		child.queue_free()


func _add_camera() -> void:
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = ORTHO
	camera.position = Vector3(0.0, 0.0, 4.0)
	_viewport.add_child(camera)


func _add_sun(from_x: bool) -> void:
	var sun := DirectionalLight3D.new()
	sun.light_color = SUN_COLOR
	# +90 about Y turns the light's -Z travel axis into -X, so LIGHT is (1,0,0).
	sun.rotation_degrees = Vector3(0.0, 90.0, 0.0) if from_x else Vector3.ZERO
	sun.shadow_enabled = false
	_viewport.add_child(sun)


func _sphere(material: Material) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = 1.0
	mesh.height = 2.0
	mesh.radial_segments = 128
	mesh.rings = 64
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	_viewport.add_child(instance)


## Quad spanning x,y in [-1,1] at the given z, facing +Z, with vertex-colour red
## ramping 0 -> 1 left to right.
func _color_quad(z: float, material: Material) -> void:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	# Clockwise as seen from +Z: Godot treats clockwise winding as front-facing, so
	# the counter-clockwise order gets culled and renders nothing at all.
	var corners: Array[Vector3] = [
		Vector3(-1.0, -1.0, z), Vector3(1.0, 1.0, z), Vector3(1.0, -1.0, z),
		Vector3(-1.0, -1.0, z), Vector3(-1.0, 1.0, z), Vector3(1.0, 1.0, z),
	]
	for corner in corners:
		vertices.append(corner)
		normals.append(Vector3(0.0, 0.0, 1.0))
		var red: float = (corner.x + 1.0) * 0.5
		colors.append(Color(red, 0.0, 0.0, 1.0))

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	_viewport.add_child(instance)


func _stage_lit() -> void:
	_clear()
	_sphere(load("res://materials/level_general.tres"))
	_add_camera()
	_add_sun(true)


func _fade_material(speed: float) -> ShaderMaterial:
	var material := load("res://materials/level_transparent.tres").duplicate() as ShaderMaterial
	material.set_shader_parameter("wobble_speed", speed)
	return material


func _stage_fade_static() -> void:
	_clear()
	# Black unshaded backdrop, so blend_mix over it is exactly src * alpha.
	var backdrop := StandardMaterial3D.new()
	backdrop.albedo_color = Color.BLACK
	backdrop.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_color_quad(-0.5, backdrop)
	_color_quad(0.0, _fade_material(0.0))
	_add_camera()
	# Light down -Z, straight at the quad, so N.L is exactly 1.
	_add_sun(false)


func _stage_cake() -> void:
	_clear()
	# Black backdrop so the additive glow is read directly. Measured against the
	# default grey clear colour instead, the dim part of the falloff sits a single
	# 8-bit level above the background and quantisation swamps the exponent.
	var black := StandardMaterial3D.new()
	black.albedo_color = Color.BLACK
	black.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var backdrop := MeshInstance3D.new()
	var plane := QuadMesh.new()
	plane.size = Vector2(8.0, 8.0)
	backdrop.mesh = plane
	backdrop.material_override = black
	backdrop.position = Vector3(0.0, 0.0, -2.0)
	_viewport.add_child(backdrop)

	_sphere(load("res://materials/cake.tres"))
	_add_camera()
	_add_sun(true)


func _stage_fade_wobble() -> void:
	_clear()
	var backdrop := StandardMaterial3D.new()
	backdrop.albedo_color = Color.BLACK
	backdrop.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_color_quad(-0.5, backdrop)
	_color_quad(0.0, _fade_material(2.0))
	_add_camera()
	_add_sun(false)


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame < 150:
		return false
	if (_frame - 150) % 10 != 0:
		return false
	if _stage >= _stages.size():
		return true

	var names := ["lit", "fade_static", "cake", "fade_wobble"]
	var label: String = names[_stage]

	# The cake and wobble stages are time-dependent, so they need several grabs
	# rather than one: the cake's sine spends half its period clamped to zero, and
	# the wobble has to be caught at two different displacements.
	var wanted: int = 6 if label in ["cake", "fade_wobble"] else 1
	var path := "%s/level_%s%s.png" % [
		_out, label, "" if wanted == 1 else "_%d" % _repeat,
	]
	var error := _viewport.get_texture().get_image().save_png(path)
	if error != OK:
		printerr("save failed (%d): %s" % [error, path])
	else:
		print("wrote ", path)

	_repeat += 1
	if _repeat < wanted:
		return false

	_repeat = 0
	_stage += 1
	if _stage < _stages.size():
		_stages[_stage].call()
	return false
