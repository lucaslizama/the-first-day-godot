#!/usr/bin/env python3
"""Extracts the level's volumes and the player start out of nivelEscena.

Run from the Unity project's Assets directory, with SP pointing at a scratch dir:

    cd ../the-first-day-unity/Assets && SP=/tmp python3 <repo>/tools/extract_zones.py

Writes $SP/zones.json with the kill volume, its three checkpoints, the two trigger
zones and Fortunato's start transform, and prints what it found.

The kill volume's scale is the reason this needs a tool rather than a lookup: the
CheckPointZone root is scaled 152 x 1 x 321, and its checkpoint children are
positioned in that scaled space, so a checkpoint authored at a local x of -0.003
lands 0.46 m away and one at z 0.18153 lands 58 m away. Reading the local numbers
as metres puts every respawn point in the wrong place.

Prefab hierarchy handling is imported from extract_coworkers, which already has to
compose an instance transform with a prefab's internal tree.
"""

import json
import os
import re
import sys

from extract_coworkers import PrefabFile, compose, guid_map, split, v3, v4

WANTED = {
    "CheckPointZone.prefab": "kill_volume",
    "Trigger Zone.prefab": "trigger_zone",
    "Fortunato.prefab": "player",
}


def main():
    guids = guid_map()
    by_name = {}
    for guid, path in guids.items():
        by_name.setdefault(os.path.basename(path), path)

    text = open("Scenes/nivelEscena.unity", errors="ignore").read()
    docs = split(text)

    transforms = {}
    instances = {}
    for d in docs:
        m = re.match(r"--- !u!(\d+) &(\d+)", d)
        if not m:
            continue
        cid, fid = m.group(1), m.group(2)
        if cid == "4":
            f = re.search(r"m_Father: \{fileID: (\d+)\}", d)
            pi = re.search(r"m_PrefabInternal: \{fileID: (\d+)\}", d)
            transforms[fid] = {
                "pos": v3(d, "m_LocalPosition"),
                "rot": v4(d, "m_LocalRotation"),
                "scale": v3(d, "m_LocalScale"),
                "father": f.group(1) if f else "0",
                "inst": pi.group(1) if pi else None,
            }
        elif cid == "1001":
            gm = re.search(r"m_ParentPrefab: \{fileID: \d+, guid: (\w+)", d)
            tp = re.search(r"m_TransformParent: \{fileID: (\d+)\}", d)
            mods = {}
            for tgt, prop, val in re.findall(
                r"- target: \{fileID: (-?\d+), guid: \w+,\s*\n?\s*type: \d+\}\s*\n"
                r"\s*propertyPath: (m_Local\w+\.\w)\s*\n\s*value: ([-\d.eE+]+)",
                d,
            ):
                mods.setdefault(tgt, {})[prop] = float(val)
            nm = re.search(r"propertyPath: m_Name\n *value: (.*)", d)
            # Whether the instance flipped its collider into a trigger.
            trig = re.findall(r"propertyPath: m_IsTrigger\n *value: (\d+)", d)
            instances[fid] = {
                "prefab": os.path.basename(guids.get(gm.group(1), "?")) if gm else "?",
                "mods": mods,
                "parent": tp.group(1) if tp else "0",
                "name": nm.group(1).strip() if nm else None,
                "is_trigger_overrides": trig,
            }

    prefabs = {}

    def prefab(name):
        if name not in prefabs:
            prefabs[name] = PrefabFile(by_name[name])
        return prefabs[name]

    def world_transform(tid, depth=0):
        if tid == "0" or tid not in transforms or depth > 40:
            return [0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 1.0], [1.0, 1.0, 1.0]
        t = transforms[tid]
        if t["inst"] and t["inst"] in instances:
            return world_instance(t["inst"], depth + 1)
        ppos, prot, pscl = world_transform(t["father"], depth + 1)
        return compose(
            ppos, prot, pscl,
            t["pos"] or [0, 0, 0], t["rot"] or [0, 0, 0, 1], t["scale"] or [1, 1, 1],
        )

    def world_instance(iid, depth=0):
        inst = instances[iid]
        p = prefab(inst["prefab"])
        root = p.root
        mm = inst["mods"].get(root, {})
        if not mm and inst["mods"]:
            for _, v in inst["mods"].items():
                if any(k.startswith("m_LocalPosition") for k in v):
                    mm = v
                    break
        dpos = p.transforms[root]["pos"]
        drot = p.transforms[root]["rot"]
        dscl = p.transforms[root]["scale"]
        pos = [mm.get("m_LocalPosition." + a, dpos[i]) for i, a in enumerate("xyz")]
        rot = [mm.get("m_LocalRotation." + a, drot[i]) for i, a in enumerate("xyzw")]
        scl = [mm.get("m_LocalScale." + a, dscl[i]) for i, a in enumerate("xyz")]
        ppos, prot, pscl = world_transform(inst["parent"], depth + 1)
        return compose(ppos, prot, pscl, pos, rot, scl)

    out = {"kill_volume": None, "trigger_zones": [], "player": None}

    for iid, inst in instances.items():
        kind = WANTED.get(inst["prefab"])
        if kind is None:
            continue
        wp, wr, ws = world_instance(iid)
        p = prefab(inst["prefab"])
        entry = {
            "name": inst["name"] or inst["prefab"],
            "pos": [round(v, 5) for v in wp],
            "rot": [round(v, 6) for v in wr],
            "scale": [round(v, 5) for v in ws],
            "box": p.box,
            "is_trigger_prefab": p.is_trigger,
            "is_trigger_overrides": inst["is_trigger_overrides"],
        }

        if kind == "kill_volume":
            # The checkpoint children, in the root's scaled space.
            points = []
            for tid, t in p.transforms.items():
                if tid == p.root:
                    continue
                lp, lr, ls = p.local(tid)
                cp, cr, cs = compose(wp, wr, ws, lp, lr, ls)
                points.append({
                    "name": p.names.get(t["go"], "?"),
                    "local": [round(v, 5) for v in lp],
                    "pos": [round(v, 5) for v in cp],
                })
            points.sort(key=lambda e: e["name"])
            entry["checkpoints"] = points
            out["kill_volume"] = entry
        elif kind == "trigger_zone":
            out["trigger_zones"].append(entry)
        else:
            out["player"] = entry

    out["trigger_zones"].sort(key=lambda e: e["name"])
    json.dump(out, open(os.environ["SP"] + "/zones.json", "w"), indent=1)

    kv = out["kill_volume"]
    print("kill volume '%s' at %s" % (kv["name"], kv["pos"]), file=sys.stderr)
    print("   scale %s, box %s, trigger in prefab=%s overrides=%s"
          % (kv["scale"], kv["box"], kv["is_trigger_prefab"], kv["is_trigger_overrides"]), file=sys.stderr)
    for c in kv["checkpoints"]:
        print("   %-14s local %s -> world %s" % (c["name"], c["local"], c["pos"]), file=sys.stderr)
    for z in out["trigger_zones"]:
        print("trigger zone '%s' at %s scale %s box %s trigger prefab=%s overrides=%s"
              % (z["name"], z["pos"], z["scale"], z["box"], z["is_trigger_prefab"],
                 z["is_trigger_overrides"]), file=sys.stderr)
    if out["player"]:
        print("player start %s" % (out["player"]["pos"],), file=sys.stderr)


if __name__ == "__main__":
    main()
