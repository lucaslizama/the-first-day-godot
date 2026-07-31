#!/usr/bin/env python3
"""Bakes martillo_anim into models/props/hammer_swing.tres.

    python3 tools/bake_hammer_swing.py [out.tres]

Reads the Unity clip out of ../the-first-day-unity and writes a Godot Animation
holding one rotation_3d track: the hammer's ±80° pendulum, 2.6333 s, looping.

Baked at Unity's own 30 fps sample rate rather than transcribed as nine keys.
Unity stores a Hermite spline per quaternion component, with tangents; Godot's
rotation_3d tracks interpolate quaternions by nlerp or its own cubic, and neither
reproduces Unity's tangents. Sampling the spline at the rate Unity itself sampled
it sidesteps the question - the same thing Godot's FBX importer does with baked
takes - and the timing of the swing is gameplay, since the player has to walk past
it.

Emitted as a separate resource rather than a sub-resource inside hammer.tscn so the
generated data and the hand-written scene stay separable, the way the coworkers'
SpriteFrames are.
"""

import os
import re
import sys

CLIP = "../the-first-day-unity/Assets/Prefabs/Level Construction/Animations/martillo_anim.anim"

## Unity's m_SampleRate on the clip.
FPS = 30

## The node the track drives, relative to the AnimationPlayer's root.
TARGET = "Arm"


def read_keys(path):
    text = open(path, errors="ignore").read()
    block = re.search(r"m_RotationCurves:(.*?)\n  m_(?:Compressed|Euler|Position)", text, re.S)
    if block is None:
        sys.exit("%s: no m_RotationCurves block" % path)

    keys = re.findall(
        r"- time: ([-\d.eE+]+)\s*\n"
        r"\s*value: \{x: ([-\d.eE+]+), y: ([-\d.eE+]+), z: ([-\d.eE+]+), w: ([-\d.eE+]+)\}\s*\n"
        r"\s*inSlope: \{x: ([-\d.eE+]+), y: ([-\d.eE+]+), z: ([-\d.eE+]+), w: ([-\d.eE+]+)\}\s*\n"
        r"\s*outSlope: \{x: ([-\d.eE+]+), y: ([-\d.eE+]+), z: ([-\d.eE+]+), w: ([-\d.eE+]+)\}",
        block.group(1),
    )
    if not keys:
        sys.exit("%s: rotation curve has no keys with tangents" % path)

    parsed = []
    for k in keys:
        f = [float(v) for v in k]
        parsed.append({"t": f[0], "v": f[1:5], "in": f[5:9], "out": f[9:13]})

    stop = float(re.search(r"m_StopTime: ([\d.]+)", text).group(1))
    loop = re.search(r"m_LoopTime: (\d)", text).group(1) == "1"
    return parsed, stop, loop


def hermite(p0, m0, p1, m1, dt, u):
    """Unity's cubic Hermite segment, evaluated per component."""
    u2 = u * u
    u3 = u2 * u
    h00 = (2.0 * u3) - (3.0 * u2) + 1.0
    h10 = u3 - (2.0 * u2) + u
    h01 = (-2.0 * u3) + (3.0 * u2)
    h11 = u3 - u2
    return (h00 * p0) + (h10 * m0 * dt) + (h01 * p1) + (h11 * m1 * dt)


def sample(keys, t):
    if t <= keys[0]["t"]:
        return keys[0]["v"]
    if t >= keys[-1]["t"]:
        return keys[-1]["v"]
    for i in range(len(keys) - 1):
        a, b = keys[i], keys[i + 1]
        if not (a["t"] <= t <= b["t"]):
            continue
        dt = b["t"] - a["t"]
        u = (t - a["t"]) / dt
        q = [hermite(a["v"][c], a["out"][c], b["v"][c], b["in"][c], dt, u) for c in range(4)]
        n = sum(c * c for c in q) ** 0.5 or 1.0
        return [c / n for c in q]
    return keys[-1]["v"]


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "models/props/hammer_swing.tres"
    keys, stop, loop = read_keys(CLIP)

    steps = int(round(stop * FPS))
    baked = []
    for i in range(steps + 1):
        t = min(i / float(FPS), stop)
        q = sample(keys, t)
        baked.append((t, q))

    # Six floats per key: time, transition, then the quaternion. The transition is
    # not optional padding - Godot rejects the whole track if the array does not
    # divide by six, with only "Condition vcount % ROTATION_TRACK_SIZE is true" to
    # say so, and the animation then silently does nothing.
    #
    # Unity quaternions transfer directly, as established for the props; the 180
    # degree correction the sun needed was specific to light emission direction.
    values = []
    for t, q in baked:
        values += ["%.6f" % t, "1"] + ["%.6f" % c for c in q]

    # No ';' header: comments in a .tres do not survive an editor save or any
    # ResourceSaver.save(), so what this file is gets reported to stdout below and recorded in
    # docs/level-port-scope.md instead. See CLAUDE.md.
    lines = [
        '[gd_resource type="Animation" format=3]',
        "",
        "[resource]",
        'resource_name = "swing"',
        "length = %.6f" % stop,
        "loop_mode = %d" % (1 if loop else 0),
        'tracks/0/type = "rotation_3d"',
        "tracks/0/imported = false",
        "tracks/0/enabled = true",
        'tracks/0/path = NodePath("%s")' % TARGET,
        "tracks/0/interp = 1",
        "tracks/0/loop_wrap = true",
        "tracks/0/keys = PackedFloat32Array(%s)" % ", ".join(values),
        "",
    ]
    open(out, "w").write("\n".join(lines))

    first = baked[0][1]
    mid = baked[len(baked) // 2][1]
    print("%s: %d keys, %.4f s, loop=%s" % (out, len(baked), stop, loop))
    print("   t=0        quat (%.4f, %.4f, %.4f, %.4f)" % tuple(first))
    print("   t=%.3f  quat (%.4f, %.4f, %.4f, %.4f)" % ((baked[len(baked) // 2][0],) + tuple(mid)))


if __name__ == "__main__":
    main()
