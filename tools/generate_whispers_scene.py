#!/usr/bin/env python3
"""Generates scenes/whispers.tscn: one whisper emitter per cluster of coworkers.

    python3 tools/generate_whispers_scene.py [--radius 18] [scenes/coworkers.tscn] [out.tscn]

The whispers used to live in scenes/coworkers.tscn, one per Unity coworker GROUP, and the
left-hand side of the level had none. Measured over the 74 placed coworkers:

    side              coworkers   emitters   mean unit_size/distance to the nearest
    negative x (left)     25          0                0.53
    positive x (right)    49          7               46.1

All seven sat at positive x. The 25 on the left were served only by a single emitter 90 to
120 m away, which is a distant wash rather than the sound coming from the people making it.

The cause was in tools/extract_coworkers.py: it only looks for an AudioSource on a coworker
GROUP ROOT. Unity actually has 12 susurro_loko sources, and the five it missed are on objects
that are not group roots. Rather than chase those five, this places emitters from OUR OWN
verified coworker placement, so coverage is a property of where the coworkers actually are
and cannot silently depend on how the Unity scene happened to be organised. It also means
this tool needs no access to the Unity project.

Deliberately a redesign, not a port. Unity's own attenuation values were inconsistent between
groups - minDistance 1 with maxMinDistance 10 on some, 40 and 45 on others, an order of
magnitude apart for the same sound - so reproducing them faithfully would reproduce the
unevenness. Each emitter here is sized from its own cluster instead.

Clustering is greedy: repeatedly take the unassigned coworker with the most neighbours within
--radius and absorb them all. Not k-means, because the number of clusters is not known in
advance and the coworkers come in tight knots with wide gaps, which is the case greedy
seeding handles well and k-means handles badly.

At the default 18 m: 15 emitters, 9 left and 6 right, and no coworker more than 23.3 m from
the emitter covering it. Smaller radii give more emitters and tighter coverage (12 m: 19
emitters, worst 14.0 m); larger give fewer and looser (35 m: 9 emitters, worst 36.2 m, and
only 3 on the left).
"""

import argparse
import math
import re

## Metres. See the module docstring for what other values produce.
DEFAULT_RADIUS = 18.0

## Floor for an emitter's unit_size, so a cluster of one coworker is still audible from a
## sensible distance rather than only when standing inside it.
MIN_UNIT_SIZE = 8.0

## unit_size at full death constant, as a multiple of the resting one. WhisperEmitter widens
## unit_size from MinDistance to MaxMinDistance as deaths accumulate, which is what makes the
## whisper "close in" - a wider unit_size attenuates less, so it carries further.
DEATH_GROWTH = 2.0

NODE = re.compile(
    r'\[node name="(Coworker\w+)"[^\]]*\]\s*\ntransform = Transform3D\(([^)]*)\)'
)


def read_coworkers(path):
    """[(name, (x, y, z))] from a generated coworkers scene."""
    out = []
    for m in NODE.finditer(open(path).read()):
        nums = [float(v) for v in m.group(2).split(",")]
        out.append((m.group(1), (nums[9], nums[10], nums[11])))
    return out


def distance(a, b):
    return math.sqrt(sum((p - q) ** 2 for p, q in zip(a, b)))


def cluster(points, radius):
    """Greedy densest-first clustering. Returns a list of lists of indices."""
    remaining = set(range(len(points)))
    groups = []
    while remaining:
        seed = max(
            remaining,
            key=lambda i: sum(
                1 for j in remaining if distance(points[i][1], points[j][1]) <= radius
            ),
        )
        members = [
            j for j in remaining if distance(points[seed][1], points[j][1]) <= radius
        ]
        groups.append(members)
        remaining -= set(members)
    return groups


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--radius", type=float, default=DEFAULT_RADIUS)
    ap.add_argument("source", nargs="?", default="scenes/coworkers.tscn")
    ap.add_argument("out", nargs="?", default="scenes/whispers.tscn")
    args = ap.parse_args()

    people = read_coworkers(args.source)
    if not people:
        raise SystemExit(
            "no coworkers found in %s - has the scene format changed?" % args.source
        )

    groups = cluster(people, args.radius)
    emitters = []
    for members in groups:
        cx = sum(people[i][1][0] for i in members) / len(members)
        cy = sum(people[i][1][1] for i in members) / len(members)
        cz = sum(people[i][1][2] for i in members) / len(members)
        centre = (cx, cy, cz)
        extent = max(distance(people[i][1], centre) for i in members)
        unit = max(MIN_UNIT_SIZE, extent)
        emitters.append(
            {
                "pos": centre,
                "unit": unit,
                "grown": unit * DEATH_GROWTH,
                "count": len(members),
                "extent": extent,
            }
        )

    # Front to back, so the node order in the scene follows the player's route.
    emitters.sort(key=lambda e: -e["pos"][2])

    lines = [
        "[gd_scene load_steps=2 format=3]",
        "",
        "; One whisper emitter per cluster of coworkers, generated by",
        "; tools/generate_whispers_scene.py from scenes/coworkers.tscn. Do not edit by hand.",
        ";",
        "; The audio used to live in coworkers.tscn. It is separate because it is not the same",
        "; kind of thing: a coworker is a placed billboard whose position comes from Unity, an",
        "; emitter is derived coverage over wherever those billboards ended up. Mixing them",
        "; meant regenerating the placement and regenerating the sound were the same operation,",
        "; and it hid the bug this fixes - every emitter was on the right-hand side of the level,",
        "; leaving the 25 coworkers at negative x with no whisper nearer than 90 m.",
        ";",
        "; Emitters are SILENT until the player starts dying: WhisperEmitter sets volume from",
        "; GameManager's death constant, which is 0 at level start. So an empty-sounding level is",
        "; correct, and to hear these you have to die. See WhisperEmitter.cs.",
        "",
        '[ext_resource type="PackedScene" path="res://scenes/whisper.tscn" id="1_whisper"]',
        "",
        '[node name="Whispers" type="Node3D"]',
    ]

    for i, e in enumerate(emitters):
        x, y, z = e["pos"]
        lines.append("")
        lines.append(
            "; %d coworker(s), furthest %.1f m from here"
            % (e["count"], e["extent"])
        )
        lines.append(
            '[node name="Whisper_%02d" parent="." instance=ExtResource("1_whisper")]'
            % (i + 1)
        )
        lines.append(
            "transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %.6f, %.6f, %.6f)"
            % (x, y, z)
        )
        lines.append("MinDistance = %.3f" % e["unit"])
        lines.append("MaxMinDistance = %.3f" % e["grown"])

    with open(args.out, "w") as f:
        f.write("\n".join(lines) + "\n")

    left = sum(1 for e in emitters if e["pos"][0] < 0.0)
    worst = max(
        min(distance(p[1], e["pos"]) for e in emitters) for p in people
    )
    print(
        "%s: %d emitters for %d coworkers (%d left / %d right), "
        "no coworker further than %.1f m from one"
        % (args.out, len(emitters), len(people), left, len(emitters) - left, worst)
    )


if __name__ == "__main__":
    main()
