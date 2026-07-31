#!/usr/bin/env python3
"""Generates scenes/zones.tscn from the volumes extract_zones.py found.

    python3 tools/generate_zones_scene.py <zones.json> [out.tscn]

Emits the kill volume with its three checkpoints and the two trigger zones.

Unity's box colliders are all authored 1 x 1 x 1 and sized by the node's scale - the
kill volume is a unit cube scaled 152 x 1 x 322. That is baked into the BoxShape3D's
size here and the nodes are left unscaled, because a scaled collision shape in Godot
is a known source of trouble and there is no reason to carry the indirection over.

The checkpoints are emitted at the world positions the extractor composed, which
means their scaled-space offsets are already resolved; see the note in
extract_zones.py about why reading their local numbers as metres does not work.
"""

import json
import sys


def fmt(vals):
    return ", ".join("%.6f" % v for v in vals)


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: generate_zones_scene.py <zones.json> [out.tscn]")
    data = json.load(open(sys.argv[1]))
    out = sys.argv[2] if len(sys.argv) > 2 else "scenes/zones.tscn"

    kv = data["kill_volume"]
    zones = data["trigger_zones"]
    if kv is None:
        sys.exit("no kill volume in the extraction")

    # Order matters in a .tscn: header, then ext_resource, then sub_resource, then
    # nodes.
    shapes = []

    def box(name, size):
        shapes.append(name)
        return [
            '[sub_resource type="BoxShape3D" id="%s"]' % name,
            "size = Vector3(%s)" % fmt(size),
            "",
        ]

    kv_size = [kv["box"]["size"][i] * kv["scale"][i] for i in range(3)]
    subresources = box("BoxShape3D_kill", kv_size)
    for i, z in enumerate(zones):
        subresources += box(
            "BoxShape3D_zone%d" % (i + 1),
            [z["box"]["size"][j] * z["scale"][j] for j in range(3)],
        )

    lines = [
        None,  # header, patched in once the shape count is known
        "",
        '[ext_resource type="Script" path="res://scripts/Gameplay/CheckpointTeleport.cs" id="1_teleport"]',
        "",
    ]
    lines += subresources
    lines += [
        '[node name="Zones" type="Node3D"]',
        "",
        '[node name="KillVolume" type="Area3D" parent="."]',
        "transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %s)" % fmt(kv["pos"]),
        'script = ExtResource("1_teleport")',
        'CheckpointPath = NodePath("../Checkpoint1")',
        "RespawnDelay = 2.0",
        "",
        '[node name="Shape" type="CollisionShape3D" parent="KillVolume"]',
        'shape = SubResource("BoxShape3D_kill")',
        "",
    ]

    # Checkpoint markers. Checkpoint 1 is where the player starts.
    for i, c in enumerate(kv["checkpoints"]):
        lines += [
            '[node name="Checkpoint%d" type="Node3D" parent="."]' % (i + 1),
            "transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %s)" % fmt(c["pos"]),
            "",
        ]

    for i, z in enumerate(zones):
        # No ';' annotations in the scene - see CLAUDE.md. What they said is in
        # docs/level-port-scope.md: these colliders are NOT triggers in the prefab and every
        # instance overrides m_IsTrigger to 1, so taking the prefab at face value gives a level
        # where the checkpoint never advances. The Unity names are echoed to stdout below.
        lines += [
            '[node name="TriggerZone%d" type="Area3D" parent="."]' % (i + 1),
            "transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %s)" % fmt(z["pos"]),
            "",
            '[node name="Shape" type="CollisionShape3D" parent="TriggerZone%d"]' % (i + 1),
            'shape = SubResource("BoxShape3D_zone%d")' % (i + 1),
            "",
        ]

    lines[0] = "[gd_scene load_steps=%d format=3]" % (len(shapes) + 2)
    open(out, "w").write("\n".join(lines))

    print("%s: kill volume %.0f x %.0f x %.0f m at %s" % (
        out, kv_size[0], kv_size[1], kv_size[2], kv["pos"]))
    for i, c in enumerate(kv["checkpoints"]):
        print("   Checkpoint%d %-14s %s" % (i + 1, c["name"], c["pos"]))
    for i, z in enumerate(zones):
        print("   TriggerZone%d %-13s %s" % (i + 1, z["name"], z["pos"]))
    if data.get("player"):
        print("   (player start in Unity: %s)" % data["player"]["pos"])


if __name__ == "__main__":
    main()
