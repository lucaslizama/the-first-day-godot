extends SceneTree

## Overview renders of the assembled level shell, plus its measured bounds, so
## the scale and the two halves' placement can be checked.

var _viewport: SubViewport
var _camera: Camera3D
var _out := "/tmp"
var _frame := 0
var _shot := 0
var _shots: Array = []

var _ready_done := false

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]

func _build() -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(1200, 800)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)

	var level := (load("res://scenes/level.tscn") as PackedScene).instantiate()
	_viewport.add_child(level)

	var total := AABB()
	var first := true
	var count := 0
	for m in _meshes(level):
		count += 1
		var box := m.global_transform * m.mesh.get_aabb()
		if first:
			total = box
			first = false
		else:
			total = total.merge(box)
	print("assembled shell: %d mesh instances" % count)
	print("  bounds pos=(%.2f, %.2f, %.2f)  size=(%.2f, %.2f, %.2f) m" % [
		total.position.x, total.position.y, total.position.z,
		total.size.x, total.size.y, total.size.z,
	])
	var c := total.get_center()
	var span: float = maxf(total.size.x, maxf(total.size.y, total.size.z))
	print("  centre=(%.2f, %.2f, %.2f)  longest span=%.2f m" % [c.x, c.y, c.z, span])

	_shots = [
		["side", c + Vector3(span * 1.1, span * 0.25, 0.0), c],
		["front", c + Vector3(0.0, span * 0.2, span * 1.1), c],
		["top", c + Vector3(0.01, span * 1.1, 0.0), c],
	]
	_camera = Camera3D.new()
	_camera.far = span * 6.0
	_viewport.add_child(_camera)
	_aim(0)

func _aim(i: int) -> void:
	_camera.look_at_from_position(_shots[i][1], _shots[i][2])

func _meshes(node: Node) -> Array[MeshInstance3D]:
	var f: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		f.append(node)
	for c in node.get_children():
		f.append_array(_meshes(c))
	return f

func _process(_delta: float) -> bool:
	_frame += 1
	# Built here rather than in _initialize: global_transform returns identity
	# before the tree is live, so bounds measured there are meaningless and the
	# camera framing derived from them is wrong.
	if _frame == 2:
		_build()
		return false
	if _frame < 150:
		return false
	if (_frame - 150) % 8 != 0:
		return false
	if _shot >= _shots.size():
		return true
	var path := "%s/level_%s.png" % [_out, _shots[_shot][0]]
	_viewport.get_texture().get_image().save_png(path)
	print("wrote ", path)
	_shot += 1
	if _shot < _shots.size():
		_aim(_shot)
	return false
