@tool
extends EditorScenePostImport

## Import-time cleanup for Fortunato's Maya-exported animation clips.
##
## Each clip ships the whole animation rig, so it carries 216-323 tracks of which
## only 41-81 actually drive the deformation skeleton. The rest address IK/FK
## control nodes (Group/Main/MotionSystem/...) that do not exist on the imported
## character: they resolve to nothing at runtime and make the editor's animation
## panel unusable - cry alone had 56,674 keys spread over 216 tracks.
##
## Keeping only DeformationSystem tracks drops ~77% of the data with no visual
## change, because the discarded tracks never drove a vertex.

const KEEP_PREFIX := "DeformationSystem"


func _post_import(scene: Node) -> Object:
	var removed := 0
	var kept := 0

	for player in _find_animation_players(scene):
		for name in player.get_animation_list():
			var animation: Animation = player.get_animation(name)
			for track in range(animation.get_track_count() - 1, -1, -1):
				if String(animation.track_get_path(track)).begins_with(KEEP_PREFIX):
					kept += 1
				else:
					animation.remove_track(track)
					removed += 1

	print("[fortunato] %s: kept %d deformation tracks, removed %d rig tracks" % [
		get_source_file().get_file(), kept, removed,
	])
	return scene


func _find_animation_players(node: Node) -> Array[AnimationPlayer]:
	var found: Array[AnimationPlayer] = []
	if node is AnimationPlayer:
		found.append(node)
	for child in node.get_children():
		found.append_array(_find_animation_players(child))
	return found
