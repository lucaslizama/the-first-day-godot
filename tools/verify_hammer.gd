# Checks that a hammer's collision is where the hammer is drawn, and swings with it.
#
#   godot-mono --headless --path . --script tools/verify_hammer.gd
#
# The bug this exists for: the hammer's collision appeared to be out of sync with its
# animation. It was not a timing problem. Unity's animated `martillo` node carries a rest
# rotation of -80 degrees about Z (m_LocalRotation z = -0.64278764), and Godot's FBX
# importer BAKES that into the mesh node (-79.6898 degrees). The swing animation drives
# `Arm` with absolute angles straight from Unity's clip, -80 to +80, so with the rest pose
# still baked in the mesh received the animated angle PLUS -79.69 while the colliders
# received the animated angle alone. The drawn hammer sat about 80 degrees from the thing
# that hits you - and because the head is 6 m out, that is metres of error.
#
# Four assertions, in the order the diagnosis went:
#   1. the physics transform tracks the node    (rules the timing hypothesis back out)
#   2. the FBX's baked rest rotation is what the scene's correction assumes
#   3. mesh volume and collider volume coincide in Arm space
#   4. the swing still covers Unity's full -80..+80 over 2.6333 s
extends SceneTree

const BAKED_REST_DEGREES := -79.6898114617764
const BAKED_TOLERANCE := 0.001
const ALIGN_TOLERANCE := 0.01
const SWING_DEGREES := 80.0
const SWING_TOLERANCE := 0.5
const TICKS := 170

var level: Node3D
var hammer: Node3D
var arm: AnimatableBody3D
var frame := 0
var worst_phys := 0.0
var worst_align := 0.0
var min_ang := INF
var max_ang := -INF
var failures := 0
var checks := 0


func _initialize() -> void:
	level = (load("res://scenes/level.tscn") as PackedScene).instantiate()
	root.add_child(level)
	hammer = level.get_node("Hammers").get_child(0)
	arm = hammer.get_node("Arm")
	_check_baked_rest()


## The scene's Model transform is the inverse of this; if a reimport changes it, the
## correction is stale and the hammer silently desynchronises again.
func _check_baked_rest() -> void:
	checks += 1
	var model := (load("res://models/props/martillo.fbx") as PackedScene).instantiate()
	var grp := model.get_node_or_null("GRP_martillo") as Node3D
	var mesh := grp.get_node_or_null("martillo") as Node3D if grp != null else null
	if mesh == null:
		_fail("martillo.fbx no longer has GRP_martillo/martillo; the scene's correction is stale")
		return
	var local: Transform3D = grp.transform * mesh.transform
	var deg := rad_to_deg(local.basis.get_euler().z)
	if absf(deg - BAKED_REST_DEGREES) > BAKED_TOLERANCE:
		_fail("the FBX's baked rest rotation is %.6f deg, the scene assumes %.6f - update hammer.tscn's Model transform to its inverse" % [deg, BAKED_REST_DEGREES])
	else:
		_ok("the FBX's baked rest rotation is still %.4f deg" % deg)


func _physics_process(_delta: float) -> bool:
	frame += 1
	if frame < 6:
		return false

	# 1. What renders vs what the player collides with.
	var node_xform := arm.global_transform
	var phys_xform: Transform3D = PhysicsServer3D.body_get_state(
		arm.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM)
	worst_phys = maxf(worst_phys, node_xform.origin.distance_to(phys_xform.origin)
		+ absf(wrapf(node_xform.basis.get_euler().z - phys_xform.basis.get_euler().z, -PI, PI)))

	# 2. Mesh volume against collider volume, both in Arm space.
	var to_arm := node_xform.affine_inverse()
	var mesh_box := AABB()
	var first := true
	for m in _meshes(hammer):
		var b: AABB = (to_arm * m.global_transform) * m.mesh.get_aabb()
		mesh_box = b if first else mesh_box.merge(b)
		first = false
	var shape_box := AABB()
	first = true
	for c in arm.get_children():
		if c is not CollisionShape3D:
			continue
		var sh := (c as CollisionShape3D).shape as BoxShape3D
		var b: AABB = (to_arm * (c as Node3D).global_transform) * AABB(-sh.size * 0.5, sh.size)
		shape_box = b if first else shape_box.merge(b)
		first = false
	worst_align = maxf(worst_align,
		(shape_box.get_center() - mesh_box.get_center()).length())

	# 3. Swing range.
	var ang := rad_to_deg(node_xform.basis.get_euler().z)
	min_ang = minf(min_ang, ang)
	max_ang = maxf(max_ang, ang)

	if frame < TICKS:
		return false

	checks += 1
	if worst_phys < 1e-4:
		_ok("the physics transform tracks the node exactly (worst %.6f)" % worst_phys)
	else:
		_fail("the physics transform lags the node by %.6f; this IS a timing problem after all" % worst_phys)

	checks += 1
	if worst_align < ALIGN_TOLERANCE:
		_ok("mesh and collider volumes coincide in Arm space (worst centre gap %.5f m)" % worst_align)
	else:
		_fail("mesh and collider centres differ by %.4f m - the drawn hammer is not where it hits. Check hammer.tscn's Model transform against the FBX's baked rest pose." % worst_align)

	checks += 1
	if absf(min_ang + SWING_DEGREES) <= SWING_TOLERANCE and absf(max_ang - SWING_DEGREES) <= SWING_TOLERANCE:
		_ok("the swing covers %.2f to %.2f deg over %d ticks" % [min_ang, max_ang, TICKS])
	else:
		_fail("the swing covers %.2f to %.2f deg, expected about +/-%.0f" % [min_ang, max_ang, SWING_DEGREES])

	print("")
	if failures == 0:
		print("PASS: %d checks" % checks)
	else:
		print("FAIL: %d of %d checks failed" % [failures, checks])
	quit(1 if failures > 0 else 0)
	return true


func _meshes(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		out.append(n)
	for c in n.get_children():
		out.append_array(_meshes(c))
	return out


func _ok(m: String) -> void:
	print("  ok    ", m)


func _fail(m: String) -> void:
	failures += 1
	print("  FAIL  ", m)
