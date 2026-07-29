extends SceneTree
var _f := 0
func _process(_d: float) -> bool:
	_f += 1
	if _f < 4:
		return false
	var dir := DirAccess.open("res://models/props")
	var files := dir.get_files()
	files.sort()
	for file in files:
		if not file.ends_with(".fbx"):
			continue
		var n := (load("res://models/props/" + file) as PackedScene).instantiate()
		root.add_child(n)
		var mats := {}
		var total := AABB()
		var first := true
		var count := 0
		for m in _meshes(n):
			count += 1
			var box: AABB = m.global_transform * m.mesh.get_aabb()
			total = box if first else total.merge(box)
			first = false
			for i in m.mesh.get_surface_count():
				var mat := m.mesh.surface_get_material(i)
				mats[mat.resource_name if mat != null else "<null>"] = true
		print("%-18s %d meshes  size=(%.2f, %.2f, %.2f) m  materials=%s" % [
			file, count, total.size.x, total.size.y, total.size.z, mats.keys(),
		])
		n.queue_free()
	quit()
	return true
func _meshes(node: Node) -> Array[MeshInstance3D]:
	var f: Array[MeshInstance3D] = []
	if node is MeshInstance3D: f.append(node)
	for c in node.get_children(): f.append_array(_meshes(c))
	return f
