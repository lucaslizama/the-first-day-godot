# Decides whether the level's world placements need conjugating by M = diag(-1,1,1).
#
#   godot-mono --headless --path . --script tools/check_mirror.gd
#
# tools/verify_table_pcs.gd established that each model's LOCAL space differs
# between Unity's importer and Godot's by exactly M. If that also holds for
# nivel/nivel_p2, then placing props at unmirrored Unity world X puts them in the
# wrong place relative to the shell, and the whole level is subtly wrong.
#
# The test does not need Unity. Coworkers stand on floors and props sit on floors,
# so "is there geometry beneath this thing" is a property the correct layout has
# and a mirrored one does not. Every placed node is probed twice: once where it
# currently is, once at M applied to its position. Whichever scores better is the
# convention the shell actually wants.
extends SceneTree

const GROUPS := ["Coworkers", "Props", "Platforms", "Hammers"]
const PROBE_UP := 0.15
const PROBE_DOWN := 60.0
const RESTING := 0.5
const EMBED_RADIUS := 0.2

var frame: int = 0
var level: Node3D
var embed_shape: RID


func _initialize() -> void:
	level = (load("res://scenes/level.tscn") as PackedScene).instantiate()
	root.add_child(level)


func _process(_delta: float) -> bool:
	frame += 1
	if frame < 3:
		return false

	# Trimesh shapes are one-sided by default, so a floor whose normals point away
	# from the probe reports nothing and a correct placement looks unsupported.
	# Turning backface collision on makes "is there a surface here" independent of
	# which way the artist wound the triangles.
	var flipped := _enable_backfaces(level)
	print("backface collision enabled on %d trimesh shapes" % flipped)

	embed_shape = PhysicsServer3D.sphere_shape_create()
	PhysicsServer3D.shape_set_data(embed_shape, EMBED_RADIUS)

	var space := root.world_3d.direct_space_state
	print("")
	print("Two measures, each computed for the placement as-is and for M applied to it.")
	print("  resting - a surface within %.1f m below, i.e. standing on something" % RESTING)
	print("  contact - solid geometry within %.1f m of the origin. NOT containment:" % EMBED_RADIUS)
	print("            a trimesh has no interior, so this is proximity to a surface.")
	print("            Props belong against floors and walls, so more is better.")
	print("")
	print("%-11s %5s   %-19s   %-19s" % ["group", "n", "as placed", "x negated"])
	print("%-11s %5s   %-19s   %-19s" % ["", "", "resting   contact", "resting   contact"])
	print("-".repeat(64))

	var t := {"rest_as": 0, "rest_mi": 0, "emb_as": 0, "emb_mi": 0, "n": 0}

	for group_name in GROUPS:
		var group := level.get_node_or_null(NodePath(group_name)) as Node3D
		if group == null:
			print("%-11s  (absent)" % group_name)
			continue

		var g := {"rest_as": 0, "rest_mi": 0, "emb_as": 0, "emb_mi": 0, "n": 0}
		for child in group.get_children():
			if child is not Node3D:
				continue
			var p: Vector3 = (child as Node3D).global_transform.origin
			var m := Vector3(-p.x, p.y, p.z)
			g["n"] += 1

			var d_as := _drop(space, p)
			var d_mi := _drop(space, m)
			if d_as >= 0.0 and d_as <= RESTING:
				g["rest_as"] += 1
			if d_mi >= 0.0 and d_mi <= RESTING:
				g["rest_mi"] += 1
			if _embedded(space, p):
				g["emb_as"] += 1
			if _embedded(space, m):
				g["emb_mi"] += 1

		for k in g:
			t[k] += g[k]
		print("%-11s %5d   %4d %8d      %4d %8d" % [
			group_name, g["n"], g["rest_as"], g["emb_as"], g["rest_mi"], g["emb_mi"],
		])

	print("-".repeat(64))
	print("%-11s %5d   %4d %8d      %4d %8d" % [
		"TOTAL", t["n"], t["rest_as"], t["emb_as"], t["rest_mi"], t["emb_mi"],
	])

	# How far below each thing the nearest surface is. A correct layout clusters
	# near zero; a wrong one scatters, with things far above floors or over holes.
	print("")
	print("drop to the nearest surface below, %d placed nodes" % t["n"])
	print("%-11s %8s %8s %8s %8s %8s %9s" % ["", "<0.1 m", "<0.5 m", "<2 m", "<10 m", "nothing", "contact"])
	# All four axis conventions, so a partial truth cannot pass for the whole one.
	# The doc settled Z as unchanged by measurement; this re-tests it against the
	# same evidence rather than trusting it.
	for conv in [
		{"label": "as placed", "sx": 1.0, "sz": 1.0},
		{"label": "-x", "sx": -1.0, "sz": 1.0},
		{"label": "-z", "sx": 1.0, "sz": -1.0},
		{"label": "-x -z", "sx": -1.0, "sz": -1.0},
	]:
		_histogram(space, conv["label"], conv["sx"], conv["sz"])

	print("")
	var rest_gain: int = t["rest_mi"] - t["rest_as"]
	var contact_gain: int = t["emb_mi"] - t["emb_as"]
	print("x negation changes resting by %+d and contact by %+d" % [rest_gain, contact_gain])
	if rest_gain > 0 and contact_gain > 0:
		print("VERDICT: x-negated wins on BOTH measures - more props stand on something,")
		print("         and more sit against geometry instead of floating in space. The")
		print("         world transforms need conjugating by M, as the models already are.")
	elif rest_gain < 0 and contact_gain < 0:
		print("VERDICT: placement as-is wins on both measures. The mirror does not apply.")
	else:
		print("VERDICT: measures disagree - do not act on this alone.")

	PhysicsServer3D.free_rid(embed_shape)
	quit()
	return true


func _histogram(space: PhysicsDirectSpaceState3D, label: String, sx: float, sz: float) -> void:
	var bins := [0, 0, 0, 0, 0]
	var contact := 0
	for group_name in GROUPS:
		var group := level.get_node_or_null(NodePath(group_name)) as Node3D
		if group == null:
			continue
		for child in group.get_children():
			if child is not Node3D:
				continue
			var o: Vector3 = (child as Node3D).global_transform.origin
			var p := Vector3(sx * o.x, o.y, sz * o.z)
			if _embedded(space, p):
				contact += 1
			var d := _drop(space, p)
			if d < 0.0:
				bins[4] += 1
			elif d < 0.1:
				bins[0] += 1
			elif d < 0.5:
				bins[1] += 1
			elif d < 2.0:
				bins[2] += 1
			else:
				bins[3] += 1
	print("%-11s %8d %8d %8d %8d %8d %9d" % [
		label, bins[0], bins[1], bins[2], bins[3], bins[4], contact,
	])


## Makes every trimesh in the level two-sided, so probes do not depend on winding.
func _enable_backfaces(node: Node) -> int:
	var n := 0
	if node is CollisionShape3D:
		var shape := (node as CollisionShape3D).shape
		if shape is ConcavePolygonShape3D:
			(shape as ConcavePolygonShape3D).backface_collision = true
			n += 1
	for child in node.get_children():
		n += _enable_backfaces(child)
	return n


## True if a small sphere at p overlaps solid geometry - the prop is sunk into it.
func _embedded(space: PhysicsDirectSpaceState3D, p: Vector3) -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape_rid = embed_shape
	q.transform = Transform3D(Basis.IDENTITY, p)
	return space.intersect_shape(q, 1).size() > 0


## Distance from a point down to the first collider, or -1 if nothing is beneath.
func _drop(space: PhysicsDirectSpaceState3D, p: Vector3) -> float:
	var from := p + Vector3(0.0, PROBE_UP, 0.0)
	var to := p - Vector3(0.0, PROBE_DOWN, 0.0)
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, to))
	if hit.is_empty():
		return -1.0
	return p.y - (hit["position"] as Vector3).y
