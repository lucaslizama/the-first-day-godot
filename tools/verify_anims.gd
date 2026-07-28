extends SceneTree

## Verifies the stripped animations still deform Fortunato's skeleton: plays each
## clip, samples every bone pose at two times, and reports how many bones actually
## moved. Zero moved bones would mean the strip went too far.
##
##   godot --headless --path . --script res://tools/verify_anims.gd

const MODEL := "res://models/fortunato/fortunato.fbx"
const LIBRARY := "res://models/fortunato/fortunato_anims.tres"


func _initialize() -> void:
	var model := (load(MODEL) as PackedScene).instantiate()
	root.add_child(model)

	var skeleton := model.get_node("DeformationSystem/Skeleton3D") as Skeleton3D
	if skeleton == null:
		printerr("no skeleton found")
		quit(1)
		return

	var player := AnimationPlayer.new()
	model.add_child(player)
	player.root_node = NodePath("..")
	player.add_animation_library("", load(LIBRARY))

	print("bones=%d  animations=%s" % [skeleton.get_bone_count(), player.get_animation_list()])
	print("---")

	var failures := 0
	for name in player.get_animation_list():
		var length: float = player.get_animation(name).length

		player.play(name)
		player.seek(0.0, true)
		var first := _sample(skeleton)

		player.seek(minf(length * 0.5, length), true)
		var second := _sample(skeleton)

		var moved := 0
		for i in first.size():
			if not first[i].is_equal_approx(second[i]):
				moved += 1

		var verdict := "ok" if moved > 0 else "NO MOVEMENT"
		if moved == 0:
			failures += 1
		print("%-14s len=%6.2fs  bones moved=%3d/%d  %s" % [
			name, length, moved, skeleton.get_bone_count(), verdict,
		])

	print("---")
	if failures > 0:
		printerr("%d animation(s) moved nothing" % failures)
	else:
		print("all %d animations deform the skeleton" % player.get_animation_list().size())
	quit(1 if failures > 0 else 0)


func _sample(skeleton: Skeleton3D) -> Array[Transform3D]:
	var poses: Array[Transform3D] = []
	for i in skeleton.get_bone_count():
		poses.append(skeleton.get_bone_pose(i))
	return poses
