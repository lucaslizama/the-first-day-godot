extends SceneTree

## Works out which doors show the player their unfinished back.
##
## puerta.fbx has its panelled, knobbed face on local +Z; local -Z is a flat
## black back. So a door is wrong when its +Z points into the void instead of
## into the building.
##
## A single ray along the normal is too noisy - doors sit in doorways, where both
## sides are open and whether a ray connects depends on distant geometry. Casting
## a fan over each hemisphere and comparing how enclosed each side is separates
## "faces a room" from "faces open sky" reliably.

const REACH := 40.0
const CONE_DEG := 55.0
var _frame := 0

func _process(_d: float) -> bool:
	_frame += 1
	if _frame < 4:
		return false

	var level := (load("res://scenes/level.tscn") as PackedScene).instantiate()
	root.add_child(level)
	var space: PhysicsDirectSpaceState3D = level.get_world_3d().direct_space_state

	var doors: Array[Node3D] = []
	_find(level, doors)
	doors.sort_custom(func(a, b): return a.name < b.name)

	print("%-12s %7s   %-13s %-13s  %s" % ["door", "det", "front(+Z)", "back(-Z)", "verdict"])
	var wrong: Array[String] = []
	for d in doors:
		var b := d.global_transform.basis
		var origin := d.global_position + Vector3(0.0, 2.0, 0.0)
		var f := b.z.normalized()
		var front := _enclosure(space, origin, f)
		var back := _enclosure(space, origin, -f)
		var verdict := "ok"
		# The void side connects with far fewer rays. Require a clear margin so
		# doors between two rooms are not flagged.
		if back - front >= 0.25:
			verdict = "SHOWS ITS BACK"
			wrong.append(String(d.name))
		print("%-12s %7.3f   hits %4.0f%%     hits %4.0f%%     %s" % [
			d.name, b.determinant(), front * 100.0, back * 100.0, verdict,
		])
	print("")
	print("doors showing their back: %d of %d" % [wrong.size(), doors.size()])
	print("names: %s" % ", ".join(wrong))
	return true

## Fraction of a cone's rays that hit level geometry.
func _enclosure(space: PhysicsDirectSpaceState3D, origin: Vector3, dir: Vector3) -> float:
	var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var right := dir.cross(up).normalized()
	up = right.cross(dir).normalized()
	var hits := 0
	var total := 0
	for ring in [0.0, CONE_DEG * 0.5, CONE_DEG]:
		var count := 1 if ring == 0.0 else 8
		for i in count:
			var a := TAU * float(i) / float(count)
			var t := deg_to_rad(ring)
			var v := (dir * cos(t) + (right * cos(a) + up * sin(a)) * sin(t)).normalized()
			var q := PhysicsRayQueryParameters3D.create(origin, origin + v * REACH)
			if not space.intersect_ray(q).is_empty():
				hits += 1
			total += 1
	return float(hits) / float(total)

func _find(node: Node, out: Array[Node3D]) -> void:
	if node.name.begins_with("puerta_") and node is Node3D:
		out.append(node)
	for c in node.get_children():
		_find(c, out)
