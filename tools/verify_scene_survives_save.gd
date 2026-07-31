# Checks that opening a scene in the editor and saving it does not silently change what the
# scene means.
#
#   godot-mono --headless --path . --script tools/verify_scene_survives_save.gd
#
# WHY THIS EXISTS. scenes/level.tscn lost all 73 of its surface_material_override entries and
# both of its child transform overrides twice, in the working copy, with the repository intact
# each time. It was blamed on a plugin with a save-scene tool. That was wrong: no plugin is
# needed, and nothing about it is intermittent. It is reproducible in one second.
#
# The overrides live on children of INSTANCED sub-scenes:
#
#     [node name="polySurface6" parent="Shell/nivel/Nivel" index="0"]
#     surface_material_override/0 = ExtResource("19_general")
#
# Godot's packer only stores state for children of an instance marked EDITABLE. The loader
# honours those blocks regardless, which is why the level always looked right until something
# re-saved it - and then the packer, seeing a sealed instance, wrote the scene back out without
# them. LOADING IS MORE PERMISSIVE THAN SAVING, and that asymmetry is the entire bug. The fix is
# two lines at the end of the scene:
#
#     [editable path="Shell/nivel"]
#     [editable path="ShellP2/nivel_p2"]
#
# This reproduces the destructive save headlessly - instantiate with GEN_EDIT_STATE_MAIN, which
# is what the editor does when it opens a scene, then pack() - so the regression cannot come back
# unnoticed.
#
# WHAT IT COMPARES, and why the obvious version does not work. The first attempt compared the
# PackedScene's STORED properties and produced five failures that were all its own fault:
#
#   * a property equal to its default is correctly omitted by the packer - volume_db = 0.0,
#     attenuation_model = 0, MinDistance = 1.0 are not losses, they are tidying;
#   * layout_mode is an editor hint that Godot legitimately recomputes;
#   * 2.39 came back as 2.39000010490417, which is float32 round-tripping, not a change.
#
# So it compares the EFFECTIVE STATE OF THE INSTANTIATED TREES instead: build the scene from the
# original, build it again from the re-packed copy, and require every stored property of every
# node to agree. That asks the question that actually matters - does the scene still behave the
# same - and it is immune to how Godot chooses to serialise any of it.
extends SceneTree

## Every scene in the project, found by scanning rather than listed. It was a hardcoded list of
## ten, which silently stopped covering the project the moment a teammate added main_menu.tscn and
## main_menu_background.tscn - two scenes authored IN THE EDITOR, which is exactly the situation
## this check exists for. A list of things to protect is a list that goes stale.
const SCENE_DIR := "res://scenes"


func _scenes() -> Array[String]:
	var out: Array[String] = []
	_collect(SCENE_DIR, out)
	out.sort()
	return out


func _collect(dir_path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := "%s/%s" % [dir_path, name]
		if dir.current_is_dir():
			if not name.begins_with("."):
				_collect(full, out)
		elif name.ends_with(".tscn"):
			out.append(full)
		name = dir.get_next()
	dir.list_dir_end()

## Float32 round-tripping through the scene format changes 2.39 into 2.39000010490417. Relative,
## so it holds for the level's ~180 m coordinates as well as for a 0.8 ratio.
const RELATIVE_TOLERANCE := 1e-5

## Recomputed by the layout system rather than carried, so it says nothing about the scene.
const IGNORED_PROPERTIES := ["layout_mode", "anchors_preset"]

var checks := 0
var failures := 0


func _process(_delta: float) -> bool:
	var scenes := _scenes()
	if scenes.is_empty():
		print("FAIL: found no scenes under %s; has the layout changed?" % SCENE_DIR)
		quit(1)
		return true
	for path in scenes:
		_check(path)

	print("")
	if failures == 0:
		print("PASS: %d checks" % checks)
	else:
		print("FAIL: %d of %d checks failed" % [failures, checks])
	quit(1 if failures > 0 else 0)
	return true


func _check(path: String) -> void:
	checks += 1
	var original := load(path) as PackedScene
	if original == null:
		_fail("%s did not load" % path)
		return

	# GEN_EDIT_STATE_MAIN is what the editor uses when opening a scene for editing. Anything
	# that differs after pack() is something a plain open-and-save would change on disk.
	var for_packing := original.instantiate(PackedScene.GEN_EDIT_STATE_MAIN)
	var repacked := PackedScene.new()
	var err := repacked.pack(for_packing)
	for_packing.free()
	if err != OK:
		_fail("%s could not be re-packed: %s" % [path, error_string(err)])
		return

	var before := original.instantiate()
	var after := repacked.instantiate()
	var differences: Array[String] = []
	_compare(before, after, ".", differences)
	before.free()
	after.free()

	if differences.is_empty():
		_ok("%s survives an open-and-save unchanged" % path)
		return

	_fail(("%s CHANGES when opened and saved - %d difference(s): %s." +
		" If these are properties on children of an instanced sub-scene, the scene needs an" +
		" [editable path=\"...\"] line for that instance: Godot's loader applies such overrides" +
		" but its packer discards them unless the instance is editable.") % [
			path, differences.size(), str(differences.slice(0, 6))])


func _compare(a: Node, b: Node, path: String, out: Array[String]) -> void:
	if a.get_class() != b.get_class():
		out.append("%s is a %s, became a %s" % [path, a.get_class(), b.get_class()])
		return

	for info in a.get_property_list():
		if (int(info["usage"]) & PROPERTY_USAGE_STORAGE) == 0:
			continue
		var name := String(info["name"])
		if name in IGNORED_PROPERTIES:
			continue
		if not _same(a.get(name), b.get(name)):
			out.append("%s -> %s (%s became %s)" % [path, name, a.get(name), b.get(name)])

	var a_children := a.get_children()
	var b_children := b.get_children()
	if a_children.size() != b_children.size():
		out.append("%s had %d children, now has %d" % [path, a_children.size(), b_children.size()])
		return
	for i in a_children.size():
		_compare(a_children[i], b_children[i], "%s/%s" % [path, a_children[i].name], out)


## Compares by value, tolerating float32 round-tripping at any nesting depth.
func _same(x: Variant, y: Variant) -> bool:
	if typeof(x) != typeof(y):
		return false
	match typeof(x):
		TYPE_FLOAT:
			return _close(x, y)
		TYPE_VECTOR3, TYPE_VECTOR2, TYPE_QUATERNION, TYPE_COLOR, TYPE_PLANE, TYPE_VECTOR4:
			for i in range(4):
				# Vector types index consistently; stop at the type's own length.
				if not (i < _component_count(x)):
					break
				if not _close(x[i], y[i]):
					return false
			return true
		TYPE_TRANSFORM3D:
			return _close_basis(x.basis, y.basis) and _same(x.origin, y.origin)
		TYPE_BASIS:
			return _close_basis(x, y)
		TYPE_ARRAY:
			if x.size() != y.size():
				return false
			for i in x.size():
				if not _same(x[i], y[i]):
					return false
			return true
		TYPE_OBJECT:
			# Resources are re-instantiated, so identity would always differ; compare the path
			# for external ones and fall back to the class for embedded ones.
			if x == null or y == null:
				return x == y
			if x is Resource and y is Resource:
				if not (x as Resource).resource_path.is_empty():
					return (x as Resource).resource_path == (y as Resource).resource_path
				return x.get_class() == y.get_class()
			return x.get_class() == y.get_class()
	return str(x) == str(y)


func _component_count(v: Variant) -> int:
	match typeof(v):
		TYPE_VECTOR2:
			return 2
		TYPE_VECTOR3:
			return 3
	return 4


func _close_basis(a: Basis, b: Basis) -> bool:
	for i in 3:
		if not _same(a[i], b[i]):
			return false
	return true


func _close(x: float, y: float) -> bool:
	var scale: float = maxf(1.0, maxf(absf(x), absf(y)))
	return absf(x - y) <= RELATIVE_TOLERANCE * scale


func _ok(m: String) -> void:
	print("  ok    ", m)


func _fail(m: String) -> void:
	failures += 1
	print("  FAIL  ", m)
