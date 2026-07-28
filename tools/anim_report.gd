extends SceneTree

## Diagnostic: reports how many tracks each imported Fortunato clip carries and
## how many of those actually drive the deformation skeleton.
##
## Run headless (with the editor closed):
##   godot --headless --path . --script res://tools/anim_report.gd

const ANIM_DIR := "res://models/fortunato/anims"
const KEEP_PREFIX := "DeformationSystem"


func _initialize() -> void:
	var dir := DirAccess.open(ANIM_DIR)
	if dir == null:
		print("cannot open ", ANIM_DIR)
		quit(1)
		return

	var total := 0
	var total_keep := 0
	var files := dir.get_files()
	files.sort()

	for file in files:
		if not file.ends_with(".res"):
			continue
		var anim := load(ANIM_DIR + "/" + file) as Animation
		if anim == null:
			print("%-18s FAILED TO LOAD" % file)
			continue

		var keep := 0
		var keys := 0
		for i in anim.get_track_count():
			if String(anim.track_get_path(i)).begins_with(KEEP_PREFIX):
				keep += 1
			keys += anim.track_get_key_count(i)

		total += anim.get_track_count()
		total_keep += keep
		print("%-18s tracks=%5d  deform=%4d  junk=%5d  keys=%7d  len=%.2fs" % [
			file, anim.get_track_count(), keep, anim.get_track_count() - keep, keys, anim.length,
		])

	print("---")
	print("TOTAL tracks=%d  deform=%d  junk=%d" % [total, total_keep, total - total_keep])
	quit()
