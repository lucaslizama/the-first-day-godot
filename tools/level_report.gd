extends SceneTree

## Reports the imported level shell: node tree, mesh AABBs, surface materials and
## - critically for level_fade.gdshader - whether vertex colours survived import.

const MODELS := ["res://models/level/nivel.fbx", "res://models/level/nivel_p2.fbx"]

func _initialize() -> void:
	for path in MODELS:
		var scene := load(path) as PackedScene
		if scene == null:
			printerr("failed to load ", path)
			continue
		var root_node := scene.instantiate()
		print("=".repeat(70))
		print(path.get_file())
		_walk(root_node, 0)
	quit()

func _walk(node: Node, depth: int) -> void:
	var pad := "  ".repeat(depth)
	if node is MeshInstance3D:
		var mesh: Mesh = node.mesh
		var aabb := mesh.get_aabb()
		print("%s%s [MeshInstance3D] surfaces=%d" % [pad, node.name, mesh.get_surface_count()])
		print("%s   aabb pos=(%.3f, %.3f, %.3f) size=(%.3f, %.3f, %.3f)" % [
			pad, aabb.position.x, aabb.position.y, aabb.position.z,
			aabb.size.x, aabb.size.y, aabb.size.z,
		])
		for i in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(i)
			var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] != null else PackedColorArray()
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var mat := mesh.surface_get_material(i)
			var reds := "none"
			if colors.size() > 0:
				var lo := 2.0
				var hi := -1.0
				for c in colors:
					lo = minf(lo, c.r)
					hi = maxf(hi, c.r)
				reds = "r in [%.3f .. %.3f]" % [lo, hi]
			print("%s   surf%d: verts=%d  material=%s  VERTEX COLOURS: %s (%d)" % [
				pad, i, verts.size(),
				mat.resource_name if mat != null else "<null>",
				reds, colors.size(),
			])
	else:
		print("%s%s [%s]" % [pad, node.name, node.get_class()])
	for child in node.get_children():
		_walk(child, depth + 1)
