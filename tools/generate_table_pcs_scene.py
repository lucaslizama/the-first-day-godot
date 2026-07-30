#!/usr/bin/env python3
"""Generates scenes/table_pcs.tscn, the desk cluster from tablePcs.prefab.

    python3 tools/generate_table_pcs_scene.py [out.tscn]

tablePcs is four whole models arranged on one node - a table, a pc, a pc2 and a
book - and the four scene instances of it were skipped by the static-props pass
because the generator's STATIC set only listed .fbx models, not prefabs.

Why the arithmetic below is not just "copy Unity's numbers"
----------------------------------------------------------
Unity's prefab does not nest the table as a model. The artist dragged table.fbx
in and flattened it, so the prefab holds pPlane23..27 as five direct children
with identity rotation. Their positions are Godot's imported positions with X
negated, to five decimals on all five planes:

    pPlane24   prefab (-0.66705, 0.95077, 1.71463)
               Godot  ( 0.66705, 0.95077, 1.71463)

The same holds for book.fbx's two children, and Z is identical throughout. So
the two importers read these files into local spaces that differ by exactly

    M = diag(-1, 1, 1)

which means a Unity node transform B has to be conjugated, not copied:

    R = M R_u M          (a Y rotation by theta becomes -theta)
    p = M p_u

Copying Unity's numbers straight across would mirror the desk layout: the book
would sit at +0.542 on a table top spanning [-0.888, +0.667] instead of at
-0.542, and the monitors would swap sides.

Two consequences fall out of this:

  * The table needs no transform at all. Godot's table.fbx already holds its five
    planes at the M-conjugated positions, which is what the prefab's flattened
    children are. Instancing it at identity reproduces them exactly.
  * The book needs two corrections beyond the conjugation. Godot's import puts a
    -12.521363 degree Y rotation on an intermediate `libro` node that Unity's does
    not have as a node, and Unity's `book` node origin sits 0.064442 above
    `libro`'s. So for a model whose internal chain contributes A:

        R = M R_u M A^-1
        p = M p_u - R A d      where d = c_godot - M c_unity

    d was measured off both of the book's children and agreed to 5e-6 on Y:
    (0, 0.064442, 0). For the table, pc and pc2, A is identity and d is zero, so
    those reduce to the plain conjugation.

Collision is not baked in here. It is per-instance in Unity - only one of the
four clusters is solid - so the root carries PropCollision.cs and the scene that
places the instances turns it on for that one. See PropCollision.cs.
"""

import math
import sys

# Unity local transforms of the prefab's children, read out of
# Assets/Prefabs/Level Construction/tablePcs.prefab. Rotations are Unity
# quaternions in xyzw order; all three are pure Y turns.
CHILDREN = [
    # (node name, model, unity position, unity quaternion)
    ("pc2", "pc2.fbx", (-0.19088, 1.06, 0.50227), (0.0, 0.657579, 0.0, 0.753385)),
    ("pc", "pc.fbx", (0.15591, 1.081, -0.88625), (0.0, 0.719837, 0.0, 0.694143)),
    ("book", "book.fbx", (0.54217, 1.146, 0.33682), (0.0, 0.891047, 0.0, 0.453911)),
]

# The table is the flattened one: identity transform, see the module docstring.
TABLE = ("table", "table.fbx")

# Per-model correction for the model's own internal chain, as A^-1's Y angle in
# degrees and d in metres. Measured off the Godot imports, not assumed:
# book.fbx carries a `libro` node Unity has no equivalent for. Verified by
# tools/verify_table_pcs.gd, which fails if an import changes these.
INTERNAL = {
    "book.fbx": {"a_inv_deg": 12.521363, "d": (0.0, 0.064442, 0.0)},
}


def unity_yaw(q):
    """Y angle in radians of a pure-Y Unity quaternion (x, y, z, w)."""
    _, y, _, w = q
    return 2.0 * math.atan2(y, w)


def rot_y_columns(theta):
    """Basis columns of a Y rotation by theta, in Godot's right-handed space."""
    c, s = math.cos(theta), math.sin(theta)
    return ([c, 0.0, -s], [0.0, 1.0, 0.0], [s, 0.0, c])


def place(model, pos_u, quat_u):
    """Conjugates a Unity child transform into Godot's model space."""
    internal = INTERNAL.get(model, {"a_inv_deg": 0.0, "d": (0.0, 0.0, 0.0)})

    # R = M R_u M A^-1. Conjugating by M negates a Y angle; A^-1 adds its own.
    theta = -unity_yaw(quat_u) + math.radians(internal["a_inv_deg"])
    cols = rot_y_columns(theta)

    # p = M p_u - R A d. R A is the conjugated rotation without A^-1, and d is a
    # pure Y offset, which any Y rotation leaves alone - so this is a plain
    # subtraction on Y. Written out longhand anyway so a non-Y d would not pass
    # silently.
    ra = rot_y_columns(-unity_yaw(quat_u))
    d = internal["d"]
    rad = [sum(ra[k][i] * d[k] for k in range(3)) for i in range(3)]
    pos = (-pos_u[0] - rad[0], pos_u[1] - rad[1], pos_u[2] - rad[2])
    return cols, pos


def transform3d(cols, pos):
    """Godot's Transform3D takes 12 floats ROW-major, so columns transpose.

    The same trap generate_props_scene.py documents: emitting basis columns in
    column order transposes the matrix, and a rotation's transpose is its
    inverse, so every angled prop comes out turned the wrong way.
    """
    bx, by, bz = cols
    vals = [
        bx[0], by[0], bz[0],
        bx[1], by[1], bz[1],
        bx[2], by[2], bz[2],
    ] + list(pos)
    return "Transform3D(%s)" % ", ".join("%.6f" % v for v in vals)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "scenes/table_pcs.tscn"

    models = [TABLE[1]] + [c[1] for c in CHILDREN]
    ids = {m: "%d_%s" % (i + 1, m[:-4]) for i, m in enumerate(models)}

    lines = ["[gd_scene load_steps=%d format=3]" % (len(models) + 2), ""]
    for m in models:
        lines.append(
            '[ext_resource type="PackedScene" path="res://models/props/%s" id="%s"]'
            % (m, ids[m])
        )
    lines.append(
        '[ext_resource type="Script" path="res://scripts/Gameplay/PropCollision.cs" id="%d_collision"]'
        % (len(models) + 1)
    )
    lines += [
        "",
        '[node name="TablePcs" type="Node3D"]',
        'script = ExtResource("%d_collision")' % (len(models) + 1),
        "",
        '[node name="%s" parent="." instance=ExtResource("%s")]' % (TABLE[0], ids[TABLE[1]]),
        "",
    ]

    for name, model, pos_u, quat_u in CHILDREN:
        cols, pos = place(model, pos_u, quat_u)
        lines.append(
            '[node name="%s" parent="." instance=ExtResource("%s")]' % (name, ids[model])
        )
        lines.append("transform = %s" % transform3d(cols, pos))
        lines.append("")

    open(out, "w").write("\n".join(lines))

    print("%s: 1 table + %d objects" % (out, len(CHILDREN)))
    for name, model, pos_u, quat_u in CHILDREN:
        _, pos = place(model, pos_u, quat_u)
        print(
            "   %-6s unity (%.5f, %.5f, %.5f) yaw %+8.3f  ->  godot (%.5f, %.5f, %.5f) yaw %+8.3f"
            % (
                name, pos_u[0], pos_u[1], pos_u[2], math.degrees(unity_yaw(quat_u)),
                pos[0], pos[1], pos[2],
                math.degrees(-unity_yaw(quat_u) + math.radians(INTERNAL.get(model, {}).get("a_inv_deg", 0.0))),
            )
        )


if __name__ == "__main__":
    main()
