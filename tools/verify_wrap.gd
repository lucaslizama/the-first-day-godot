extends SceneTree

## Numeric check on character_lit.gdshader.
##
## Renders a sphere with Fortunato's body material under a single directional
## light on the +X axis, viewed orthographically down -Z. That makes the
## equator scanline a clean sweep of N.L from -1 to +1, so every pixel across it
## has a known shading input and can be compared against the Unity shader's
## math computed on the CPU. Eyeballing a character mesh cannot confirm the
## light-wrapping term; this can.
##
##   godot --path . --script res://tools/verify_wrap.gd -- <out_png>

const MATERIAL := "res://materials/fortunato_body.tres"
const SIZE := 800
const ORTHO_SIZE := 2.4

var _viewport: SubViewport
var _out := "/tmp/wrap.png"
var _frame := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]

	_viewport = SubViewport.new()
	_viewport.size = Vector2i(SIZE, SIZE)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)

	var mesh := SphereMesh.new()
	mesh.radius = 1.0
	mesh.height = 2.0
	mesh.radial_segments = 128
	mesh.rings = 64

	var sphere := MeshInstance3D.new()
	sphere.mesh = mesh
	sphere.material_override = load(MATERIAL)
	_viewport.add_child(sphere)

	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = ORTHO_SIZE
	camera.position = Vector3(0.0, 0.0, 4.0)
	_viewport.add_child(camera)

	# Rotating a directional light +90 deg about Y turns its -Z travel axis into
	# -X, so the light arrives from +X and LIGHT is exactly (1, 0, 0).
	var sun := DirectionalLight3D.new()
	sun.light_color = Color(1.0, 0.95686275, 0.8392157)
	sun.rotation_degrees = Vector3(0.0, 90.0, 0.0)
	sun.shadow_enabled = false
	_viewport.add_child(sun)

	# Radius in pixels, so the analyser can turn x into N.L.
	print("size=%d center=%d radius_px=%.4f" % [
		SIZE, SIZE / 2, (1.0 / (ORTHO_SIZE * 0.5)) * (SIZE * 0.5),
	])


func _process(_delta: float) -> bool:
	_frame += 1
	# A shader Godot has not cached yet renders nothing for a while, so wait
	# generously rather than capturing a blank frame and calling it a result.
	if _frame < 150:
		return false

	var error := _viewport.get_texture().get_image().save_png(_out)
	if error != OK:
		printerr("save failed (%d)" % error)
	else:
		print("wrote ", _out)
	return true
