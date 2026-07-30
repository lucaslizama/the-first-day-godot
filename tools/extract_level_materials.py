#!/usr/bin/env python3
"""Rebuilds models/level/level_materials.json from Unity's scene.

    python3 tools/extract_level_materials.py [unity-project-root]

The two level shells, nivel.fbx and nivel_p2.fbx, ship from Maya with one material and
get their real materials from the SCENE: every prefab instance carries an
`m_Materials.Array.data[N]` override per renderer. There are 74 of them. Godot has no
equivalent of per-instance material overrides on an inherited scene, so level.tscn
assigns `surface_material_override/N` on each mesh instead, and this table is what
generates them.

The whole difficulty is that an override names its renderer by fileID, not by mesh:

    - target: {fileID: 2300046, guid: ..., type: 3}
      propertyPath: m_Materials.Array.data[0]

Resolving 2300046 to a mesh name is the only hard step, and getting it wrong silently
paints the level with the right materials in the wrong places. Do NOT guess it from the
FBX's Model record order. That order is `Nivel_p2, polySurface6, polySurface7,
polySurface9, polySurface10, ...`, whereas Unity's renderer order is `polySurface6,
polySurface10, polySurface11, ... polySurface31, polySurface7, polySurface9,
polySurface32, polySurface34` - Maya's export order and Unity's import order disagree,
and 7 and 9 land at the END.

This tool exists because of that trap, but note what it actually established: the
Model-order guess had made four nivel_p2 meshes LOOK wrongly painted, and this
regenerates the shipped level_materials.json byte for byte, all 74 entries across both
shells. The reported material bug was not real; the diagnosis was. Before this existed
the table had no generator in the repo at all, so the suspicion could be neither
confirmed nor dismissed without writing one.

The authority is the FBX's own .meta file, which carries a `fileIDToRecycleName:` table
mapping every fileID Unity minted to the object it belongs to. It is a RECYCLE table, so
it also retains names from earlier exports of the same FBX - nivel.fbx's lists 53
renderers (pPlane1..pPlane27, plataformaCae, mesa) where the current FBX has 27. Stale
entries are harmless here because the scene only references fileIDs that currently
exist, but it does mean the table's size means nothing and it must never be used to
decide what the FBX contains.

Because that mapping is load-bearing and a recycle table could in principle be wrong,
it is cross-checked against something the table cannot influence: a mesh has a second
material slot only if it has a second submesh, so the set of names carrying a slot 1
must equal the set of meshes Godot imports with 2 surfaces. tools/verify_level_shells.gd
does that comparison against the real imported models. It passes on both shells - 6
names for nivel (polySurface1..5, polySurface33) and 14 for nivel_p2 - which is
independent confirmation that the recycle table is the right mapping. Under the Model-order
guess it does not: that predicts polySurface17 and polySurface18 have two slots and
polySurface7 and polySurface9 have one, and the imported meshes say the opposite.

The output shape is the one scripts/Gameplay/LevelShell.cs reads: shell -> mesh name ->
slot index -> material path.
"""

import json
import os
import re
import sys

# Unity material name -> our resource. Only these two exist in the level.
MATERIALS = {
    "mat_general": "res://materials/level_general.tres",
    "mat_generalTransparencia": "res://materials/level_transparent.tres",
}
SHELLS = ("nivel.fbx", "nivel_p2.fbx")
SCENE = "Assets/Scenes/nivelEscena.unity"
OUT = "models/level/level_materials.json"

OVERRIDE = re.compile(
    r"- target: \{fileID: (-?\d+), guid: \w+, type: \d+\}\s*\n"
    r"\s*propertyPath: m_Materials\.Array\.data\[(\d+)\]\s*\n"
    r"\s*value:\s*\n"
    r"\s*objectReference: \{fileID: \d+, guid: ([0-9a-f]{32})"
)


def guid_index(root):
    """guid -> (asset name, .meta path), for every asset in the project."""
    out = {}
    for folder, _, files in os.walk(os.path.join(root, "Assets")):
        for f in files:
            if not f.endswith(".meta"):
                continue
            path = os.path.join(folder, f)
            m = re.search(r"guid: ([0-9a-f]{32})", open(path, errors="ignore").read())
            if m:
                out[m.group(1)] = (f[:-5], path)
    return out


def instance_block(scene_text, guid):
    """The Prefab (class 1001) block whose m_ParentPrefab is this FBX."""
    parts = re.split(r"--- !u!(\d+) &(\d+)[^\n]*\n", scene_text)
    for i in range(1, len(parts), 3):
        cls, body = parts[i], parts[i + 2]
        if cls == "1001" and re.search(
            r"m_ParentPrefab: \{fileID: \d+, guid: " + guid, body
        ):
            return body
    raise SystemExit("no prefab instance of guid %s in the scene" % guid)


def shell_table(scene_text, guids, shell):
    matches = [(g, p) for g, (n, p) in guids.items() if n == shell]
    if len(matches) != 1:
        raise SystemExit("expected exactly one %s, found %d" % (shell, len(matches)))
    guid, meta_path = matches[0]
    names = dict(
        (int(f), n)
        for f, n in re.findall(
            r"^\s+(\d+): (\S+)$", open(meta_path, errors="ignore").read(), re.M
        )
    )
    if not names:
        raise SystemExit("%s has no fileIDToRecycleName table" % meta_path)

    table = {}
    for fid, slot, ref in OVERRIDE.findall(instance_block(scene_text, guid)):
        fid = int(fid)
        if fid not in names:
            raise SystemExit(
                "%s: renderer %d is not in the recycle table, so its mesh is unknown"
                % (shell, fid)
            )
        mesh = names[fid]
        unity_material = guids.get(ref, (ref, None))[0]
        if unity_material.endswith(".mat"):
            unity_material = unity_material[:-4]
        if unity_material not in MATERIALS:
            raise SystemExit(
                "%s/%s slot %s uses '%s', which has no Godot resource mapped"
                % (shell, mesh, slot, unity_material)
            )
        per_mesh = table.setdefault(mesh, {})
        if slot in per_mesh:
            raise SystemExit(
                "%s: two overrides for %s slot %s - the fileID mapping is not one-to-one"
                % (shell, mesh, slot)
            )
        per_mesh[slot] = MATERIALS[unity_material]
    return table


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "../the-first-day-unity"
    scene_text = open(os.path.join(root, SCENE), errors="ignore").read()
    guids = guid_index(root)

    result = {}
    for shell in SHELLS:
        table = shell_table(scene_text, guids, shell)
        result[shell] = dict(sorted(table.items()))
        two_slot = sorted(m for m, s in table.items() if "1" in s)
        print(
            "%-14s %d renderers, %d slots, %d with a second slot: %s"
            % (
                shell,
                len(table),
                sum(len(s) for s in table.values()),
                len(two_slot),
                ", ".join(two_slot),
            )
        )

    # Trailing newline: without it every regeneration shows a diff against the
    # committed table even when nothing changed.
    with open(OUT, "w") as f:
        json.dump(result, f, indent=1, sort_keys=True)
        f.write("\n")
    print("wrote %s" % OUT)


if __name__ == "__main__":
    main()
