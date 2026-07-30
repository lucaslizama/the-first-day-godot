#!/usr/bin/env python3
"""Extracts each Fortunato clip's per-bone rotation from Unity's .anim files.

    python3 tools/extract_unity_bone_poses.py <unity Animaciones dir>   # writes $SP/bone_poses.json

Emitted in GODOT space: a Unity bone-local quaternion (x, y, z, w) becomes
(x, -y, -z, w), which is the same diag(-1, 1, 1) conjugation every placement in this
port uses, expressed on a quaternion. That is not an assumption - it was measured
against the 35 bones our jumpL1Frame and Unity's have in common, where it reproduces
every one of them (allowing for q == -q, which is the same rotation). The applier
re-checks it per bone and refuses to write if it stops holding.

Only the FIRST key of each curve is taken. That is enough for what this is for: the
bones missing from our clips are missing because they never change, so one value is
the whole curve. Bones that do move are already present and are only validated, not
replaced.

Deformation bones only. Unity's clips also carry the Maya IK/FK control rig, which
addresses nodes the imported character does not have.
"""

import json
import os
import re
import sys

FIRST_KEY = re.compile(
    r"value: \{x: ([-\d.eE+]+), y: ([-\d.eE+]+), z: ([-\d.eE+]+), w: ([-\d.eE+]+)\}"
)


def clip_bones(path):
    """Bone name -> Godot-space quaternion, for the deformation skeleton."""
    text = open(path, errors="ignore").read()
    start = text.find("m_RotationCurves:")
    end = text.find("m_CompressedRotationCurves:")
    if start < 0:
        return {}
    section = text[start : end if end > start else len(text)]

    out = {}
    for block in section.split("- curve:")[1:]:
        m = re.search(r"path: (\S+)", block)
        if not m or not m.group(1).startswith("DeformationSystem"):
            continue
        bone = m.group(1).split("/")[-1]
        key = FIRST_KEY.search(block)
        if not key:
            continue
        x, y, z, w = (float(v) for v in key.groups())
        # M R M on a quaternion, M = diag(-1, 1, 1).
        out[bone] = [x, -y, -z, w]
    return out


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__.strip().splitlines()[2].strip())
    folder = sys.argv[1]
    out_dir = os.environ.get("SP", "/tmp")

    result = {}
    for name in sorted(os.listdir(folder)):
        if not name.endswith(".anim"):
            continue
        bones = clip_bones(os.path.join(folder, name))
        if not bones:
            print("  %-16s no deformation rotation curves; skipped" % name)
            continue
        result[name[:-5]] = bones
        print("  %-16s %d deformation bones" % (name[:-5], len(bones)))

    path = os.path.join(out_dir, "bone_poses.json")
    json.dump(result, open(path, "w"), indent=1)
    print("wrote %s (%d clips)" % (path, len(result)))


if __name__ == "__main__":
    main()
