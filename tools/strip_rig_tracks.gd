extends SceneTree

## One-shot repair for Fortunato's Maya-exported animations.
##
## Maya exported each clip with the whole animation rig attached, so the imported
## animations carry 216-323 tracks of which only 41-81 drive the deformation
## skeleton. The rest address IK/FK control nodes (Group/Main/MotionSystem/...)
## that do not exist on the imported character. They animate nothing, and they
## make the editor's animation panel hang: cry alone held 56,674 keys across 216
## tracks, and the panel lays out every row and key.
##
## This rewrites the extracted .res animations in place, keeping only the tracks
## that address the deformation skeleton. Nothing visual is lost, because the
## discarded tracks never moved a vertex.
##
## Run with the editor CLOSED (it caches these resources):
##   godot --headless --path . --script res://tools/strip_rig_tracks.gd

const ANIM_DIR := "res://models/fortunato/anims"
const KEEP_PREFIX := "DeformationSystem"


func _initialize() -> void:
	var dir := DirAccess.open(ANIM_DIR)
	if dir == null:
		printerr("cannot open ", ANIM_DIR)
		quit(1)
		return

	var files := dir.get_files()
	files.sort()

	var total_before := 0
	var total_after := 0
	var failures := 0

	for file in files:
		if not file.ends_with(".res"):
			continue

		var path := ANIM_DIR + "/" + file
		var animation := load(path) as Animation
		if animation == null:
			printerr("%s: failed to load" % file)
			failures += 1
			continue

		var before := animation.get_track_count()
		for track in range(before - 1, -1, -1):
			if not String(animation.track_get_path(track)).begins_with(KEEP_PREFIX):
				animation.remove_track(track)
		var after := animation.get_track_count()

		if after == 0:
			printerr("%s: refusing to save, every track would be removed" % file)
			failures += 1
			continue

		var error := ResourceSaver.save(animation, path)
		if error != OK:
			printerr("%s: save failed (%d)" % [file, error])
			failures += 1
			continue

		total_before += before
		total_after += after
		print("%-18s %5d -> %4d tracks" % [file, before, after])

	print("---")
	print("tracks %d -> %d (removed %d)" % [
		total_before, total_after, total_before - total_after,
	])
	if failures > 0:
		printerr("%d file(s) failed" % failures)
	quit(1 if failures > 0 else 0)
