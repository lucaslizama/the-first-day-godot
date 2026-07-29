extends SceneTree

## Confirms the Unity -> Godot placement convention by raycasting down from
## landmark positions taken out of nivelEscena. Under the correct convention
## every landmark has level geometry beneath it; under a flipped Z the ones far
## along the level fall outside the shell entirely.
##
## Landmarks are Unity world positions, composed from the scene hierarchy:
##   Fortunato (player start)   (0.00, 0.00,    4.02)
##   CheckPointZone             (0.28, 9.90,   -0.36)
##   Trigger Zone               (-0.02, 11.97, -101.14)

const LANDMARKS := [
	["player start", Vector3(0.0, 0.0, 4.02)],
	["checkpoint zone", Vector3(0.28, 9.90, -0.36)],
	["trigger zone", Vector3(-0.02, 11.97, -101.14)],
]

var _frame := 0

func _process(_delta: float) -> bool:
	_frame += 1
	if _frame < 4:
		return false

	var level := (load("res://scenes/level.tscn") as PackedScene).instantiate()
	root.add_child(level)

	var bounds := _bounds(level)
	print("shell bounds: pos=(%.1f, %.1f, %.1f) size=(%.1f x %.1f x %.1f) m" % [
		bounds.position.x, bounds.position.y, bounds.position.z,
		bounds.size.x, bounds.size.y, bounds.size.z,
	])
	print("z range: %.1f .. %.1f" % [bounds.position.z, bounds.position.z + bounds.size.z])
	print("")

	var space: PhysicsDirectSpaceState3D = level.get_world_3d().direct_space_state
	for flip in [false, true]:
		var label := "Z NEGATED (mirrored)" if flip else "Z UNCHANGED"
		print("--- convention: %s" % label)
		var hits := 0
		for entry in LANDMARKS:
			var name: String = entry[0]
			var p: Vector3 = entry[1]
			if flip:
				p.z = -p.z
			var from := p + Vector3(0.0, 60.0, 0.0)
			var query := PhysicsRayQueryParameters3D.create(from, p - Vector3(0.0, 60.0, 0.0))
			var result: Dictionary = space.intersect_ray(query)
			var inside := bounds.has_point(Vector3(p.x, clampf(p.y, bounds.position.y, bounds.position.y + bounds.size.y), p.z))
			if result.is_empty():
				print("    %-16s at z=%8.2f  no geometry hit      inside bounds: %s" % [name, p.z, inside])
			else:
				hits += 1
				print("    %-16s at z=%8.2f  hit y=%7.2f        inside bounds: %s" % [
					name, p.z, (result["position"] as Vector3).y, inside,
				])
		print("    landmarks with geometry beneath them: %d of %d" % [hits, LANDMARKS.size()])
		print("")
	return true

func _bounds(n: Node) -> AABB:
	var total := AABB()
	var first := true
	for m in _meshes(n):
		var box: AABB = m.global_transform * m.mesh.get_aabb()
		if first:
			total = box
			first = false
		else:
			total = total.merge(box)
	return total

func _meshes(node: Node) -> Array[MeshInstance3D]:
	var f: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		f.append(node)
	for c in node.get_children():
		f.append_array(_meshes(c))
	return f
