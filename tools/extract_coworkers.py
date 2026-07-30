#!/usr/bin/env python3
"""Extracts every coworker's world transform out of nivelEscena.

Run from the Unity project's Assets directory, with SP pointing at a scratch dir:

    cd ../the-first-day-unity/Assets && SP=/tmp python3 <repo>/tools/extract_coworkers.py

Writes $SP/coworkers.json: one entry per coworker with its kind (mono1 or mono2),
world position, rotation and scale, plus one entry per whisper emitter.

Why this is separate from extract_unity_transforms.py
----------------------------------------------------

That script only reads a prefab's *root* transform, which is all a prop needs. It
is also a script with top-level side effects rather than a module, so its helpers
cannot be imported without it re-reading the scene and rewriting props.json. The
quaternion helpers are therefore duplicated here, deliberately and identically.

The coworkers need more than a root transform. Three of the five coworker prefabs
are *clusters*: coworkers_group 1, coworkers_group2 and coworkers_group3 each
contain seven coworkers - 4 mono1 and 3 mono2 - baked in as plain GameObjects
rather than as nested prefab instances. So a single group instance in the scene is
seven coworkers, and their transforms only exist inside the prefab file.

This is why the recon doc's "31 SpriteRenderers" is not the coworker count. That
is a count of stripped component documents in the scene, which Unity only writes
for objects carrying overrides. The real count is
13 mono1 + 5 mono2 instanced directly, plus 8 group instances of 7 each = 74.
"""

import json
import os
import re
import sys
from collections import Counter

from unity_space import to_godot

MONO_PREFABS = {"mono1.prefab": "mono1", "mono2_prefab.prefab": "mono2"}
GROUP_PREFABS = {"coworkers_group 1.prefab", "coworkers_group2.prefab", "coworkers_group3.prefab"}

## SoundAttenuationByDeath.cs, the whisper attenuation on each group root.
SOUND_SCRIPT_GUID = "d428b6d30c257084898f758689387497"


def guid_map():
    g = {}
    for root, _, files in os.walk("."):
        for f in files:
            if not f.endswith(".meta"):
                continue
            p = os.path.join(root, f)
            m = re.search(r"^guid: (\w+)", open(p, errors="ignore").read(), re.M)
            if m:
                g[m.group(1)] = os.path.relpath(p[:-5])
    return g


def v3(d, key):
    m = re.search(key + r": \{x: ([-\d.eE+]+), y: ([-\d.eE+]+), z: ([-\d.eE+]+)\}", d)
    return [float(x) for x in m.groups()] if m else None


def v4(d, key):
    m = re.search(
        key + r": \{x: ([-\d.eE+]+), y: ([-\d.eE+]+), z: ([-\d.eE+]+), w: ([-\d.eE+]+)\}", d
    )
    return [float(x) for x in m.groups()] if m else None


def qmul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return [
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
        aw * bw - ax * bx - ay * by - az * bz,
    ]


def qrot(q, v):
    x, y, z, w = q
    vx, vy, vz = v
    tx, ty, tz = 2 * (y * vz - z * vy), 2 * (z * vx - x * vz), 2 * (x * vy - y * vx)
    return [
        vx + w * tx + (y * tz - z * ty),
        vy + w * ty + (z * tx - x * tz),
        vz + w * tz + (x * ty - y * tx),
    ]


def compose(ppos, prot, pscl, pos, rot, scl):
    sp = [pos[i] * pscl[i] for i in range(3)]
    rp = qrot(prot, sp)
    return (
        [ppos[i] + rp[i] for i in range(3)],
        qmul(prot, rot),
        [pscl[i] * scl[i] for i in range(3)],
    )


def split(text):
    return re.split(r"\n(?=--- !u!)", text)


class PrefabFile:
    """A prefab's internal hierarchy: transforms, names and per-object components.

    Shared with extract_zones.py, which needs the same instance-plus-internal-tree
    composition for the kill volume's checkpoint children.
    """

    def __init__(self, path):
        self.transforms = {}
        self.names = {}
        self.components = {}
        self.root = None
        ## First BoxCollider found, and whether it is a trigger. Enough for the
        ## volumes in this project, which have one box each.
        self.box = None
        self.is_trigger = None
        text = open(path, errors="ignore").read()
        for d in split(text):
            m = re.match(r"--- !u!(\d+) &(\d+)", d)
            if not m:
                continue
            cid, fid = m.group(1), m.group(2)
            if cid == "4":
                f = re.search(r"m_Father: \{fileID: (\d+)\}", d)
                go = re.search(r"m_GameObject: \{fileID: (\d+)\}", d)
                self.transforms[fid] = {
                    "pos": v3(d, "m_LocalPosition") or [0.0, 0.0, 0.0],
                    "rot": v4(d, "m_LocalRotation") or [0.0, 0.0, 0.0, 1.0],
                    "scale": v3(d, "m_LocalScale") or [1.0, 1.0, 1.0],
                    "father": f.group(1) if f else "0",
                    "go": go.group(1) if go else None,
                }
                if not f or f.group(1) == "0":
                    self.root = fid
            elif cid == "1":
                n = re.search(r"m_Name: (.*)", d)
                self.names[fid] = n.group(1).strip() if n else "?"
                self.components[fid] = re.findall(r"- (\d+): \{fileID: (\d+)\}", d)
            elif cid == "95":
                go = re.search(r"m_GameObject: \{fileID: (\d+)\}", d)
                ctrl = re.search(r"m_Controller: \{fileID: \d+, guid: (\w+)", d)
                if go and ctrl:
                    self.components.setdefault("controller", {})[go.group(1)] = ctrl.group(1)
            elif cid == "65" and self.box is None:
                self.box = {
                    "size": v3(d, "m_Size") or [1.0, 1.0, 1.0],
                    "center": v3(d, "m_Center") or [0.0, 0.0, 0.0],
                }
                t = re.search(r"m_IsTrigger: (\d)", d)
                self.is_trigger = t.group(1) == "1" if t else None
            elif cid == "114":
                go = re.search(r"m_GameObject: \{fileID: (\d+)\}", d)
                s = re.search(r"m_Script: \{fileID: \d+, guid: (\w+)", d)
                if go and s and s.group(1) == SOUND_SCRIPT_GUID:
                    mn = re.search(r"minDistance: ([-\d.eE+]+)", d)
                    mx = re.search(r"maxMinDistance: ([-\d.eE+]+)", d)
                    self.components.setdefault("sound", {})[go.group(1)] = {
                        "minDistance": float(mn.group(1)) if mn else 1.0,
                        "maxMinDistance": float(mx.group(1)) if mx else 10.0,
                    }

    def local(self, tid):
        """Transform of tid relative to the prefab root, root's own TRS excluded.

        Excluded because the caller already has the root's world transform, taken
        from the scene instance where it may have been overridden. Including the
        prefab's authored root TRS here as well applies it twice: the first version
        of this tool did, and put coworkers at x = -106 in a level that spans 0 to
        126, scaled four times too large - the group roots carry both an offset and
        a scale of about four.
        """
        if tid == self.root:
            return [0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 1.0], [1.0, 1.0, 1.0]
        t = self.transforms[tid]
        ppos, prot, pscl = self.local(t["father"])
        return compose(ppos, prot, pscl, t["pos"], t["rot"], t["scale"])


def main():
    guids = guid_map()
    by_name = {}
    for guid, path in guids.items():
        by_name.setdefault(os.path.basename(path), (guid, path))

    prefabs = {}

    def prefab(name):
        if name not in prefabs:
            prefabs[name] = PrefabFile(by_name[name][1])
        return prefabs[name]

    # Which controller guid means which coworker, read from the prefabs themselves
    # rather than hardcoded.
    kind_by_controller = {}
    for pname, kind in MONO_PREFABS.items():
        p = prefab(pname)
        for _, guid in p.components.get("controller", {}).items():
            kind_by_controller[guid] = kind

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
            instances[fid] = {
                "prefab": os.path.basename(guids.get(gm.group(1), "?")) if gm else "?",
                "mods": mods,
                "parent": tp.group(1) if tp else "0",
                "name": nm.group(1).strip() if nm else None,
            }

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
        rootid = p.root
        mm = inst["mods"].get(rootid, {})
        if not mm and inst["mods"]:
            for _, v in inst["mods"].items():
                if any(k.startswith("m_LocalPosition") for k in v):
                    mm = v
                    break
        dpos, drot, dscl = p.transforms[rootid]["pos"], p.transforms[rootid]["rot"], p.transforms[rootid]["scale"]
        pos = [mm.get("m_LocalPosition." + a, dpos[i]) for i, a in enumerate("xyz")]
        rot = [mm.get("m_LocalRotation." + a, drot[i]) for i, a in enumerate("xyzw")]
        scl = [mm.get("m_LocalScale." + a, dscl[i]) for i, a in enumerate("xyz")]
        ppos, prot, pscl = world_transform(inst["parent"], depth + 1)
        return compose(ppos, prot, pscl, pos, rot, scl)

    out = []
    whispers = []
    counts = Counter()
    nonuniform = []

    for iid, inst in instances.items():
        name = inst["prefab"]
        if name not in MONO_PREFABS and name not in GROUP_PREFABS:
            continue
        wp, wr, ws = world_instance(iid)

        if name in MONO_PREFABS:
            entries = [(MONO_PREFABS[name], inst["name"] or MONO_PREFABS[name], wp, wr, ws)]
        else:
            p = prefab(name)
            entries = []
            for tid, t in p.transforms.items():
                go = t["go"]
                ctrl = p.components.get("controller", {}).get(go)
                if ctrl is None:
                    continue  # the group root itself, which carries no Animator
                kind = kind_by_controller.get(ctrl)
                if kind is None:
                    sys.exit("unknown animator controller %s in %s" % (ctrl, name))
                lp, lr, ls = p.local(tid)
                cp, cr, cs = compose(wp, wr, ws, lp, lr, ls)
                entries.append((kind, "%s/%s" % (inst["name"] or name, p.names[go]), cp, cr, cs))

            # The whisper emitter lives on the group root.
            for go, cfg in p.components.get("sound", {}).items():
                whispers.append({
                    "source": inst["name"] or name,
                    "pos": [round(v, 5) for v in wp],
                    "minDistance": cfg["minDistance"],
                    "maxMinDistance": cfg["maxMinDistance"],
                })

        for kind, label, cp, cr, cs in entries:
            counts[kind] += 1
            if max(cs) - min(cs) > 1e-4:
                nonuniform.append((label, cs))
            out.append({
                "kind": kind,
                "name": label,
                "pos": [round(v, 5) for v in cp],
                "rot": [round(v, 6) for v in cr],
                "scale": [round(v, 5) for v in cs],
            })

    out.sort(key=lambda e: (e["kind"], e["pos"][2], e["pos"][0]))
    # Conjugated into Godot space on the way out; see tools/unity_space.py.
    json.dump(
        to_godot({"coworkers": out, "whispers": whispers}),
        open(os.environ["SP"] + "/coworkers.json", "w"),
        indent=1,
    )

    for k, v in counts.most_common():
        print("  %-8s %d" % (k, v), file=sys.stderr)
    print("  TOTAL %d coworkers, %d whisper emitters" % (len(out), len(whispers)), file=sys.stderr)
    if nonuniform:
        print("  non-uniform scales (%d):" % len(nonuniform), file=sys.stderr)
        for label, s in nonuniform[:5]:
            print("     %-24s %s" % (label, s), file=sys.stderr)


if __name__ == "__main__":
    main()
