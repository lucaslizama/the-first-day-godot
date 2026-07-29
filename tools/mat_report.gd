extends SceneTree

func _initialize() -> void:
	var scene := load("res://models/fortunato/fortunato.fbx") as PackedScene
	var root := scene.instantiate()
	_walk(root, 0)
	quit()

func _walk(node: Node, depth: int) -> void:
	var line := "  ".repeat(depth) + node.name + " [" + node.get_class() + "]"
	if node is MeshInstance3D:
		var mesh: Mesh = node.mesh
		line += "  surfaces=%d" % mesh.get_surface_count()
		for i in mesh.get_surface_count():
			var m := mesh.surface_get_material(i)
			if m == null:
				line += "\n" + "  ".repeat(depth + 1) + "surf%d: <null>" % i
			else:
				var desc := "surf%d: %s name=%s" % [i, m.get_class(), m.resource_name]
				if m is StandardMaterial3D:
					desc += " albedo=%s metallic=%.3f roughness=%.3f emission_on=%s emission=%s" % [
						m.albedo_color, m.metallic, m.roughness,
						m.emission_enabled, m.emission,
					]
				line += "\n" + "  ".repeat(depth + 1) + desc
	print(line)
	for child in node.get_children():
		_walk(child, depth + 1)
