# Bakes the level shell's per-surface materials into scenes/level.tscn.
#
#   godot-mono --headless --path . --script tools/generate_shell_overrides.gd -- [--dry]
#
# Why this exists, and why it replaces a script that did the same work at load time:
#
# Unity assigned the shell's materials per renderer-SLOT, and the same FBX material name
# resolves differently in different places - lambert1 is mat_generalTransparencia on
# nivel's pPlane meshes but mat_general on its polySurface slot 1, and nivel_p2 reverses
# the polySurface mapping. LevelShell.cs used to apply all 73 of those assignments in
# _Ready, with [Tool] so the editor showed them too, and its documentation said Godot
# "cannot express" the per-slot mapping.
#
# That was wrong, and the narrower true statement matters: the IMPORTER cannot express it,
# because it keys external materials by material NAME and there are only two names for four
# different (mesh-set, slot) outcomes. The SCENE can express it exactly -
# `surface_material_override/N` is per mesh and per slot, which is precisely Unity's
# granularity. Overriding a property on a child of an instanced scene is ordinary .tscn
# syntax; it needed no code at all.
#
# The cost of getting that wrong was real. Because the materials came from a [Tool] C#
# script, the level's appearance depended on a compiled C# assembly existing. On a fresh
# clone - where .godot/ and bin/ are both gitignored - the first editor session runs with
# no assembly, so nothing applied the materials and the meshes fell back to the FBX's own
# lambert1/lambert2. Both of those have vertex_color_use_as_albedo = true, and the level's
# vertex colours are PURE RED, mean (0.457, 0.000, 0.000): the red channel is data for
# level_fade.gdshader's wobble and alpha, not paint. So the whole level rendered red in the
# editor until the editor was restarted. Baked into the scene, that failure mode cannot
# happen.
#
# This owns only the region between the two markers below. Everything else in level.tscn,
# including the two material ext_resources it references, is hand-written and left alone.
extends SceneTree

const SCENE := "res://scenes/level.tscn"
const TABLE := "res://models/level/level_materials.json"
const BEGIN := "; >>> BEGIN generated shell overrides - tools/generate_shell_overrides.gd"
const END := "; <<< END generated shell overrides"

## Material path -> the ext_resource id hand-declared in level.tscn's header.
const RESOURCE_IDS := {
	"res://materials/level_general.tres": "19_general",
	"res://materials/level_transparent.tres": "20_transparent",
}

## The shell nodes in level.tscn, and the FBX instance node under each.
const SHELLS := [
	{"key": "nivel.fbx", "node": "Shell", "instance": "nivel"},
	{"key": "nivel_p2.fbx", "node": "ShellP2", "instance": "nivel_p2"},
]

## nivelEscena also moves two of nivel_p2's children after instancing it. Kept here rather
## than in the material table because it comes from a different part of the scene file, and
## because these two blocks must merge with the material overrides for the same nodes - two
## [node] blocks naming one node is not valid .tscn.
##
## Already conjugated by M = diag(-1, 1, 1): position X negates, and for a rotation y and z
## negate. tools/verify_level_shells.gd re-derives both from Unity independently, so a wrong
## value here does not go unnoticed.
const TRANSFORMS := {
	"nivel_p2.fbx": {
		"polySurface16": {
			"value": "Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 37.26, 48.98, -0.23)",
			"note": "Unity (-37.26, 48.98, -0.23); the FBX exports it at (51.791214, 50.000011, 40.291302).",
		},
		"polySurface17": {
			"value": "Transform3D(0.795548, 0, -0.605891, 0, 1, 0, 0.605891, 0, 0.795548, -46.13, 50.54, 9.94)",
			"note": "Unity (46.13, 50.54, 9.94) with m_LocalRotation x/y/w overridden but not z - the three given components already norm to 1.000000000, so z keeps the FBX's 0. Its m_LocalEulerAnglesHint.y of 37.555 disagrees with its own quaternion by a quarter degree; the quaternion is what the engine used.",
		},
	},
}

var lines: Array[String] = []
var mesh_count := 0
var slot_count := 0
var failures := 0


func _init() -> void:
	var dry := "--dry" in OS.get_cmdline_user_args()
	var table: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TABLE))

	lines.append(BEGIN)
	lines.append(";")
	lines.append("; Unity assigned these per renderer-slot; see the header of the generator for why they")
	lines.append("; live in the scene rather than in a script. Regenerate with:")
	lines.append(";")
	lines.append(";     godot-mono --headless --path . --script tools/generate_shell_overrides.gd")
	lines.append(";")
	lines.append("; Do not edit by hand - tools/verify_level_shells.gd checks every entry against")
	lines.append("; models/level/level_materials.json, which tools/extract_level_materials.py derives")
	lines.append("; from nivelEscena.")

	for shell in SHELLS:
		_emit_shell(shell, table)

	# THE OVERRIDES ABOVE DO NOT SURVIVE A SAVE WITHOUT THESE. Godot's loader applies an override
	# on a child of an instanced sub-scene whether or not the instance is editable, but its
	# PACKER discards it unless the instance is marked editable - so opening level.tscn in the
	# editor and saving it deletes every block this tool writes. That happened twice, and was
	# twice blamed on a plugin; it needs no plugin and is reproducible in one second with
	# tools/verify_scene_survives_save.gd.
	#
	# Emitted from here, inside the generated region, rather than left at the end of the scene by
	# hand: they are a property of these overrides existing, so whatever writes the overrides
	# should write them. Godot requires them after all node blocks, which the region already is.
	lines.append("")
	for shell in SHELLS:
		lines.append('[editable path="%s/%s"]' % [shell["node"], shell["instance"]])

	lines.append("")
	lines.append(END)

	if failures > 0:
		printerr("FAIL: %d problem(s); level.tscn not written." % failures)
		quit(1)
		return

	print("%d meshes, %d surface materials" % [mesh_count, slot_count])
	var block := "\n".join(lines) + "\n"
	if dry:
		print(block)
		print("dry run, nothing written")
		quit()
		return

	if not _write(block):
		quit(1)
		return
	print("wrote %s" % SCENE)
	quit()


func _emit_shell(shell: Dictionary, table: Dictionary) -> void:
	var key: String = shell["key"]
	if not table.has(key):
		_fail("the material table has no '%s' section" % key)
		return

	var model := "res://models/level/%s" % key
	var root := (load(model) as PackedScene).instantiate()
	var section: Dictionary = table[key]
	var transforms: Dictionary = TRANSFORMS.get(key, {})

	lines.append("")
	lines.append("; ---- %s, under %s ----" % [key, shell["node"]])

	var seen := {}
	for mesh in _meshes(root):
		seen[String(mesh.name)] = true
		var name := String(mesh.name)
		if not section.has(name):
			_fail("%s: no material entry for mesh '%s'; it would keep the FBX's own material" % [key, name])
			continue

		# Relative to the FBX instance root, which level.tscn names shell["instance"].
		var parent_path := String(root.get_path_to(mesh.get_parent()))
		var full := "%s/%s" % [shell["node"], shell["instance"]]
		if parent_path != ".":
			full += "/" + parent_path

		lines.append("")
		var t: Dictionary = transforms.get(name, {})
		if not t.is_empty():
			lines.append("; %s" % t["note"])
		lines.append('[node name="%s" parent="%s" index="%d"]' % [
			name, full, mesh.get_index()])
		if not t.is_empty():
			lines.append("transform = %s" % t["value"])

		var slots: Dictionary = section[name]
		var surfaces: int = mesh.mesh.get_surface_count()
		for slot in _sorted_int_keys(slots):
			var path: String = slots[str(slot)]
			if slot >= surfaces:
				_fail("%s/%s has %d surface(s), but the table assigns slot %d" % [
					key, name, surfaces, slot])
				continue
			if not RESOURCE_IDS.has(path):
				_fail("%s/%s slot %d uses '%s', which has no ext_resource id in level.tscn" % [
					key, name, slot, path])
				continue
			lines.append('surface_material_override/%d = ExtResource("%s")' % [
				slot, RESOURCE_IDS[path]])
			slot_count += 1
		mesh_count += 1

	# An entry naming something that is not a mesh is expected for exactly one node and
	# harmless; anything else means the table and the model have diverged.
	for entry in section:
		if seen.has(entry):
			continue
		if root.find_child(entry, true, false) != null:
			print("  note: '%s' is a node but not a mesh; its children carry their own materials" % entry)
		else:
			_fail("%s: the table names '%s', but no such node exists in the model" % [key, entry])

	root.free()


func _write(block: String) -> bool:
	var text := FileAccess.get_file_as_string(SCENE)
	if text == "":
		_fail("could not read %s" % SCENE)
		return false

	var begin := text.find(BEGIN)
	if begin >= 0:
		var stop := text.find(END, begin)
		if stop < 0:
			printerr("FAIL: %s has a BEGIN marker with no END; refusing to guess where the block ends." % SCENE)
			return false
		text = text.substr(0, begin) + block + text.substr(stop + END.length() + 1)
	else:
		if not text.ends_with("\n"):
			text += "\n"
		text += "\n" + block

	var f := FileAccess.open(SCENE, FileAccess.WRITE)
	if f == null:
		printerr("FAIL: cannot open %s for writing" % SCENE)
		return false
	f.store_string(text)
	return true


func _sorted_int_keys(d: Dictionary) -> Array:
	var out := []
	for k in d:
		out.append(int(k))
	out.sort()
	return out


func _meshes(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		out.append(n)
	for c in n.get_children():
		out.append_array(_meshes(c))
	return out


func _fail(m: String) -> void:
	failures += 1
	printerr("  FAIL  ", m)
