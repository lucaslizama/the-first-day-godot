#!/usr/bin/env python3
"""Generates scenes/props.tscn from the transforms extracted out of nivelEscena.

Run tools/extract_unity_transforms.py first to produce props.json, then:

    python3 tools/generate_props_scene.py <props.json> [out.tscn]

Transforms are reproduced exactly as Unity had them, negative scales included.

Twelve doors carry a negative X scale, which is how the artists flipped which
side a door opens on. Do NOT substitute a 180 degree turn about Y for that
mirror: a mirror on X leaves the door's facing axis alone, while a Y turn
negates it, so the substitution silently turns those doors to face backwards.
That was tried and reverted. A mirror is not a rotation, and no combination of
scale signs preserves both up and facing while making the determinant positive
- diag(-1,-1,1) turns the door upside down and diag(-1,1,-1) is the Y turn that
flips the facing.

Godot renders negative-determinant transforms correctly, verified by rendering a
mirrored door beside an unmirrored one, so nothing needs working around here.
"""

import json
import os
import sys
from collections import Counter

STATIC = {
    "silla.fbx", "puerta.fbx", "table.fbx", "pc.fbx", "pc2.fbx",
    "cable.fbx", "interruptor.fbx", "piezaParede.fbx",
}

# Doors that face the wrong way once placed, keyed by world position.
#
# puerta.fbx has its panelled, knobbed face on local +Z; local -Z is a flat black
# back. Ten of the twenty-one doors end up presenting that back to the building's
# interior, so the player sees a black rectangle instead of a door.
#
# This is not the mirror question: the list cuts across both groups, eight of
# these have a negative scale and two do not, and eleven mirrored-or-not doors
# are already correct. It is per-instance, so it is corrected per instance.
#
# Turning a door 180 degrees about Y is safe in a way that it is not for a
# mirrored prop in general: the door stays in its doorway and simply presents its
# other face.
#
# Re-derive with tools/door_facing.gd, which casts a fan over each hemisphere and
# compares how enclosed the two sides are. Keyed by position rather than by node
# name so regenerating props.json cannot silently move the corrections onto
# different doors.
FLIP_DOORS = {
    (45.61, 11.41, -59.68),
    (8.12, 2.87, 35.84),
    (-25.34, 0.82, -25.82),
    (-26.27, 3.74, -66.73),
    (43.02, 11.41, -104.27),
    (-56.49, 19.69, 22.16),
    (34.07, 20.89, 50.53),
    (-55.73, 14.72, -57.40),
    (-24.17, 2.72, 34.83),
    (22.72, 1.90, -43.84),
}


def wants_flip(pos):
    return (round(pos[0], 2), round(pos[1], 2), round(pos[2], 2)) in FLIP_DOORS


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


def build_basis(rot, scale, flip=False):
    """Returns (columns, mirrored) reproducing Unity's transform.

    mirrored is reported for the summary only; the scale is emitted as-is so each
    prop keeps the handedness it had in Unity. flip adds a 180 degree turn about
    Y for the doors listed in FLIP_DOORS, by negating the X and Z columns, which
    leaves the determinant's sign alone.
    """
    bx, by, bz = quat_basis(rot)
    mirrored = (scale[0] * scale[1] * scale[2]) < 0.0
    if flip:
        bx = [-c for c in bx]
        bz = [-c for c in bz]
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
    flipped_count = 0
    for p in items:
        f = p["prefab"]
        counters[f] += 1
        flip = f == "puerta.fbx" and wants_flip(p["pos"])
        if flip:
            flipped_count += 1
        cols, mirrored = build_basis(p["rot"], p["scale"], flip)
        if mirrored:
            mirrored_count += 1

        vals = list(cols[0]) + list(cols[1]) + list(cols[2]) + list(p["pos"])
        lines.append(
            '[node name="%s_%02d" parent="." instance=ExtResource("%s")]'
            % (f[:-4], counters[f], ids[f])
        )
        lines.append("transform = Transform3D(%s)" % ", ".join("%.6f" % v for v in vals))
        lines.append("")

    open(out, "w").write("\n".join(lines))
    print("%s: %d instances across %d models" % (out, len(items), len(used)))
    print("  mirrored props kept as Unity had them (negative determinant): %d" % mirrored_count)
    print("  doors turned 180 deg to stop showing their back: %d of %d" % (flipped_count, len(FLIP_DOORS)))
    if flipped_count != len(FLIP_DOORS):
        sys.exit("FLIP_DOORS has %d entries but %d matched; positions have drifted" % (len(FLIP_DOORS), flipped_count))
    for k, v in counters.most_common():
        print("   %-18s %d" % (k, v))


if __name__ == "__main__":
    main()
