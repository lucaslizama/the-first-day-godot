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
    "tablePcs.prefab",
    # The ending pair, at the far end around z = -183. Both are plain solid meshes
    # in Unity - no MonoBehaviour, no trigger - so they are static props here and the
    # ending's behaviour stays with TimerZone and Credits.
    "meta.fbx", "cake.fbx",
    # The entrance door: its own scene, because it animates and carries a trigger.
    "puertaInicio.prefab",
}

# Where each entry's PackedScene lives. Models resolve to models/props by name;
# tablePcs is a cluster of four models rather than one, so it has its own scene.
# It was missed by the first static-props pass precisely because this set used to
# hold only .fbx names.
RESOURCE = {
    "tablePcs.prefab": "res://scenes/table_pcs.tscn",
    "puertaInicio.prefab": "res://scenes/puerta_inicio.tscn",
}

# The tablePcs instances that are solid, keyed by world position the way
# FLIP_DOORS is, so regenerating props.json cannot move the flag onto a different
# desk. Collision is per-instance in Unity: of the four clusters only this one -
# the desk beside the player's spawn at (0, 0, 4.02) - carries MeshColliders, and
# the other three are walk-through. Adding physics to the models at import time
# would wrongly solidify all four. See scripts/Gameplay/PropCollision.cs.
#
# In GODOT space, so X is negated relative to Unity's -2.0: props.json is
# conjugated by diag(-1, 1, 1) on the way out of the extractor. The count check
# below caught this when the conjugation landed, which is what it is for.
SOLID_CLUSTERS = {(2.0, 0.0, 4.93)}

# Per-door 180 degree corrections, keyed by world position. Currently empty.
#
# An earlier attempt listed ten doors here, chosen because a hemisphere ray test
# said they showed their unfinished back. Applying it made almost every door in
# the level render semi-transparent, so it was reverted on request. The cause of
# that transparency is not yet understood and the ray test is not trustworthy
# until it is - do not repopulate this from tools/door_facing.gd without checking
# the result in the editor first.
#
# The mechanism is kept because the generator is the right place for such a fix
# if one turns out to be needed. Keyed by position rather than node name so
# regenerating props.json cannot move corrections onto different doors.
FLIP_DOORS = set()


def wants_flip(pos):
    return (round(pos[0], 2), round(pos[1], 2), round(pos[2], 2)) in FLIP_DOORS


def stem(name):
    """Node-name stem for an entry: drops .fbx or .prefab."""
    return name.rsplit(".", 1)[0]


def is_solid(pos):
    return (round(pos[0], 2), round(pos[1], 2), round(pos[2], 2)) in SOLID_CLUSTERS


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
    ids = {f: "%d_%s" % (i + 1, stem(f)) for i, f in enumerate(used)}

    lines = ["[gd_scene load_steps=%d format=3]" % (len(used) + 1), ""]
    for f in used:
        lines.append(
            '[ext_resource type="PackedScene" path="%s" id="%s"]'
            % (RESOURCE.get(f, "res://models/props/%s" % f), ids[f])
        )
    lines += ["", '[node name="Props" type="Node3D"]', ""]

    counters = Counter()
    mirrored_count = 0
    flipped_count = 0
    solid_count = 0
    for p in items:
        f = p["prefab"]
        counters[f] += 1
        flip = f == "puerta.fbx" and wants_flip(p["pos"])
        if flip:
            flipped_count += 1
        cols, mirrored = build_basis(p["rot"], p["scale"], flip)
        if mirrored:
            mirrored_count += 1

        # Godot's 12-float Transform3D constructor is ROW-major, so the basis
        # columns have to be written out transposed. Emitting them in column
        # order instead silently transposes the matrix, and the transpose of a
        # rotation is its inverse - every angled prop ended up rotated the wrong
        # way, while ones near 0 or 180 degrees looked fine. Verified against the
        # live editor: for Unity's -93.47 deg yaw on puerta_21, the column order
        # produced +93.47.
        bx, by, bz = cols
        vals = [
            bx[0], by[0], bz[0],
            bx[1], by[1], bz[1],
            bx[2], by[2], bz[2],
        ] + list(p["pos"])
        lines.append(
            '[node name="%s_%02d" parent="." instance=ExtResource("%s")]'
            % (stem(f), counters[f], ids[f])
        )
        lines.append("transform = Transform3D(%s)" % ", ".join("%.6f" % v for v in vals))
        if f == "tablePcs.prefab" and is_solid(p["pos"]):
            lines.append("GenerateCollision = true")
            solid_count += 1
        lines.append("")

    open(out, "w").write("\n".join(lines))
    print("%s: %d instances across %d models" % (out, len(items), len(used)))
    print("  mirrored props kept as Unity had them (negative determinant): %d" % mirrored_count)
    print("  doors turned 180 deg to stop showing their back: %d of %d" % (flipped_count, len(FLIP_DOORS)))
    print("  tablePcs clusters made solid: %d of %d" % (solid_count, len(SOLID_CLUSTERS)))
    if flipped_count != len(FLIP_DOORS):
        sys.exit("FLIP_DOORS has %d entries but %d matched; positions have drifted" % (len(FLIP_DOORS), flipped_count))
    if solid_count != len(SOLID_CLUSTERS):
        sys.exit("SOLID_CLUSTERS has %d entries but %d matched; positions have drifted" % (len(SOLID_CLUSTERS), solid_count))
    for k, v in counters.most_common():
        print("   %-18s %d" % (k, v))


if __name__ == "__main__":
    main()
