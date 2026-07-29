extends SceneTree

## Close-up of a prop cluster, to check the props are upright, correctly scaled
## and carrying their ported materials. Pass the world point to look at.

var _viewport: SubViewport
var _camera: Camera3D
var _out := "/tmp"
var _target := Vector3.ZERO
var _frame := 0
var _shot := 0
var _built := false

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	_out = a[0] if a.size() > 0 else "/tmp"
	if a.size() >= 4:
		_target = Vector3(float(a[1]), float(a[2]), float(a[3]))

func _build() -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(1200, 800)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)
	_viewport.add_child((load("res://scenes/level.tscn") as PackedScene).instantiate())
	_camera = Camera3D.new()
	_viewport.add_child(_camera)
	_aim(0)

const OFFSETS := [Vector3(7.0, 4.0, 7.0), Vector3(-6.0, 2.0, 6.0), Vector3(0.0, 9.0, 0.5)]

func _aim(i: int) -> void:
	_camera.look_at_from_position(_target + OFFSETS[i], _target)

func _process(_d: float) -> bool:
	_frame += 1
	if _frame == 2:
		_build()
		return false
	if _frame < 150:
		return false
	if (_frame - 150) % 8 != 0:
		return false
	if _shot >= OFFSETS.size():
		return true
	var path := "%s/props_%d.png" % [_out, _shot]
	_viewport.get_texture().get_image().save_png(path)
	print("wrote ", path)
	_shot += 1
	if _shot < OFFSETS.size():
		_aim(_shot)
	return false
