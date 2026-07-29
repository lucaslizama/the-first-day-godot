extends SceneTree

## Numeric check on death_distortion.gdshader.
##
## Renders a synthetic source through the shader and, separately, without it.
## Comparing against the engine's own unshaded render rather than an assumed
## source value keeps colour-space handling out of the comparison entirely.
##
## The source's green channel is a linear ramp in x, which makes the shifted
## green tap analytically predictable: bilinear filtering of a linear ramp is
## exact, so no bilinear reconstruction is needed on the analysis side. Red and
## blue are constant, so they isolate the vignette mask.
##
##   godot --path . --script res://tools/verify_death_shader.gd -- <out_dir>

const SHADER := "res://shaders/death_distortion.gdshader"
const SIZE := 512
const RED := 128
const BLUE := 64

# vignette_intensity, chromatic_aberration: the values GameManager writes at
# deathConstant 0 and 1.
const CASES := [
	["k0", 0.1, 2.0],
	["k1", 0.4, 10.0],
]

var _viewport: SubViewport
var _overlay: ColorRect
var _out := "/tmp"
var _frame := 0
var _stage := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]

	_viewport = SubViewport.new()
	_viewport.size = Vector2i(SIZE, SIZE)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)

	var image := Image.create(SIZE, SIZE, false, Image.FORMAT_RGB8)
	for x in SIZE:
		var green := float(x) / float(SIZE - 1)
		for y in SIZE:
			image.set_pixel(x, y, Color8(RED, int(round(green * 255.0)), BLUE))

	var source := TextureRect.new()
	source.texture = ImageTexture.create_from_image(image)
	source.size = Vector2(SIZE, SIZE)
	_viewport.add_child(source)

	_overlay = ColorRect.new()
	_overlay.size = Vector2(SIZE, SIZE)
	var material := ShaderMaterial.new()
	material.shader = load(SHADER)
	_overlay.material = material
	_overlay.visible = false
	_viewport.add_child(_overlay)

	print("size=%d red=%d blue=%d" % [SIZE, RED, BLUE])


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame < 150:
		return false
	if (_frame - 150) % 8 != 0:
		return false

	# Stage 0 grabs the source with the overlay hidden; each later stage grabs one
	# parameter case.
	if _stage == 0:
		_save("source")
		_overlay.visible = true
		_apply(0)
		_stage += 1
		return false

	if _stage <= CASES.size():
		_save(CASES[_stage - 1][0])
		if _stage < CASES.size():
			_apply(_stage)
		_stage += 1
		return false

	return true


func _apply(index: int) -> void:
	var material := _overlay.material as ShaderMaterial
	material.set_shader_parameter("vignette_intensity", CASES[index][1])
	material.set_shader_parameter("chromatic_aberration", CASES[index][2])


func _save(label: String) -> void:
	var path := "%s/death_%s.png" % [_out, label]
	var error := _viewport.get_texture().get_image().save_png(path)
	if error != OK:
		printerr("save failed (%d): %s" % [error, path])
	else:
		print("wrote ", path)
