# Checks puertaInicio: the leaf's collision, the trigger, and the swing.
#
#   godot-mono --headless --path . --script tools/verify_door.gd
#
# Unity's Door is one line - OnTriggerEnter sets the animator's `Open` trigger - and the
# animator has a clipless default state, one transition to `puertaAbrir`, and no way back.
# So the door rests closed, opens once, and stays open.
#
# The angles come from puertaAbrir.anim, whose 11 keys hold 0, 10.63, 53.16, 95.69 and
# 106.32 degrees about Y. This asserts the FINAL angle and its sign, since the sign is the
# diag(-1, 1, 1) conjugation applied to a rotation and is the thing most likely to be
# wrong. It also asserts the leaf is solid and the frame is not, matching the prefab, where
# only `puertita` carries a MeshCollider.
extends SceneTree

const FINAL_DEGREES := -106.32
const TOLERANCE := 0.5

var level: Node3D
var door: Node3D
var leaf: Node3D
var trigger: Area3D
var anim: AnimationPlayer

var frame := 0
var opened_at := -1.0
var clock := 0.0
var failures := 0
var checks := 0


func _initialize() -> void:
	level = (load("res://scenes/level.tscn") as PackedScene).instantiate()
	root.add_child(level)
	door = level.get_node("Props/puertaInicio_01")
	leaf = door.get_node("Model/puertaInicio/puertita")
	trigger = door.get_node("Trigger")
	anim = door.get_node("AnimationPlayer")


func _physics_process(delta: float) -> bool:
	frame += 1
	clock += delta

	if frame == 1:
		_static_checks()

	# Put the player inside the trigger. Its box is 2 x 3.97 x 1 centred (0, 2, -0.24) in
	# the door's unscaled space, so the world centre is the shape node's own origin.
	if frame == 30:
		var shape := trigger.get_node("Collider") as Node3D
		var player := level.get_node("Player") as Node3D
		print("   moving the player to the trigger at %.3v" % shape.global_position)
		player.global_position = shape.global_position

	if opened_at < 0.0 and door.get("IsOpen"):
		opened_at = clock
		print("   %5.2fs door reported open" % clock)

	# Give the 0.333 s clip time to finish.
	if opened_at >= 0.0 and clock > opened_at + 1.0:
		_swing_checks()
		print("")
		if failures == 0:
			print("PASS: %d checks" % checks)
		else:
			print("FAIL: %d of %d checks failed" % [failures, checks])
		quit(1 if failures > 0 else 0)
		return true

	if frame > 400:
		_fail("the door never opened; the trigger did not fire")
		print("")
		print("FAIL: %d of %d checks failed" % [failures, checks])
		quit(1)
		return true
	return false


func _static_checks() -> void:
	# Only the leaf is solid, as in the prefab.
	checks += 1
	var leaf_bodies := _bodies(leaf)
	if leaf_bodies.is_empty():
		_fail("the leaf has no StaticBody3D; Unity gave puertita a MeshCollider")
	else:
		var shape := (leaf_bodies[0].get_child(0) as CollisionShape3D).shape
		if shape is ConcavePolygonShape3D:
			_ok("the leaf is solid, trimesh (Unity had m_Convex 0)")
		else:
			_fail("the leaf's shape is %s, expected ConcavePolygonShape3D" % shape.get_class())

	checks += 1
	var frame_node := door.get_node("Model/puertaInicio/marquito")
	if _bodies(frame_node).is_empty():
		_ok("the frame is not solid, matching the prefab")
	else:
		_fail("the frame has collision; only puertita had a MeshCollider")

	# The trigger must not be parented to the leaf, or it swings away with the door.
	checks += 1
	if trigger.get_parent() == door:
		_ok("the trigger sits on the root, not on the swinging leaf")
	else:
		_fail("the trigger's parent is %s; Unity's BoxCollider was on the root" % trigger.get_parent().name)

	checks += 1
	if leaf.rotation.y == 0.0:
		_ok("the leaf starts closed (the animator's default state has no clip)")
	else:
		_fail("the leaf starts at %.2f deg, not closed" % rad_to_deg(leaf.rotation.y))


func _swing_checks() -> void:
	checks += 1
	var got := rad_to_deg(leaf.rotation.y)
	if absf(got - FINAL_DEGREES) <= TOLERANCE:
		_ok("the leaf ends at %.2f deg (expected %.2f)" % [got, FINAL_DEGREES])
	else:
		_fail("the leaf ended at %.2f deg, expected %.2f - if the magnitude is right and the sign is not, the conjugation of the rotation is inverted" % [got, FINAL_DEGREES])

	# Opening twice would restart the clip and slam the door.
	checks += 1
	var before := leaf.rotation.y
	trigger.emit_signal("body_entered", level.get_node("Player"))
	if is_equal_approx(leaf.rotation.y, before) and not anim.is_playing():
		_ok("a second trigger does not replay the clip")
	else:
		_fail("a second trigger restarted the animation")


func _bodies(node: Node) -> Array[StaticBody3D]:
	var out: Array[StaticBody3D] = []
	if node is StaticBody3D:
		out.append(node)
	for c in node.get_children():
		out.append_array(_bodies(c))
	return out


func _ok(m: String) -> void:
	print("  ok    ", m)


func _fail(m: String) -> void:
	failures += 1
	print("  FAIL  ", m)
