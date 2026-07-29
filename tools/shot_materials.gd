extends SceneTree

## Renders Fortunato from a few angles so the ported materials can actually be
## looked at. Instances the FBX directly rather than player.tscn, so it needs no
## C# and no editor - which also isolates the material test from gameplay.
##
## Lit with nivelEscena's real directional light colour. The Unity ambient is a
## uniform inside the shaders, not a Godot environment light, so it shows up
## without one.
##
## Run with a display attached (no --headless, that has no renderer):
##   godot --path . --script res://tools/shot_materials.gd -- <out_dir>

const MODEL := "res://models/fortunato/fortunato.fbx"

# nivelEscena's "Directional Light": m_Color, m_Intensity 1.
const SUN_COLOR := Color(1.0, 0.95686275, 0.8392157)

# Camera setups: label, position, look-at target.
const SHOTS := [
	["front", Vector3(1.6, 1.5, 2.4), Vector3(0.0, 1.1, 0.0)],
	["side", Vector3(2.8, 1.4, 0.2), Vector3(0.0, 1.1, 0.0)],
	["face", Vector3(0.35, 1.78, 0.75), Vector3(0.0, 1.72, 0.0)],
	["shadowed", Vector3(-1.9, 1.5, -1.9), Vector3(0.0, 1.1, 0.0)],
]

var _camera: Camera3D
var _out_dir := "/tmp"
var _frame := 0
var _shot := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out_dir = args[0]

	var model := (load(MODEL) as PackedScene).instantiate()
	# player.tscn applies the same 180 turn: the mesh's visual front is +Z.
	model.rotation.y = PI
	root.add_child(model)

	var sun := DirectionalLight3D.new()
	sun.light_color = SUN_COLOR
	sun.rotation_degrees = Vector3(-35.0, 35.0, 0.0)
	root.add_child(sun)

	_camera = Camera3D.new()
	root.add_child(_camera)
	_aim(0)

	print("bones/meshes ready, writing to ", _out_dir)


func _aim(index: int) -> void:
	# look_at_from_position rather than position + look_at, because look_at needs
	# the node to already be inside the tree and the first aim happens before it.
	_camera.look_at_from_position(SHOTS[index][1], SHOTS[index][2])


func _process(_delta: float) -> bool:
	_frame += 1

	# Give the renderer a few frames to compile shaders and settle before the
	# first grab, then one settling frame between shots.
	if _frame < 150:
		return false

	if (_frame - 150) % 6 != 0:
		return false

	if _shot >= SHOTS.size():
		return true

	var image := root.get_texture().get_image()
	var path := "%s/fortunato_%s.png" % [_out_dir, SHOTS[_shot][0]]
	var error := image.save_png(path)
	if error != OK:
		printerr("save failed (%d): %s" % [error, path])
	else:
		print("wrote ", path)

	_shot += 1
	if _shot < SHOTS.size():
		_aim(_shot)
	return false
