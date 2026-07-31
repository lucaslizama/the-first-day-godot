# Checks the two level shells: every child's placement, and every surface's material.
#
#   godot-mono --headless --path . --script tools/verify_level_shells.gd
#
# Reported in play as "there is something wrong with nivel_p2, the geometry is not where it
# should be" - a long platform floating in the middle of the moving platforms, and two
# platforms missing from the end of the level, which made it unbeatable. One cause: the
# shells are instanced straight from the FBX, but nivelEscena had MOVED two of nivel_p2's
# children after instancing, and those per-child overrides were never carried across. Both
# slabs sat 40 m further along +Z than they belong - present where they should not be, and
# absent where they should.
#
# Three assertions, and the first is the one that matters:
#
#   1. every mesh child of either shell is at the FBX's transform, EXCEPT the two Unity
#      overrode, which must be at Unity's values. Not "the two are right" - the two are
#      right and nothing else has drifted, so a future reimport that renumbers children
#      cannot quietly move the overrides onto the wrong meshes.
#   2. the material table's second slots match the models. Deliberately NOT a comparison
#      against the table LevelShell reads, which would be circular. A mesh has a second
#      material slot only if it has a second submesh, so the set of names carrying a slot 1
#      must equal the set of meshes Godot imports with 2 surfaces - a fact the table cannot
#      influence. This is what caught the renderer mapping being wrong: resolving Unity's
#      renderer fileIDs by the FBX's Model record order predicts two slots on polySurface17
#      and polySurface18, and the imported meshes say polySurface7 and polySurface9.
#      See tools/extract_level_materials.py.
#   3. no surface anywhere is left on the material the FBX shipped with.
#   4. every one of those materials comes from level.tscn itself, matching the table entry
#      for entry, and NOTHING assigns them at load time. This is the check that closes the
#      red-editor bug: the materials used to be applied by LevelShell.cs in _Ready with
#      [Tool], so the level's appearance depended on a compiled C# assembly existing. A
#      fresh clone has none on first open - .godot/ and bin/ are both gitignored - so the
#      meshes fell back to the FBX's lambert1/lambert2, whose vertex_color_use_as_albedo is
#      true, and the level's vertex colours are pure red (mean 0.457, 0, 0: that channel is
#      data for level_fade.gdshader, not paint). The whole level rendered red until the
#      editor was restarted.
#
#      Checking "the surfaces have the right materials" alone would NOT have caught that -
#      it passed the whole time, because the verifier ran with the assembly built. So this
#      reads the PackedScene's own stored state, which is what the editor sees before any
#      script runs.
extends SceneTree

const TABLE := "res://models/level/level_materials.json"
const SHELLS := {"Shell": "nivel.fbx", "ShellP2": "nivel_p2.fbx"}
const MODELS := {
	"nivel.fbx": "res://models/level/nivel.fbx",
	"nivel_p2.fbx": "res://models/level/nivel_p2.fbx",
}

## Unity's per-child overrides from nivelEscena, already conjugated by M = diag(-1, 1, 1):
## position X negates, and a rotation's y and z negate. Stated here in Godot space so this
## does not re-run the generator's arithmetic - if the conjugation itself were wrong, both
## would agree and both would be wrong.
##
## nivel is absent on purpose. Its instance does carry overrides, but every one of them
## targets an object only an older export of nivel.fbx contained (mesa, pPlane20..pPlane28)
## plus m_RootOrder and m_StaticEditorFlags, none of which place geometry. So the
## expectation for nivel is that NOTHING deviates, which check 1 enforces by having no
## entry here.
const EXPECTED := {
	"nivel_p2.fbx": {
		"polySurface16": [Vector3(37.26, 48.98, -0.23), Quaternion(0, 0, 0, 1)],
		"polySurface17": [Vector3(-46.13, 50.54, 9.94), Quaternion(0, -0.31972805, 0, 0.94750935)],
	},
}
## Metres. The scene stores 6 significant figures, so agreement is exact to well under this.
const POSITION_TOLERANCE := 0.001
const ROTATION_TOLERANCE := 0.05

var level: Node3D
var frame := 0
var failures := 0
var checks := 0


func _process(_delta: float) -> bool:
	frame += 1
	if frame == 2:
		level = (load("res://scenes/level.tscn") as PackedScene).instantiate()
		root.add_child(level)
		return false
	# LevelShell applies materials in _Ready; give it a frame to have run.
	if frame < 5:
		return false

	for shell_name in SHELLS:
		_check_placement(shell_name, SHELLS[shell_name])
	_check_second_slots()
	_check_no_imported_materials()
	_check_materials_are_in_the_scene()
	_check_nothing_applies_materials()

	print("")
	if failures == 0:
		print("PASS: %d checks" % checks)
	else:
		print("FAIL: %d of %d checks failed" % [failures, checks])
	quit(1 if failures > 0 else 0)
	return true


## Compares the level's copy of a shell against a pristine instance of the same FBX.
func _check_placement(shell_name: String, key: String) -> void:
	checks += 1
	var shell := level.get_node_or_null(shell_name) as Node3D
	if shell == null:
		_fail("level.tscn has no %s" % shell_name)
		return

	var pristine := (load(MODELS[key]) as PackedScene).instantiate()
	var want: Dictionary = EXPECTED.get(key, {})

	var mine := {}
	var theirs := {}
	_collect(shell, mine)
	_collect(pristine, theirs)

	if mine.keys().size() != theirs.keys().size():
		_fail("%s has %d meshes, %s has %d - the model changed shape" % [
			shell_name, mine.size(), key, theirs.size()])
		return

	var problems: Array[String] = []
	for name in theirs:
		if not mine.has(name):
			problems.append("%s is missing" % name)
			continue
		var got: Transform3D = mine[name]
		var base: Transform3D = theirs[name]
		var expected := base
		if want.has(name):
			expected = Transform3D(Basis(want[name][1] as Quaternion), want[name][0] as Vector3)

		var dp: float = got.origin.distance_to(expected.origin)
		var dr: float = rad_to_deg(got.basis.get_rotation_quaternion().angle_to(
			expected.basis.get_rotation_quaternion()))
		if dp <= POSITION_TOLERANCE and dr <= ROTATION_TOLERANCE:
			continue

		if want.has(name):
			problems.append("%s is at %v, but nivelEscena puts it at %v (%.3f m, %.2f deg off)" % [
				name, got.origin, expected.origin, dp, dr])
		else:
			problems.append("%s is at %v, but the FBX exports it at %v (%.3f m, %.2f deg off) - an override nivelEscena does not have" % [
				name, got.origin, expected.origin, dp, dr])

	pristine.free()
	if problems.is_empty():
		_ok("%s: all %d meshes placed as %s exports them, with %s's %d scene override(s) applied" % [
			shell_name, theirs.size(), key, key, want.size()])
	else:
		for p in problems:
			_fail("%s: %s" % [shell_name, p])


func _check_second_slots() -> void:
	var table: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TABLE))
	for key in MODELS:
		checks += 1
		if not table.has(key):
			_fail("the material table has no '%s' section" % key)
			continue

		var claims := {}
		for mesh_name in table[key]:
			if (table[key][mesh_name] as Dictionary).has("1"):
				claims[mesh_name] = true

		var pristine := (load(MODELS[key]) as PackedScene).instantiate()
		var meshes := {}
		_collect(pristine, meshes)
		var actual := {}
		for mesh_name in meshes:
			var m := pristine.find_child(mesh_name, true, false) as MeshInstance3D
			if m != null and m.mesh.get_surface_count() > 1:
				actual[mesh_name] = true

		var only_table: Array = claims.keys().filter(func(n): return not actual.has(n))
		var only_model: Array = actual.keys().filter(func(n): return not claims.has(n))
		pristine.free()

		if only_table.is_empty() and only_model.is_empty():
			_ok("%s: the %d meshes with a second material slot are exactly the %d with a second surface" % [
				key, claims.size(), actual.size()])
		else:
			_fail("%s: the renderer-to-mesh mapping is wrong. Table says these have a second slot but the model gives them one surface: %s. Model has a second surface on these but the table does not: %s." % [
				key, str(only_table), str(only_model)])


## Every surface must have been given an override. One left null is a surface still
## rendering Maya's lambert1, which is the symptom the table exists to prevent.
func _check_no_imported_materials() -> void:
	for shell_name in SHELLS:
		checks += 1
		var shell := level.get_node_or_null(shell_name) as Node3D
		var bare: Array[String] = []
		var total := 0
		for m in _meshes(shell):
			for s in m.mesh.get_surface_count():
				total += 1
				if m.get_surface_override_material(s) == null:
					bare.append("%s slot %d" % [m.name, s])
		if bare.is_empty():
			_ok("%s: all %d surfaces have their scene material" % [shell_name, total])
		else:
			_fail("%s: %d of %d surfaces keep the FBX's own material: %s" % [
				shell_name, bare.size(), total, str(bare)])


## Reads level.tscn's OWN stored overrides, entry for entry against the table.
##
## Deliberately not read off the running tree: a script could have put them there. This
## instantiates the scene with no _ready having assigned anything - the same state the
## editor is in on a fresh clone before any assembly exists - by checking the node's
## surface_material_override against the table for all 73 slots.
func _check_materials_are_in_the_scene() -> void:
	var table: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TABLE))
	var packed := load("res://scenes/level.tscn") as PackedScene
	var state := packed.get_state()

	# node path -> {slot: material path}, straight out of the scene file.
	var stored := {}
	for i in state.get_node_count():
		var path := "%s/%s" % [String(state.get_node_path(i, true)), String(state.get_node_name(i))]
		for p in state.get_node_property_count(i):
			var prop := String(state.get_node_property_name(i, p))
			if not prop.begins_with("surface_material_override/"):
				continue
			var slot := prop.split("/")[1]
			var value = state.get_node_property_value(i, p)
			var res_path := (value as Resource).resource_path if value is Resource else "<not a resource>"
			var node_name := String(state.get_node_name(i))
			if not stored.has(node_name):
				stored[node_name] = {}
			(stored[node_name] as Dictionary)[slot] = res_path

	for shell_name in SHELLS:
		checks += 1
		var key: String = SHELLS[shell_name]
		var problems: Array[String] = []
		var matched := 0
		for mesh_name in table[key]:
			var want: Dictionary = table[key][mesh_name]
			# pPlane30 is a node, not a mesh, and carries no surfaces of its own.
			if not stored.has(mesh_name):
				if _mesh_named(shell_name, mesh_name) == null:
					continue
				problems.append("%s has no override in level.tscn" % mesh_name)
				continue
			for slot in want:
				var got = (stored[mesh_name] as Dictionary).get(slot)
				if got == null:
					problems.append("%s slot %s is not in level.tscn" % [mesh_name, slot])
				elif got != want[slot]:
					problems.append("%s slot %s is %s, the table says %s" % [
						mesh_name, slot, got, want[slot]])
				else:
					matched += 1

		if problems.is_empty():
			_ok("%s: all %d surface materials are stored in level.tscn and match the table" % [
				shell_name, matched])
		else:
			_fail("%s: level.tscn and the table disagree - regenerate with tools/generate_shell_overrides.gd: %s" % [
				shell_name, str(problems)])


## The point of baking them in was to remove the load-time dependency, so assert it is gone.
##
## Behavioural, not a grep: a freshly instantiated scene has NOT had _ready called on it -
## that happens on tree entry - so whatever materials it already carries came from the scene
## file and nothing else. An earlier version of this check searched LevelShell.cs for
## "SetSurfaceOverrideMaterial" and "[Tool]", and failed on the file's own documentation of
## having once done exactly that. Source text is the wrong thing to assert on.
func _check_nothing_applies_materials() -> void:
	checks += 1
	var loose := (load("res://scenes/level.tscn") as PackedScene).instantiate()
	var missing: Array[String] = []
	var present := 0
	for shell_name in SHELLS:
		var shell := loose.get_node_or_null(shell_name)
		if shell == null:
			continue
		for m in _meshes(shell):
			for s in m.mesh.get_surface_count():
				if m.get_surface_override_material(s) == null:
					missing.append("%s slot %d" % [m.name, s])
				else:
					present += 1
	loose.free()

	if missing.is_empty():
		_ok("all %d surfaces already have their material before _ready runs, so the editor needs no C# build to draw the level" % present)
	else:
		_fail("%d surface(s) only get a material once a script runs, so a fresh clone with no C# assembly draws the level wrong: %s" % [
			missing.size(), str(missing.slice(0, 6))])

	# The [Tool] attribute specifically, with comments stripped so the file may describe
	# its own history without tripping this.
	checks += 1
	var code := ""
	for line in FileAccess.get_file_as_string("res://scripts/Gameplay/LevelShell.cs").split("\n"):
		var trimmed := line.strip_edges()
		if not trimmed.begins_with("//"):
			code += trimmed + "\n"
	if code.contains("[Tool]"):
		_fail("LevelShell.cs is [Tool] again; if it draws anything, the editor depends on a C# build")
	else:
		_ok("LevelShell.cs is not [Tool]")


func _mesh_named(shell_name: String, mesh_name: String) -> MeshInstance3D:
	var shell := level.get_node_or_null(shell_name)
	if shell == null:
		return null
	return shell.find_child(mesh_name, true, false) as MeshInstance3D


func _collect(n: Node, out: Dictionary) -> void:
	if n is MeshInstance3D:
		out[String(n.name)] = (n as Node3D).transform
	for c in n.get_children():
		_collect(c, out)


func _meshes(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_meshes(c))
	return out


func _ok(m: String) -> void:
	print("  ok    ", m)


func _fail(m: String) -> void:
	failures += 1
	print("  FAIL  ", m)
