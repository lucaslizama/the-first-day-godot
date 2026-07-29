extends SceneTree

## Measures bounds AFTER the tree is live. Doing this in _initialize() makes
## global_transform return identity, which silently merges mesh-local boxes and
## produces meaningless numbers.

var _built := false
var _frame := 0

func _initialize() -> void:
	pass

func _process(_delta: float) -> bool:
	_frame += 1
	if _frame < 3:
		return false

	if not _built:
		_built = true
		_report("res://scenes/level.tscn", "assembled level (root_scale=100)")
		_report_model("res://models/level/nivel.fbx", "nivel.fbx alone")
		_report_model("res://models/level/nivel_p2.fbx", "nivel_p2.fbx alone")
	return true

func _report(path: String, label: String) -> void:
	var n := (load(path) as PackedScene).instantiate()
	root.add_child(n)
	_bounds(n, label)
	n.queue_free()

func _report_model(path: String, label: String) -> void:
	var n := (load(path) as PackedScene).instantiate()
	root.add_child(n)
	_bounds(n, label)
	n.queue_free()

func _bounds(n: Node, label: String) -> void:
	var total := AABB()
	var first := true
	var count := 0
	for m in _meshes(n):
		if not m.is_inside_tree():
			printerr("  %s: mesh %s not in tree - measurement would be wrong" % [label, m.name])
			return
		count += 1
		var box: AABB = m.global_transform * m.mesh.get_aabb()
		if first:
			total = box
			first = false
		else:
			total = total.merge(box)
	print("%s: %d meshes" % [label, count])
	print("   bounds pos=(%.2f, %.2f, %.2f)  size=(%.2f x %.2f x %.2f) m" % [
		total.position.x, total.position.y, total.position.z,
		total.size.x, total.size.y, total.size.z,
	])

func _meshes(node: Node) -> Array[MeshInstance3D]:
	var f: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		f.append(node)
	for c in node.get_children():
		f.append_array(_meshes(c))
	return f
