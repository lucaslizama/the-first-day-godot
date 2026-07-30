#!/usr/bin/env python3
"""Generates scenes/hammers.tscn from the transforms extracted out of nivelEscena.

Run tools/extract_unity_transforms.py first to produce props.json, then:

    python3 tools/generate_hammers_scene.py <props.json> [out.tscn]

Separate from the platform generator for the same reason that one is separate from
the props generator: these are different kinds of thing that happen to share
transform maths, which is imported from generate_props_scene rather than copied.
Read the notes there before touching quaternions or the row-major Transform3D
layout - a transposed basis inverts every rotation, and the hammers are rotated.
"""

import json
import sys

from generate_props_scene import build_basis

PREFAB = "martillo_prefab.prefab"


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: generate_hammers_scene.py <props.json> [out.tscn]")
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else "scenes/hammers.tscn"

    items = [p for p in json.load(open(src)) if p["prefab"] == PREFAB]
    if not items:
        sys.exit("no %s instances in %s" % (PREFAB, src))

    lines = [
        "[gd_scene load_steps=2 format=3]",
        "",
        '[ext_resource type="PackedScene" path="res://scenes/hammer.tscn" id="1_hammer"]',
        "",
        '[node name="Hammers" type="Node3D"]',
        "",
    ]

    for i, p in enumerate(items):
        if tuple(round(s, 4) for s in p["scale"]) != (1.0, 1.0, 1.0):
            sys.exit(
                "%s has scale %s; a scaled hammer would also scale its 7 m reach and "
                "its collider boxes." % (p["name"], p["scale"])
            )
        cols, mirrored = build_basis(p["rot"], p["scale"])
        if mirrored:
            sys.exit("%s is mirrored; no hammer in the level is." % p["name"])

        bx, by, bz = cols
        vals = [
            bx[0], by[0], bz[0],
            bx[1], by[1], bz[1],
            bx[2], by[2], bz[2],
        ] + list(p["pos"])
        lines.append(
            '[node name="Hammer_%02d" parent="." instance=ExtResource("1_hammer")]' % (i + 1)
        )
        lines.append("transform = Transform3D(%s)" % ", ".join("%.6f" % v for v in vals))
        lines.append("")

    open(out, "w").write("\n".join(lines))
    print("%s: %d hammers" % (out, len(items)))
    for p in items:
        print("   %-22s pos=%s" % (p["name"] or "(unnamed)", p["pos"]))


if __name__ == "__main__":
    main()
