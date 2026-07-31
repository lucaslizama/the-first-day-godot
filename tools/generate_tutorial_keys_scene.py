#!/usr/bin/env python3
"""Generates scenes/tutorial_keys.tscn from tools/extract_tutorial_keys.py's JSON.

    python3 tools/generate_tutorial_keys_scene.py [models/level/tutorial_keys.json] [out.tscn]

Five quads: the tutorial board and the four key prompts on it, at the level's start.

THE ONE THING HERE THAT IS NOT MECHANICAL - and it is the reason this needed thought rather than
just transcription - is that these meshes are NATIVE Godot QuadMeshes, not imported models.

The port's placement rule conjugates every Unity transform by M = diag(-1, 1, 1). That works for
imported models because Godot's FBX importer ALREADY mirrored their local geometry by the same M, so
a local vertex v lands at M*(Unity's world position) and the whole scene is consistently mirrored -
which renders the way Unity's did, since the handedness differs too. A QuadMesh has had no such
importer pass. Placing one with a conjugated transform alone puts its local +X where Unity's -X was,
so anything written on it reads BACKWARDS: "WASD" would show as "DSAW".

So the mesh transform is the conjugated basis times M again - equivalently, its first column negated:

    T_godot = (M W M) * M = M W

which sends the quad's local vertex v to M * (Unity world position of v), exactly as an imported
model's would. Verified by rendering the spawn and reading the signs, not by reasoning alone; a
mirrored quad is geometrically identical to an unmirrored one, so nothing but the texture shows it.

COLLISION IS BAKED INTO VERTICES rather than carried by a node transform. All five have
m_Convex: 0, m_IsTrigger: 0 in Unity - solid concave - and `WASD (1)` composes to a SHEARED basis,
because its own -90.3 degree Y rotation sits under `Tutorial`'s non-uniform (5.88, 2.99, 1) scale.
A sheared transform on a CollisionShape3D is not something to rely on, so every quad's four corners
are transformed here and emitted as one ConcavePolygonShape3D in the scene's own space, with the
body and shape left at identity. The shear then lives in triangle data, which holds it exactly.
"""

import json
import os
import sys

## Unity's built-in Quad and Godot's QuadMesh are both 1x1 in the XY plane, centred, facing +Z.
CORNERS = [
    (-0.5, -0.5, 0.0),
    (0.5, -0.5, 0.0),
    (0.5, 0.5, 0.0),
    (-0.5, 0.5, 0.0),
]

## Which material each prop uses. `Tutorial` carries Unity's own default material, so it gets a plain
## white one of the same shape - Standard, metallic 0, glossiness 0.5.
MATERIAL_FILES = {
    "wasd": "res://materials/props/wasd.tres",
    "space_key_l": "res://materials/props/space_key_l.tres",
    "shift_key": "res://materials/props/shift_key.tres",
    "controller": "res://materials/props/controller.tres",
    "default": "res://materials/props/tutorial_board.tres",
}


def mirror_local(rows):
    """Right-multiply the conjugated basis by M = diag(-1, 1, 1), i.e. negate its X COLUMN.

    The basis arrives as rows (Godot's Transform3D order), so the X column is element 0 of each row.
    Getting rows and columns the wrong way round here is not a cosmetic error: for a rotation times a
    non-uniform scale the transpose moves the scales onto other axes, which measured as the tutorial
    board being 1 m wide instead of 5.88 m.

    The Z column is negated too, because a Unity built-in Quad's front face is its local -Z while a
    Godot QuadMesh's is +Z. For a flat quad the Z column moves no vertex - every vertex has z = 0 - so
    this only flips the winding and the normal, leaving the texture's orientation untouched. Confirmed
    numerically against M * (Unity's world normal) for all five, and by rendering.
    """
    return [[-row[0], row[1], -row[2]] for row in rows]


def transform3d(rows, origin):
    """Godot's Transform3D literal, which is ROW-major: xx, xy, xz, yx, ... then the origin."""
    values = [c for row in rows for c in row] + list(origin)
    return "Transform3D(%s)" % ", ".join("%.6f" % v for v in values)


def place(rows, origin, v):
    """Basis (as rows) applied to a local vertex, plus the origin."""
    return tuple(sum(rows[i][j] * v[j] for j in range(3)) + origin[i] for i in range(3))


def main():
    source = sys.argv[1] if len(sys.argv) > 1 else "models/level/tutorial_keys.json"
    out = sys.argv[2] if len(sys.argv) > 2 else "scenes/tutorial_keys.tscn"
    props = json.load(open(source))["props"]

    materials = []
    for p in props:
        path = MATERIAL_FILES.get(p["material"])
        if path is None:
            sys.exit("no material mapped for %s (Unity material '%s')" % (p["name"], p["material"]))
        if path not in materials:
            materials.append(path)

    triangles = []
    for p in props:
        if not p["collider"]:
            continue
        rows = mirror_local(p["basis"])
        world = [place(rows, p["origin"], v) for v in CORNERS]
        # Two triangles per quad, corners in order, matching Unity's solid MeshCollider.
        triangles += [world[0], world[1], world[2], world[0], world[2], world[3]]

    steps = len(materials) + 2  # the materials, plus the QuadMesh and the collision shape
    lines = ["[gd_scene load_steps=%d format=3]" % steps, ""]
    ids = {}
    for i, path in enumerate(materials, start=1):
        ids[path] = "%d_mat" % i
        lines.append('[ext_resource type="Material" path="%s" id="%s"]' % (path, ids[path]))
    lines.append("")
    lines.append('[sub_resource type="QuadMesh" id="QuadMesh_key"]')
    lines.append("")
    lines.append('[sub_resource type="ConcavePolygonShape3D" id="ConcavePolygonShape3D_keys"]')
    lines.append("data = PackedVector3Array(%s)" % ", ".join(
        "%.6f" % c for v in triangles for c in v))
    lines.append("")
    lines.append('[node name="TutorialKeys" type="Node3D"]')

    for p in props:
        rows = mirror_local(p["basis"])
        node = p["name"].replace(" ", "_").replace("(", "").replace(")", "")
        lines.append("")
        lines.append('[node name="%s" type="MeshInstance3D" parent="."]' % node)
        lines.append("transform = %s" % transform3d(rows, p["origin"]))
        lines.append('mesh = SubResource("QuadMesh_key")')
        lines.append('surface_material_override/0 = ExtResource("%s")' % ids[
            MATERIAL_FILES[p["material"]]])

    if triangles:
        lines.append("")
        lines.append('[node name="Collision" type="StaticBody3D" parent="."]')
        lines.append("")
        lines.append('[node name="Shape" type="CollisionShape3D" parent="Collision"]')
        lines.append('shape = SubResource("ConcavePolygonShape3D_keys")')

    with open(out, "w") as f:
        f.write("\n".join(lines) + "\n")

    print("%s: %d quads, %d materials, %d collision triangles" % (
        out, len(props), len(materials), len(triangles) // 3))
    for p in props:
        print("   %-9s %-14s origin=(%7.3f, %6.3f, %8.3f)" % (
            p["name"], p["material"], *p["origin"]))


if __name__ == "__main__":
    main()
