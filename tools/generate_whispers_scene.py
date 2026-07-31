#!/usr/bin/env python3
"""Generates scenes/whispers.tscn: one whisper emitter per cluster of coworkers.

    python3 tools/generate_whispers_scene.py [--radius 25] [scenes/coworkers.tscn] [out.tscn]

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

THE RADIUS IS NOT JUST A COUNT. Because unit_size comes from the cluster's own extent, a
smaller radius makes every emitter quieter as well as more numerous, and that is a trap I
walked into: the first version used 18 m with an 8 m floor, which put an emitter near every
coworker and then could not be heard. Measured over 28 points along the player's route
(platform tops, the spawn, the end of the level), taking the loudest emitter at each:

    configuration                      mean   points above 0.5   summed loudness
    the original 7 emitters            0.610       21 / 28             2.22
    18 m radius, 8 m floor             0.431        3 / 28             2.19
    25 m radius, 8 m floor (this)      0.707       27 / 28             2.69
    18 m radius, 20 m floor            0.760       28 / 28             4.39

The 18 m version was audible on 3 route points out of 28, against the original's 21, which is
why the whispers went missing everywhere after the first attempt at fixing them going missing
on one side. 25 m matches the original's total loudness within about a decibel while covering
both sides and being audible almost everywhere. Raising the floor instead reaches the same
audibility at roughly twice the original's summed loudness, which is a different game.

So when changing --radius, check tools/verify_whispers.gd's route-audibility assertion, not
just the coverage one. Coverage of the coworkers and audibility to the player are different
properties and only the second one is what a player notices.
"""

import argparse
import math
import re

## Metres. Sets the emitter count AND, indirectly, how far each one carries: unit_size comes
## from the cluster's own extent, so wider clusters are audible from further away. 18 m was
## tried first and was a mistake - see the docstring.
DEFAULT_RADIUS = 25.0

## Floor for an emitter's unit_size, so a cluster of one coworker is still audible from a
## sensible distance rather than only when standing inside it.
MIN_UNIT_SIZE = 8.0

## Metres ADDED to unit_size at full death constant. WhisperEmitter widens unit_size from
## MinDistance to MaxMinDistance as deaths accumulate, which is what makes the whisper "close
## in" - a wider unit_size attenuates less, so it carries further.
##
## Additive, like Unity's, but 15 m rather than its 5. Unity went 40 -> 45, a 12% change that
## is essentially inaudible, so the mechanic its own author described barely existed. Over the
## sampled route this takes summed loudness from 2.69 to 5.24, which is an escalation you can
## actually hear.
DEATH_GROWTH_METRES = 15.0

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
                "grown": unit + DEATH_GROWTH_METRES,
                "count": len(members),
                "extent": extent,
            }
        )

    # Front to back, so the node order in the scene follows the player's route.
    emitters.sort(key=lambda e: -e["pos"][2])

    # No ';' header, and no per-emitter annotation below: comments in a .tscn are destroyed by
    # any editor save or ResourceSaver.save(), so they are write-only memory. Why this scene is
    # separate from coworkers.tscn, and why the emitters are silent until the player dies, is in
    # docs/level-port-scope.md under "Coworkers". The per-cluster coverage this used to write
    # into the file is printed to stdout instead. See CLAUDE.md.
    lines = [
        "[gd_scene load_steps=2 format=3]",
        "",
        '[ext_resource type="PackedScene" path="res://scenes/whisper.tscn" id="1_whisper"]',
        "",
        '[node name="Whispers" type="Node3D"]',
    ]

    for i, e in enumerate(emitters):
        x, y, z = e["pos"]
        lines.append("")
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
    # Per-cluster coverage. This used to be written into the scene as a comment beside each
    # emitter, where it did not survive a save; it is per-run output, so stdout is where it goes.
    for i, e in enumerate(emitters):
        print(
            "   Whisper_%02d  %2d coworker(s), furthest %5.1f m, unit_size %6.3f -> %6.3f"
            % (i + 1, e["count"], e["extent"], e["unit"], e["grown"])
        )


if __name__ == "__main__":
    main()
