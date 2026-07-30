#!/usr/bin/env python3
"""Generates scenes/platforms.tscn from the transforms extracted out of nivelEscena.

Run tools/extract_unity_transforms.py first to produce props.json, then:

    python3 tools/generate_platforms_scene.py <props.json> [out.tscn]

The static props and the platforms are generated separately because they are not
the same kind of thing: a prop is an FBX instanced straight in, while a platform
is a hand-built scene - collider, trigger, animation - that the FBX only supplies
the mesh for. The transform maths is identical, so it is imported from
generate_props_scene rather than copied; read the comments there before touching
quaternions or the row-major Transform3D layout.

Unlike the props, no platform in the level is mirrored or non-uniformly scaled -
all 26 have scale (1, 1, 1) - so the negative-determinant handling that the doors
needed never comes up here. The generator still asserts it rather than assuming.
"""

import json
import sys
from collections import Counter

from generate_props_scene import build_basis

# Unity prefab -> the scene that replaces it. The plataforma/plataformaCae FBXs are
# referenced by those scenes, not here.
PLATFORMS = {
    "plataforma_prefab.prefab": ("moving_platform.tscn", "MovingPlatform"),
    "plataformaCae.prefab": ("falling_platform.tscn", "FallingPlatform"),
}


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: generate_platforms_scene.py <props.json> [out.tscn]")
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else "scenes/platforms.tscn"

    items = [p for p in json.load(open(src)) if p["prefab"] in PLATFORMS]
    used = sorted({p["prefab"] for p in items})
    ids = {f: "%d_%s" % (i + 1, PLATFORMS[f][1].lower()) for i, f in enumerate(used)}

    lines = ["[gd_scene load_steps=%d format=3]" % (len(used) + 1), ""]
    for f in used:
        lines.append(
            '[ext_resource type="PackedScene" path="res://scenes/%s" id="%s"]'
            % (PLATFORMS[f][0], ids[f])
        )
    lines += ["", '[node name="Platforms" type="Node3D"]', ""]

    counters = Counter()
    for p in items:
        f = p["prefab"]
        counters[f] += 1

        if tuple(round(s, 4) for s in p["scale"]) != (1.0, 1.0, 1.0):
            sys.exit(
                "%s %s has scale %s; the platform scenes assume unit scale, since a "
                "scaled platform would also scale its 10 m fall and its trigger box."
                % (f, p["name"], p["scale"])
            )

        cols, mirrored = build_basis(p["rot"], p["scale"])
        if mirrored:
            sys.exit("%s %s is mirrored; no platform in the level is." % (f, p["name"]))

        # Row-major, as Godot's 12-float Transform3D constructor expects. Emitting
        # the columns in order transposes the basis, which inverts every rotation -
        # see the note in generate_props_scene.
        bx, by, bz = cols
        vals = [
            bx[0], by[0], bz[0],
            bx[1], by[1], bz[1],
            bx[2], by[2], bz[2],
        ] + list(p["pos"])
        lines.append(
            '[node name="%s_%02d" parent="." instance=ExtResource("%s")]'
            % (PLATFORMS[f][1], counters[f], ids[f])
        )
        lines.append("transform = Transform3D(%s)" % ", ".join("%.6f" % v for v in vals))
        lines.append("")

    open(out, "w").write("\n".join(lines))
    print("%s: %d platforms" % (out, len(items)))
    for k, v in counters.most_common():
        print("   %-26s %d -> %s" % (k, v, PLATFORMS[k][0]))


if __name__ == "__main__":
    main()
