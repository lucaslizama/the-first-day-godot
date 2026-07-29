extends SceneTree

## Renders scenes/level.tscn from an explicit camera position and target, so a
## single prop can be inspected without the camera ending up inside geometry.
##   -- <out.png> camx camy camz tgtx tgty tgtz

var _vp: SubViewport
var _out := "/tmp/shot.png"
var _cam_pos := Vector3.ZERO
var _tgt := Vector3.ZERO
var _frame := 0

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() >= 7:
		_out = a[0]
		_cam_pos = Vector3(float(a[1]), float(a[2]), float(a[3]))
		_tgt = Vector3(float(a[4]), float(a[5]), float(a[6]))

func _process(_d: float) -> bool:
	_frame += 1
	if _frame == 2:
		_vp = SubViewport.new()
		_vp.size = Vector2i(900, 700)
		_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(_vp)
		_vp.add_child((load("res://scenes/level.tscn") as PackedScene).instantiate())
		var cam := Camera3D.new()
		_vp.add_child(cam)
		cam.look_at_from_position(_cam_pos, _tgt)
		return false
	if _frame < 160:
		return false
	_vp.get_texture().get_image().save_png(_out)
	print("wrote ", _out)
	return true
