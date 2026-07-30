# Verifies the tablePcs desk clusters against Unity's prefab, independently of
# tools/generate_table_pcs_scene.py.
#
#   godot-mono --headless --path . --script tools/verify_table_pcs.gd
#
# The generator conjugates Unity's child transforms by M = diag(-1, 1, 1) because
# the two importers read these models into local spaces that differ by exactly
# that mirror. This script does not reuse that derivation. It takes Unity's raw
# prefab numbers, composes the child world positions with plain quaternion
# algebra, mirrors the result, and compares against where the meshes actually end
# up in the built scene. If the generator's algebra is wrong, the residuals blow
# up here rather than looking plausible in the viewport.
#
# It also pins the two constants the book's placement depends on - the libro
# node's Y rotation and the 0.064442 origin offset - so a reimport that changes
# either fails loudly instead of silently sliding the book off the desk.
extends SceneTree

# Unity locals from Assets/Prefabs/Level Construction/tablePcs.prefab.
# Quaternions are xyzw, as Unity stores them.
const UNITY_CHILDREN := {
	"pc2": {"pos": Vector3(-0.19088, 1.06, 0.50227), "quat": [0.0, 0.657579, 0.0, 0.753385],
		"meshes": {"GEO_Monitor": Vector3.ZERO, "GEO_Tarro": Vector3.ZERO}},
	"pc": {"pos": Vector3(0.15591, 1.081, -0.88625), "quat": [0.0, 0.719837, 0.0, 0.694143],
		"meshes": {"GEO_Monitor": Vector3.ZERO, "GEO_Tarro": Vector3.ZERO}},
	"book": {"pos": Vector3(0.54217, 1.146, 0.33682), "quat": [0.0, 0.891047, 0.0, 0.453911],
		"meshes": {"pCube11": Vector3(-0.0181, -0.06097, -0.00236),
			"polySurface8": Vector3(-0.01383, 0.01187, 0.00142)}},
}

# The table was flattened into the prefab root, so its planes are direct children
# with identity rotation.
const UNITY_TABLE := {
	"pPlane23": Vector3(-0.55617, 0.0, 1.60378),
	"pPlane24": Vector3(-0.66705, 0.95077, 1.71463),
	"pPlane25": Vector3(-0.55617, 0.0, -1.60378),
	"pPlane26": Vector3(0.77696, 0.0, -1.60378),
	"pPlane27": Vector3(0.77696, 0.0, 1.60378),
}

# Unity world positions of the four instances, from tools/extract_unity_transforms.py.
# Kept in UNITY space here: the cluster origin check conjugates them, so that this
# file keeps comparing against Unity's numbers rather than against the extractor's
# output, which would make the test circular.
const UNITY_INSTANCES := [
	{"node": "tablePcs_01", "pos": Vector3(-20.77, 3.84, -66.12), "solid": false},
	{"node": "tablePcs_02", "pos": Vector3(12.60201, 2.97, 28.90268), "solid": false},
	{"node": "tablePcs_03", "pos": Vector3(14.87, 1.99, -3.38), "solid": false},
	{"node": "tablePcs_04", "pos": Vector3(-2.0, 0.0, 4.933), "solid": true},
]

const LIBRO_YAW_DEG := -12.521363
const LIBRO_OFFSET := Vector3(0.0, 0.064442, 0.0)
const TOL := 0.0005

var failures: int = 0
var checks: int = 0
var props: Node3D
var frame: int = 0


func _initialize() -> void:
	_check_model_constants()
	props = (load("res://scenes/props.tscn") as PackedScene).instantiate()
	root.add_child(props)


func _process(_delta: float) -> bool:
	# One physics step so the runtime-built bodies are registered before counting.
	frame += 1
	if frame < 3:
		return false

	_check_cluster_count()
	for inst in UNITY_INSTANCES:
		_check_cluster(inst)
	_check_collision()

	print("")
	if failures == 0:
		print("PASS: %d checks, no residual above %.4f m" % [checks, TOL])
	else:
		print("FAIL: %d of %d checks failed" % [failures, checks])
	quit(1 if failures > 0 else 0)
	return true


func _fail(msg: String) -> void:
	failures += 1
	print("  FAIL  ", msg)


func _check(label: String, got: Vector3, want: Vector3) -> void:
	checks += 1
	var d := (got - want).length()
	if d > TOL:
		_fail("%s off by %.6f m: got %.5v want %.5v" % [label, d, got, want])


func _check_model_constants() -> void:
	# The book's placement is the only one that leans on the model's internals, so
	# pin them. A reimport that adds, removes or re-angles `libro` invalidates the
	# generator's correction.
	print("book.fbx internal constants")
	var book := (load("res://models/props/book.fbx") as PackedScene).instantiate()
	var libro := book.get_node_or_null("libro") as Node3D
	if libro == null:
		_fail("book.fbx no longer has a `libro` node; the generator's A^-1 correction is stale")
		return

	checks += 1
	var yaw := rad_to_deg(libro.transform.basis.get_euler().y)
	if abs(yaw - LIBRO_YAW_DEG) > 0.001:
		_fail("libro yaw is %.6f deg, generator assumes %.6f" % [yaw, LIBRO_YAW_DEG])
	else:
		print("  ok    libro yaw %.6f deg" % yaw)

	# d = c_godot - M c_unity, which the generator takes as a pure Y offset.
	for mesh_name in UNITY_CHILDREN["book"]["meshes"]:
		var node := libro.get_node_or_null(NodePath(mesh_name)) as Node3D
		if node == null:
			_fail("book.fbx has no %s under libro" % mesh_name)
			continue
		var c_u: Vector3 = UNITY_CHILDREN["book"]["meshes"][mesh_name]
		var d: Vector3 = node.transform.origin - _mirror(c_u)
		_check("libro/%s offset d" % mesh_name, d, LIBRO_OFFSET)
	print("  ok    d = %v on both children" % LIBRO_OFFSET)


func _mirror(v: Vector3) -> Vector3:
	return Vector3(-v.x, v.y, v.z)


func _unity_rotate(quat: Array, v: Vector3) -> Vector3:
	# Quaternion algebra is the same in both engines; only the interpretation of
	# the axes differs, and that is what the mirror accounts for.
	return Quaternion(quat[0], quat[1], quat[2], quat[3]) * v


func _check_cluster_count() -> void:
	print("")
	print("props.tscn cluster count")
	var found := 0
	for child in props.get_children():
		if String(child.name).begins_with("tablePcs_"):
			found += 1
	checks += 1
	if found != UNITY_INSTANCES.size():
		_fail("props.tscn holds %d tablePcs clusters, Unity has %d" % [found, UNITY_INSTANCES.size()])
	else:
		print("  ok    %d clusters placed" % found)


func _check_cluster(inst: Dictionary) -> void:
	print("")
	print(inst["node"], "  Unity world ", inst["pos"])
	var cluster := props.get_node_or_null(NodePath(inst["node"])) as Node3D
	if cluster == null:
		_fail("%s is missing from props.tscn" % inst["node"])
		return

	# The cluster root goes down at Unity's world position conjugated by M, which is
	# the convention every placement in this level follows. See tools/unity_space.py.
	_check("%s origin" % inst["node"], cluster.global_transform.origin, _mirror(inst["pos"]))

	# The cluster's own basis is Unity's, so compare inside cluster-local space:
	# what the mesh should be at is the mirror of its Unity prefab-local position.
	var to_local := cluster.global_transform.affine_inverse()

	for mesh_name in UNITY_TABLE:
		var node := _find(cluster, mesh_name)
		if node == null:
			_fail("%s: no %s" % [inst["node"], mesh_name])
			continue
		_check("%s/%s" % [inst["node"], mesh_name],
			to_local * node.global_transform.origin, _mirror(UNITY_TABLE[mesh_name]))

	for child_name in UNITY_CHILDREN:
		var spec: Dictionary = UNITY_CHILDREN[child_name]
		for mesh_name in spec["meshes"]:
			var node := _find(cluster.get_node_or_null(NodePath(child_name)), mesh_name)
			if node == null:
				_fail("%s: no %s/%s" % [inst["node"], child_name, mesh_name])
				continue
			# Unity world (prefab space), composed from raw prefab numbers.
			var unity_local: Vector3 = spec["pos"] + _unity_rotate(spec["quat"], spec["meshes"][mesh_name])
			_check("%s/%s/%s" % [inst["node"], child_name, mesh_name],
				to_local * node.global_transform.origin, _mirror(unity_local))
	print("  checked %d meshes" % (UNITY_TABLE.size() + 6))


func _check_collision() -> void:
	print("")
	print("collision, per instance")
	for inst in UNITY_INSTANCES:
		var cluster := props.get_node_or_null(NodePath(inst["node"])) as Node3D
		if cluster == null:
			continue
		var bodies := 0
		var concave := 0
		for body in _bodies(cluster):
			bodies += 1
			for shape_owner in body.get_children():
				if shape_owner is CollisionShape3D and (shape_owner as CollisionShape3D).shape is ConcavePolygonShape3D:
					concave += 1
		checks += 1
		# 11 mesh-bearing nodes: 5 table planes, 2 per pc, 2 per pc2, 2 book.
		var want := 11 if inst["solid"] else 0
		if bodies != want:
			_fail("%s has %d static bodies, expected %d" % [inst["node"], bodies, want])
		elif bodies != concave:
			_fail("%s: %d of %d shapes are not ConcavePolygonShape3D; Unity's were m_Convex 0" % [inst["node"], bodies - concave, bodies])
		else:
			print("  ok    %s  bodies=%d (all trimesh)" % [inst["node"], bodies])


func _find(node: Node, wanted: String) -> Node3D:
	if node == null:
		return null
	if node.name == wanted and node is Node3D:
		return node
	for child in node.get_children():
		var hit := _find(child, wanted)
		if hit != null:
			return hit
	return null


func _bodies(node: Node) -> Array[StaticBody3D]:
	var out: Array[StaticBody3D] = []
	if node is StaticBody3D:
		out.append(node)
	for child in node.get_children():
		out.append_array(_bodies(child))
	return out
