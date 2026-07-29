extends SceneTree

## Renders Fortunato through death_distortion.gdshader at 0 and 10 deaths, so the
## effect can be compared at both ends of the range.
##
##   godot --path . --script res://tools/shot_death_effect.gd -- <out_dir>

const MODEL := "res://models/fortunato/fortunato.fbx"
const SHADER := "res://shaders/death_distortion.gdshader"
const SIZE := Vector2i(900, 900)
const SUN_COLOR := Color(1.0, 0.95686275, 0.8392157)

# label, deaths, vignette_intensity, chromatic_aberration
const CASES := [
	["deaths0", 0, 0.1, 2.0],
	["deaths10", 10, 0.4, 10.0],
]

var _viewport: SubViewport
var _overlay: ColorRect
var _out := "/tmp"
var _frame := 0
var _shot := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]

	_viewport = SubViewport.new()
	_viewport.size = SIZE
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)

	var model := (load(MODEL) as PackedScene).instantiate()
	model.rotation.y = PI
	_viewport.add_child(model)

	var sun := DirectionalLight3D.new()
	sun.light_color = SUN_COLOR
	sun.rotation_degrees = Vector3(-30.0, 20.0, 0.0)
	_viewport.add_child(sun)

	var camera := Camera3D.new()
	_viewport.add_child(camera)
	camera.look_at_from_position(Vector3(0.0, 1.35, 2.1), Vector3(0.0, 1.15, 0.0))

	_overlay = ColorRect.new()
	_overlay.size = Vector2(SIZE)
	var material := ShaderMaterial.new()
	material.shader = load(SHADER)
	_overlay.material = material
	_viewport.add_child(_overlay)
	_apply(0)


func _apply(index: int) -> void:
	var material := _overlay.material as ShaderMaterial
	material.set_shader_parameter("vignette_intensity", CASES[index][2])
	material.set_shader_parameter("chromatic_aberration", CASES[index][3])


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame < 150:
		return false
	if (_frame - 150) % 8 != 0:
		return false
	if _shot >= CASES.size():
		return true

	var path := "%s/death_effect_%s.png" % [_out, CASES[_shot][0]]
	var error := _viewport.get_texture().get_image().save_png(path)
	if error != OK:
		printerr("save failed (%d)" % error)
	else:
		print("wrote %s  (deaths=%d)" % [path, CASES[_shot][1]])

	_shot += 1
	if _shot < CASES.size():
		_apply(_shot)
	return false
