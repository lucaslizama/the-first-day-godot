extends SceneTree

## Renders one model on its own from +Z and -Z, to establish which local axis is
## its visible front. Everything about door facing depends on knowing that.

var _vp: SubViewport
var _cam: Camera3D
var _model: Node3D
var _out := "/tmp"
var _path := ""
var _frame := 0
var _i := 0

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	_out = a[0] if a.size() > 0 else "/tmp"
	_path = a[1] if a.size() > 1 else ""

func _build() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(700, 800)
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_vp)
	_model = (load(_path) as PackedScene).instantiate()
	_vp.add_child(_model)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35.0, 25.0, 0.0)
	_vp.add_child(sun)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.1, 0.1, 0.12)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.35, 0.35, 0.35)
	env.environment = e
	_vp.add_child(env)
	_cam = Camera3D.new()
	_vp.add_child(_cam)
	_aim()

func _bounds() -> AABB:
	var total := AABB()
	var first := true
	for m in _meshes(_model):
		var b: AABB = m.global_transform * m.mesh.get_aabb()
		total = b if first else total.merge(b)
		first = false
	return total

func _aim() -> void:
	var b := _bounds()
	var c := b.get_center()
	var d: float = maxf(b.size.x, maxf(b.size.y, b.size.z)) * 1.6
	var sign := 1.0 if _i == 0 else -1.0
	_cam.look_at_from_position(c + Vector3(0.0, 0.0, d * sign), c)

func _meshes(node: Node) -> Array[MeshInstance3D]:
	var f: Array[MeshInstance3D] = []
	if node is MeshInstance3D: f.append(node)
	for c in node.get_children(): f.append_array(_meshes(c))
	return f

func _process(_d: float) -> bool:
	_frame += 1
	if _frame == 2:
		_build()
		return false
	if _frame < 150 or (_frame - 150) % 8 != 0:
		return false
	if _i >= 2:
		return true
	var tag := "plusZ" if _i == 0 else "minusZ"
	_vp.get_texture().get_image().save_png("%s/model_%s.png" % [_out, tag])
	print("wrote model_%s" % tag)
	_i += 1
	if _i < 2:
		_aim()
	return false
