#!/usr/bin/env python3
"""Extracts the five tutorial key signs from nivelEscena.unity to JSON.

    python3 tools/extract_tutorial_keys.py [--unity DIR] [--out models/level/tutorial_keys.json]

The last piece of unported level content: WASD, WASD (1), Spacebar, Shift and Tutorial - the
key-prompt signs at the level's start.

WHY THIS NEEDS ITS OWN EXTRACTOR rather than going through extract_unity_transforms.py: these are
not prefab instances of an FBX. They are plain GameObjects carrying Unity's BUILT-IN QUAD mesh
(fileID 10210 of the default resources), so there is no model to import and nothing for the usual
per-prefab path to key off.

TWO THINGS THE PORT DOCUMENT HAD WRONG about them, both corrected there:

  * They are QUADS, not cubes. fileID 10210, not 10202. A quad is a 1x1 plane in the XY plane; a
    cube would have made them metre-thick slabs.
  * Only four materials need porting, not five. `Tutorial` uses Unity's own default material
    (guid 0000000000000000f000000000000000), so it is an untextured white quad - the backing board
    the other four sit on.

THE COMPOSITION IS A FULL MATRIX, NOT A TRS TRIPLE, and that is the trap here. `Tutorial` is the
parent of the other four and carries a NON-UNIFORM scale (5.88, 2.99, 1) as well as a 90 degree Y
rotation. Three children have identity rotation, so for them parent_rotation * parent_scale *
child_scale stays a rotation times a diagonal. But `WASD (1)` has its own -90.3 degree Y rotation,
which puts a non-uniform scale BETWEEN two rotations - and that product is not orthogonal. It
shears. Decomposing it back into position, rotation and scale would silently discard the shear, so
each prop is emitted as a 3x3 basis plus an origin, which Godot's Transform3D holds exactly as
Unity's matrix does.

The diag(-1, 1, 1) conjugation is applied here, once, as tools/unity_space.py documents - but on the
composed matrix rather than per-key, since a basis conjugates as M B M while a position conjugates
as M p. unity_space's per-key helpers cannot express that, so the rule is applied directly and the
module is imported only to keep the mirror's definition in one place.
"""

import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import unity_space  # noqa: E402  - imported for MIRRORED_AXIS, so the rule has one home

NAMES = ["WASD", "WASD (1)", "Spacebar", "Shift", "Tutorial"]

## Unity's built-in default resources. A quad is 1x1 in XY; anything else here is a surprise.
BUILTIN_MESHES = {"10210": "Quad", "10202": "Cube", "10209": "Plane"}

## Unity's own default material, which `Tutorial` uses.
DEFAULT_MATERIAL_GUID = "0000000000000000f000000000000000"


def documents(path):
    """fileID -> (class id, body) for every document in a Unity YAML file."""
    text = open(path, errors="ignore").read()
    out = {}
    for m in re.finditer(
        r"^--- !u!(\d+) &(\d+)(?: stripped)?\n(.*?)(?=^--- !u!|\Z)", text, re.S | re.M
    ):
        out[m.group(2)] = (m.group(1), m.group(3))
    return out


def field(body, name):
    m = re.search(rf"^\s*{name}:\s*(.*)$", body, re.M)
    return m.group(1).strip() if m else None


def listing(body, name):
    """The indented block following `name:`, for Unity's YAML sequences."""
    m = re.search(rf"^\s*{name}:\s*\n((?:\s+-.*\n|\s{{4,}}\S.*\n)*)", body, re.M)
    return m.group(1) if m else ""


def vector(text, default=(0.0, 0.0, 0.0)):
    if not text:
        return default
    got = dict(re.findall(r"([xyzw]):\s*([-\d.eE+]+)", text))
    return tuple(float(got.get(k, 0.0)) for k in "xyz")


def quaternion(text):
    got = dict(re.findall(r"([xyzw]):\s*([-\d.eE+]+)", text or ""))
    return tuple(float(got.get(k, 0.0)) for k in "xyzw")


def quaternion_basis(q):
    """xyzw quaternion -> 3x3 rotation as rows."""
    x, y, z, w = q
    n = (x * x + y * y + z * z + w * w) ** 0.5
    if n == 0.0:
        return [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
    x, y, z, w = x / n, y / n, z / n, w / n
    return [
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ]


def multiply(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]


def apply(basis, v):
    return tuple(sum(basis[i][k] * v[k] for k in range(3)) for i in range(3))


def local_matrix(body):
    """(basis, origin) for one Transform document, as Unity composes T * R * S."""
    rotation = quaternion_basis(quaternion(field(body, "m_LocalRotation")))
    scale = vector(field(body, "m_LocalScale"), (1.0, 1.0, 1.0))
    basis = [[rotation[i][j] * scale[j] for j in range(3)] for i in range(3)]
    return basis, vector(field(body, "m_LocalPosition"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--unity", default="/home/lucaslizama/repos/unity/asylum-jam-game")
    ap.add_argument("--out", default="models/level/tutorial_keys.json")
    args = ap.parse_args()

    scene = os.path.join(args.unity, "Assets/Scenes/nivelEscena.unity")
    if not os.path.exists(scene):
        sys.exit("no scene at %s - point --unity at the Unity project" % scene)
    docs = documents(scene)

    transform_of = {}
    for fid, (cls, body) in docs.items():
        if cls == "4":
            owner = re.search(r"fileID: (\d+)", field(body, "m_GameObject") or "")
            if owner:
                transform_of[owner.group(1)] = fid

    names = {fid: field(body, "m_Name") for fid, (cls, body) in docs.items() if cls == "1"}
    guid_to_material = material_index(args.unity)

    props = []
    for fid, name in names.items():
        if name not in NAMES:
            continue
        cls, body = docs[fid]
        if field(body, "m_IsActive") != "1":
            sys.exit("%s is not active; the port assumed all five were" % name)

        # Compose up the parent chain. Unity's world matrix is the product of each level's T*R*S,
        # so a non-uniform parent scale above a rotated child produces shear - see the docstring.
        basis = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        origin = (0.0, 0.0, 0.0)
        cursor = transform_of[fid]
        chain = []
        while cursor:
            tbody = docs[cursor][1]
            chain.append(names.get(
                re.search(r"fileID: (\d+)", field(tbody, "m_GameObject") or "").group(1), "?"))
            local_basis, local_origin = local_matrix(tbody)
            origin = tuple(
                a + b for a, b in zip(apply(local_basis, origin), local_origin))
            basis = multiply(local_basis, basis)
            father = re.search(r"fileID: (\d+)", field(tbody, "m_Father") or "")
            cursor = father.group(1) if father and father.group(1) != "0" else None

        mesh, material, collider = components(docs, body, guid_to_material)

        props.append({
            "name": name,
            "path": " <- ".join(chain),
            "mesh": mesh,
            "material": material,
            "collider": collider,
            # Conjugated: a basis by M B M, an origin by M p. M = diag(-1, 1, 1) and M == M^-1.
            "basis": mirror_basis(basis),
            "origin": list(mirror_position(origin)),
        })

    if len(props) != len(NAMES):
        sys.exit("found %d of the %d tutorial props: %s" % (
            len(props), len(NAMES), sorted(p["name"] for p in props)))

    props.sort(key=lambda p: NAMES.index(p["name"]))
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump({"props": props}, f, indent=2)
        f.write("\n")

    print("%s: %d props" % (args.out, len(props)))
    for p in props:
        # Shear between NORMALISED COLUMNS, since a column is where a local axis ends up. The basis is
        # stored as rows, so the columns are read across them. An earlier version dotted the rows and
        # skipped the normalisation, and reported 0.4812 where the real figure is 0.0304.
        columns = [[p["basis"][r][c] for r in range(3)] for c in range(3)]
        shear = max(abs(dot(unit(columns[i]), unit(columns[j])))
                    for i, j in ((0, 1), (0, 2), (1, 2)))
        print("  %-9s %-28s origin=(%7.3f, %6.3f, %8.3f)  material=%-14s collider=%s  shear=%.4f" % (
            p["name"], p["path"], p["origin"][0], p["origin"][1], p["origin"][2],
            p["material"], "solid" if p["collider"] else "none", shear))


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def unit(v):
    length = sum(x * x for x in v) ** 0.5
    return [x / length for x in v] if length else v


def mirror_position(v):
    return (-v[0], v[1], v[2])


def mirror_basis(basis):
    """M B M with M = diag(-1, 1, 1): negates the terms that couple X to Y or Z.

    Returned as ROWS, matching Godot's Transform3D(xx, xy, xz, yx, ...) constructor, which is
    ROW-major. An earlier version returned columns "which is the order Godot takes" - it is not, and
    the transpose is not harmless: for a rotation times a non-uniform scale, (R*S)^T = S*R^T puts each
    scale factor on the wrong axis. It showed up as the Tutorial board measuring 1 m wide instead of
    5.88 while its height stayed correct, because the transpose happened to preserve the axis whose
    scale was already in the right slot.
    """
    m = (-1.0, 1.0, 1.0)
    return [[m[i] * basis[i][j] * m[j] for j in range(3)] for i in range(3)]


def material_index(unity):
    index = {}
    for root, _, files in os.walk(os.path.join(unity, "Assets")):
        for name in files:
            if not name.endswith(".mat.meta"):
                continue
            path = os.path.join(root, name)
            guid = re.search(r"^guid: (\w+)", open(path, errors="ignore").read(), re.M)
            if guid:
                index[guid.group(1)] = os.path.basename(name)[: -len(".mat.meta")]
    return index


def components(docs, body, guid_to_material):
    """(mesh name, material name, collider is solid) for one GameObject."""
    mesh = material = None
    collider = False
    for cls, cid in re.findall(r"-\s+(\d+):\s*\{fileID: (\d+)\}", listing(body, "m_Component")):
        cbody = docs.get(cid, ("?", ""))[1]
        if cls == "33":  # MeshFilter
            got = re.search(r"fileID: (\d+)", field(cbody, "m_Mesh") or "")
            mesh = BUILTIN_MESHES.get(got.group(1) if got else "", "unknown")
        elif cls == "23":  # MeshRenderer
            guids = re.findall(r"fileID: \d+, guid: (\w+)", listing(cbody, "m_Materials"))
            if guids:
                material = ("default" if guids[0] == DEFAULT_MATERIAL_GUID
                            else guid_to_material.get(guids[0], guids[0]))
        elif cls == "64":  # MeshCollider
            # Every one is m_Convex: 0, m_IsTrigger: 0 - solid concave, i.e. the signs are walls.
            collider = field(cbody, "m_IsTrigger") != "1"
    return mesh, material, collider


if __name__ == "__main__":
    main()
