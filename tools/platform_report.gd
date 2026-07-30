extends SceneTree
## Measures the platform models and their placement. Two sections.
##
## The models: node tree, per-surface material, and the true vertex bounds. Bounds
## are recomputed from the surface arrays rather than read from Mesh.get_aabb(),
## which reported an identical 0.02 x 0.2 x 0.02 box for both models - a size
## neither mesh has. Each is really one axis-aligned box, 2 x 20 x 2 m with its top
## face at y = 0: a 2 m square you stand on, on a 20 m column hanging into the void
## below. The columns are meant to be seen fading out, which is what the vertex
## colours are for - red is 1 along the bottom edge and 0 along the top, and
## mat_generalTransparencia turns red into transparency.
##
## The placement: each instance's world footprint, plus a contiguity check on the
## falling walkway. Renders of these platforms are genuinely hard to read - a 2 x 2
## top seen at a glancing angle looks like a thin ledge, and a rotated square has a
## 2.73 m AABB - so anything about their size or spacing should be settled here
## rather than by eye. The 4 m gap this port initially claimed in the walkway was
## an eyeballed guess, and wrong: the gap is one tile, 2 m.
##
## Run: godot-mono --headless --script tools/platform_report.gd

func _process(_d: float) -> bool:
	print("=== models ===")
	for file in ["plataforma.fbx", "plataformaCae.fbx"]:
		var n := (load("res://models/props/" + file) as PackedScene).instantiate()
		root.add_child(n)
		print("-- ", file)
		_dump(n, "  ")
		n.queue_free()

	print("=== placement ===")
	_placement()
	quit()
	return true

func _dump(node: Node, indent: String) -> void:
	var extra := ""
	if node is Node3D:
		var t: Transform3D = (node as Node3D).transform
		extra = "  origin=(%.3f, %.3f, %.3f)" % [t.origin.x, t.origin.y, t.origin.z]
	if node is MeshInstance3D:
		var m: MeshInstance3D = node
		for i in m.mesh.get_surface_count():
			var mat := m.mesh.surface_get_material(i)
			var arrays: Array = m.mesh.surface_get_arrays(i)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var box := AABB(verts[0], Vector3.ZERO)
			for v in verts:
				box = box.expand(v)
			var reds := "no vertex colours - mat_generalTransparencia would render it invisible"
			var colours: Variant = arrays[Mesh.ARRAY_COLOR]
			if colours != null:
				var lo := INF
				var hi := -INF
				for c in colours:
					lo = minf(lo, c.r)
					hi = maxf(hi, c.r)
				reds = "vertex red %.2f..%.2f" % [lo, hi]
			extra += "\n%s  surface %d: %-26s size=(%.2f, %.2f, %.2f) y=%.2f..%.2f  %s" % [
				indent, i, mat.resource_name if mat != null else "<null>",
				box.size.x, box.size.y, box.size.z,
				box.position.y, box.position.y + box.size.y, reds,
			]
	print(indent, node.name, " [", node.get_class(), "]", extra)
	for c in node.get_children():
		_dump(c, indent + "  ")

func _placement() -> void:
	var n := (load("res://scenes/platforms.tscn") as PackedScene).instantiate()
	root.add_child(n)

	var falling: Array[Vector2] = []  # z span of each falling platform
	var children := n.get_children()
	children.sort_custom(func(a, b): return String(a.name) < String(b.name))

	for c in children:
		var box := _world_bounds(c)
		print("%-20s origin=(%7.2f, %5.2f, %8.2f)  z=[%8.2f, %8.2f]  footprint %.2f x %.2f  top y=%.2f" % [
			c.name, (c as Node3D).global_position.x, (c as Node3D).global_position.y,
			(c as Node3D).global_position.z, box.position.z, box.position.z + box.size.z,
			box.size.x, box.size.z, box.position.y + box.size.y,
		])
		if String(c.name).begins_with("FallingPlatform"):
			falling.append(Vector2(box.position.z, box.position.z + box.size.z))

	falling.sort_custom(func(a: Vector2, b: Vector2): return a.x < b.x)
	var gaps: Array[String] = []
	for i in falling.size() - 1:
		var gap: float = falling[i + 1].x - falling[i].y
		if absf(gap) > 0.01:
			gaps.append("%.2f m at z=%.2f" % [gap, falling[i].y])
	print("walkway: %d tiles from z=%.2f to %.2f, gaps: %s" % [
		falling.size(), falling[0].x, falling[falling.size() - 1].y,
		"none - contiguous" if gaps.is_empty() else ", ".join(gaps),
	])

func _world_bounds(node: Node) -> AABB:
	var box := AABB()
	var first := true
	for m in _meshes(node):
		for i in m.mesh.get_surface_count():
			for v in m.mesh.surface_get_arrays(i)[Mesh.ARRAY_VERTEX]:
				var p: Vector3 = m.global_transform * v
				if first:
					box = AABB(p, Vector3.ZERO)
					first = false
				else:
					box = box.expand(p)
	return box

func _meshes(node: Node) -> Array[MeshInstance3D]:
	var found: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		found.append(node)
	for c in node.get_children():
		found.append_array(_meshes(c))
	return found
