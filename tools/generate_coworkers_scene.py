#!/usr/bin/env python3
"""Generates scenes/coworkers.tscn from the transforms extract_coworkers.py found.

    python3 tools/generate_coworkers_scene.py <coworkers.json> [out.tscn]

Rotation is deliberately dropped; only position and scale are emitted.

Unity's YBillboardFollow overwrote each coworker's rotation every frame with a
yaw-only quaternion, so whatever the artists authored never survived to the screen -
and the yaw it wrote does not matter either, because the sprite is a flat quad
turned to face the camera. Godot's BILLBOARD_FIXED_Y does the same job in the
shader, taking its vertical from the node's Y column. Emitting the authored
rotation would therefore change nothing about the yaw but would tilt any coworker
whose basis carried pitch or roll - a difference from Unity, not a fidelity to it.

Scale is emitted, and matters: 24 of the 74 coworkers are scaled non-uniformly,
some to eight times the prefab's size, and Godot keeps X and Y scale independently
through fixed-Y billboarding (measured, not assumed). Group children get their
scale from Unity's component-wise composition of the group's scale with their own,
which is what Unity itself renders from - so the giants are faithful, not a bug in
the extraction.
"""

import json
import sys
from collections import Counter

SCENES = {
    "mono1": ("coworker_mono1.tscn", "CoworkerMono1"),
    "mono2": ("coworker_mono2.tscn", "CoworkerMono2"),
}

# No audio here. The whisper emitters are generated separately by
# tools/generate_whispers_scene.py into scenes/whispers.tscn, clustered from the coworker
# positions this tool writes. They used to be emitted here, one per Unity coworker group, and
# that hid a bug: every emitter landed at positive x, so the 25 coworkers on the left-hand
# side of the level had no whisper nearer than 90 m. Placement and coverage are different
# problems and regenerating one should not mean regenerating the other.


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: generate_coworkers_scene.py <coworkers.json> [out.tscn]")
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else "scenes/coworkers.tscn"

    data = json.load(open(src))
    items = data["coworkers"]
    used = sorted({e["kind"] for e in items})
    ids = {k: "%d_%s" % (i + 1, k) for i, k in enumerate(used)}

    steps = len(used) + 1
    lines = ["[gd_scene load_steps=%d format=3]" % steps, ""]
    for k in used:
        lines.append(
            '[ext_resource type="PackedScene" path="res://scenes/%s" id="%s"]'
            % (SCENES[k][0], ids[k])
        )
    lines += ["", '[node name="Coworkers" type="Node3D"]', ""]

    counters = Counter()
    scaled = 0
    for e in items:
        k = e["kind"]
        counters[k] += 1
        sx, sy, sz = e["scale"]
        if max(e["scale"]) - min(e["scale"]) > 1e-4:
            scaled += 1

        # A diagonal basis, so row-major and column-major coincide and the transpose
        # trap that caught the props cannot apply here. Written row-major anyway, to
        # match every other generated scene in the project.
        vals = [sx, 0.0, 0.0, 0.0, sy, 0.0, 0.0, 0.0, sz] + list(e["pos"])
        lines.append(
            '[node name="%s_%02d" parent="." instance=ExtResource("%s")]'
            % (SCENES[k][1], counters[k], ids[k])
        )
        lines.append("transform = Transform3D(%s)" % ", ".join("%.6f" % v for v in vals))
        lines.append("")

    open(out, "w").write("\n".join(lines))
    print("%s: %d coworkers" % (out, len(items)))
    for k, v in counters.most_common():
        print("   %-8s %d -> %s" % (k, v, SCENES[k][0]))
    print("   non-uniformly scaled: %d" % scaled)


if __name__ == "__main__":
    main()
