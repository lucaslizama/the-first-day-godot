# Checks the five tutorial key signs at the level's start.
#
#   godot-mono --headless --path . --script tools/verify_tutorial_keys.gd
#
# These are the last piece of unported level content, and they are not like the other props: plain
# GameObjects carrying Unity's BUILT-IN QUAD mesh, so nothing is imported and there is no model whose
# transform can be compared against. Everything below is therefore checked against Unity's own
# numbers rather than against the generator's output, per the rule that a verifier must not import
# the math it verifies.
#
# THE SIZES ARE THE INTERESTING PART. Each sign's world width and height are the PRODUCT of the
# `Tutorial` parent's non-uniform scale (5.8803244, 2.9868073, 1) and the child's own - numbers read
# straight out of nivelEscena.unity, multiplied here rather than copied from the built scene. That
# makes this an independent re-derivation: if the extractor's matrix composition, the row-major
# Transform3D order, or the conjugation were wrong, these products would not match.
#
# They caught exactly that. The generator first emitted the basis as COLUMNS while Godot's
# Transform3D constructor takes ROWS, and the transpose of a rotation times a non-uniform scale moves
# each scale factor onto a different axis: the tutorial board measured 1 m wide instead of 5.88 while
# its height stayed right, which is the kind of half-correct result that survives a glance.
extends SceneTree

const KEYS := "res://scenes/tutorial_keys.tscn"

## Unity's `Tutorial` parent scale, from nivelEscena.unity.
const PARENT := Vector2(5.8803244, 2.9868073)

## Each sign's own m_LocalScale x and y, from the same scene. World size is the product.
const CHILDREN := {
	"Tutorial": Vector2(1.0, 1.0),
	"WASD": Vector2(0.27134758, 0.32844943),
	"Spacebar": Vector2(0.5155682, 0.21032742),
	"Shift": Vector2(0.34315127, 0.2415331),
	# WASD (1) carries its own -90.3 degree Y rotation under the parent's non-uniform scale, so its
	# basis SHEARS and its columns are not simply the scale product. Checked for shear instead, below.
}

## The sheared one, and the shear measured off the composed matrix. Pinned so a change is loud.
##
## It is the X-Z pair, not X-Y: the parent's non-uniform scale sits between two Y rotations, which
## tilts the local Z axis relative to X. For a FLAT quad that moves no vertex - every vertex has
## z = 0 - so it only tilts the normal slightly. It is pinned anyway because it is the fingerprint of
## the composition being carried as a matrix: any round-trip through position-rotation-scale would
## orthogonalise it away, and this is the only prop that would notice.
const SHEARED := "WASD_1"
const SHEAR := 0.0304
const SHEAR_TOLERANCE := 0.005

const MATERIALS := {
	"Tutorial": "res://materials/props/tutorial_board.tres",
	"WASD": "res://materials/props/wasd.tres",
	"Spacebar": "res://materials/props/space_key_l.tres",
	"Shift": "res://materials/props/shift_key.tres",
	"WASD_1": "res://materials/props/controller.tres",
}

## Unity gave all five m_Convex: 0, m_IsTrigger: 0 - solid concave. Two triangles per quad.
const TRIANGLES := 10

const SIZE_TOLERANCE := 0.01

var checks := 0
var failures := 0


func _initialize() -> void:
	var scene := load(KEYS) as PackedScene
	if scene == null:
		_fail("cannot load %s" % KEYS)
		_finish()
		return
	var keys := scene.instantiate()
	root.add_child(keys)

	_check_present(keys)
	_check_sizes(keys)
	_check_shear(keys)
	_check_materials(keys)
	_check_collision(keys)
	_finish()


func _quads(keys: Node) -> Dictionary:
	var out := {}
	for c in keys.get_children():
		if c is MeshInstance3D:
			out[String(c.name)] = c
	return out


func _check_present(keys: Node) -> void:
	checks += 1
	var quads := _quads(keys)
	var missing: Array[String] = []
	for name in MATERIALS:
		if not quads.has(name):
			missing.append(name)
	if missing.is_empty():
		_ok("all %d signs are present: %s" % [quads.size(), str(quads.keys())])
	else:
		_fail("missing %s; the scene holds %s" % [str(missing), str(quads.keys())])


## World size along a local axis, obtained by TRANSFORMING that axis rather than by reading a row or a
## column off the basis. Basis.get_column does not exist in GDScript, and basis.x reported every sign
## as 1 x 1 metre in an earlier probe while the scene was demonstrably correct - a cycle wasted chasing
## a bug that was in the instrument. `basis * Vector3(1, 0, 0)` cannot be misread either way.
func _check_sizes(keys: Node) -> void:
	var quads := _quads(keys)
	for name in CHILDREN:
		checks += 1
		var node := quads.get(name) as MeshInstance3D
		if node == null:
			_fail("%s is not in the scene, so its size cannot be checked" % name)
			continue
		var child: Vector2 = CHILDREN[name]
		var want := Vector2(PARENT.x * child.x, PARENT.y * child.y)
		var basis := node.transform.basis
		var got := Vector2(
			(basis * Vector3(1.0, 0.0, 0.0)).length(),
			(basis * Vector3(0.0, 1.0, 0.0)).length())
		if absf(got.x - want.x) <= SIZE_TOLERANCE and absf(got.y - want.y) <= SIZE_TOLERANCE:
			_ok("%-9s is %.3f x %.3f m, which is Unity's %.4f x %.4f parent scale times its own" % [
				name, got.x, got.y, PARENT.x, PARENT.y])
		else:
			_fail("%s is %.3f x %.3f m, expected %.3f x %.3f from Unity's scales. Is the Transform3D row-major?" % [
				name, got.x, got.y, want.x, want.y])


func _check_shear(keys: Node) -> void:
	checks += 1
	var node := _quads(keys).get(SHEARED) as MeshInstance3D
	if node == null:
		_fail("%s is missing" % SHEARED)
		return
	var basis := node.transform.basis
	var x := (basis * Vector3(1.0, 0.0, 0.0)).normalized()
	var y := (basis * Vector3(0.0, 1.0, 0.0)).normalized()
	var z := (basis * Vector3(0.0, 0.0, 1.0)).normalized()
	# Worst of the three pairs. Checking only X against Y found 0.0000 and failed, because this
	# particular shear is between X and Z - a check looking at the wrong pair of axes.
	var shear: float = maxf(absf(x.dot(y)), maxf(absf(x.dot(z)), absf(y.dot(z))))
	if absf(shear - SHEAR) <= SHEAR_TOLERANCE:
		_ok("%s keeps its %.4f shear, which a position-rotation-scale decomposition would have lost" % [
			SHEARED, shear])
	else:
		_fail("%s shears %.4f, expected %.4f. Unity composes its own -90.3 degree Y rotation under the parent's non-uniform scale, and that product is not orthogonal." % [
			SHEARED, shear, SHEAR])


func _check_materials(keys: Node) -> void:
	var quads := _quads(keys)
	for name in MATERIALS:
		checks += 1
		var node := quads.get(name) as MeshInstance3D
		if node == null:
			_fail("%s is missing, so its material cannot be checked" % name)
			continue
		var material := node.get_surface_override_material(0)
		if material == null:
			_fail("%s has no material override; it would render as untextured white" % name)
			continue
		if material.resource_path != MATERIALS[name]:
			_fail("%s uses %s, expected %s" % [name, material.resource_path, MATERIALS[name]])
			continue
		var standard := material as StandardMaterial3D
		if standard == null:
			_fail("%s is not a StandardMaterial3D" % name)
		elif name != "Tutorial" and standard.albedo_texture == null:
			_fail("%s has no albedo texture; Unity's material set _MainTex" % name)
		else:
			_ok("%-9s uses %s" % [name, MATERIALS[name].get_file()])


func _check_collision(keys: Node) -> void:
	checks += 1
	var body := keys.get_node_or_null("Collision") as StaticBody3D
	if body == null:
		_fail("no Collision body; Unity gave all five solid MeshColliders")
		return
	var shape_node := body.get_node_or_null("Shape") as CollisionShape3D
	var shape := shape_node.shape as ConcavePolygonShape3D if shape_node != null else null
	if shape == null:
		_fail("the Collision body has no ConcavePolygonShape3D")
		return
	var count := shape.get_faces().size() / 3
	if count == TRIANGLES:
		_ok("collision is %d triangles, two per quad, baked in scene space so the sheared sign needs no sheared shape" % count)
	else:
		_fail("collision has %d triangles, expected %d" % [count, TRIANGLES])


func _finish() -> void:
	print("")
	if failures == 0:
		print("PASS: %d checks" % checks)
	else:
		print("FAIL: %d of %d checks failed" % [failures, checks])
	quit(1 if failures > 0 else 0)


func _ok(m: String) -> void:
	print("  ok    ", m)


func _fail(m: String) -> void:
	failures += 1
	print("  FAIL  ", m)
