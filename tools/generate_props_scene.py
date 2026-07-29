#!/usr/bin/env python3
"""Generates scenes/props.tscn from the transforms extracted out of nivelEscena.

Run tools/extract_unity_transforms.py first to produce props.json, then:

    python3 tools/generate_props_scene.py <props.json> [out.tscn]

Mirrored props are rewritten rather than reproduced literally. Several props -
most of the doors - carry a negative X scale in Unity, which is how the artists
flipped which side a door opens on. A negative determinant flips triangle
winding, so Godot renders those meshes inside out. Replacing the mirror with a
180 degree turn about Y keeps the determinant positive and looks the same: the
two differ only by a flip along the prop's thin axis, which is imperceptible on
a door and on the other props that use it.
"""

import json
import os
import sys
from collections import Counter

STATIC = {
    "silla.fbx", "puerta.fbx", "table.fbx", "pc.fbx", "pc2.fbx",
    "cable.fbx", "interruptor.fbx", "piezaParede.fbx",
}


def quat_basis(q):
    """Unity quaternion -> three basis column vectors.

    Quaternions transfer directly. The extra 180 degree turn the sun needed is
    specific to lights, whose emission-direction convention differs between the
    engines, and is not a general rotation correction.
    """
    x, y, z, w = q
    n = (x * x + y * y + z * z + w * w) ** 0.5 or 1.0
    x, y, z, w = x / n, y / n, z / n, w / n
    return (
        [1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w)],
        [2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w)],
        [2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y)],
    )


def determinant(bx, by, bz):
    return (
        bx[0] * (by[1] * bz[2] - by[2] * bz[1])
        - bx[1] * (by[0] * bz[2] - by[2] * bz[0])
        + bx[2] * (by[0] * bz[1] - by[1] * bz[0])
    )


def build_basis(rot, scale):
    """Returns (columns, mirrored) with a guaranteed positive determinant."""
    bx, by, bz = quat_basis(rot)
    mirrored = (scale[0] * scale[1] * scale[2]) < 0.0

    if mirrored:
        # Turn 180 degrees about the prop's own Y by negating the X and Z
        # columns, then take the scale magnitudes. Negating two columns leaves
        # the determinant positive.
        bx = [-c for c in bx]
        bz = [-c for c in bz]
        scale = [abs(s) for s in scale]

    cols = (
        [c * scale[0] for c in bx],
        [c * scale[1] for c in by],
        [c * scale[2] for c in bz],
    )
    return cols, mirrored


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: generate_props_scene.py <props.json> [out.tscn]")
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else "scenes/props.tscn"

    items = [p for p in json.load(open(src)) if p["prefab"] in STATIC]
    used = sorted({p["prefab"] for p in items})
    ids = {f: "%d_%s" % (i + 1, f[:-4]) for i, f in enumerate(used)}

    lines = ["[gd_scene load_steps=%d format=3]" % (len(used) + 1), ""]
    for f in used:
        lines.append(
            '[ext_resource type="PackedScene" path="res://models/props/%s" id="%s"]'
            % (f, ids[f])
        )
    lines += ["", '[node name="Props" type="Node3D"]', ""]

    counters = Counter()
    mirrored_count = 0
    for p in items:
        f = p["prefab"]
        counters[f] += 1
        cols, mirrored = build_basis(p["rot"], p["scale"])
        if mirrored:
            mirrored_count += 1
        det = determinant(*cols)
        if det <= 0.0:
            sys.exit("refusing to emit a negative-determinant transform for %s" % f)

        vals = list(cols[0]) + list(cols[1]) + list(cols[2]) + list(p["pos"])
        lines.append(
            '[node name="%s_%02d" parent="." instance=ExtResource("%s")]'
            % (f[:-4], counters[f], ids[f])
        )
        lines.append("transform = Transform3D(%s)" % ", ".join("%.6f" % v for v in vals))
        lines.append("")

    open(out, "w").write("\n".join(lines))
    print("%s: %d instances across %d models" % (out, len(items), len(used)))
    print("  mirrored props rewritten as a 180 deg turn: %d" % mirrored_count)
    for k, v in counters.most_common():
        print("   %-18s %d" % (k, v))


if __name__ == "__main__":
    main()
