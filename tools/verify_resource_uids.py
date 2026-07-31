#!/usr/bin/env python3
"""Checks that every uid:// reference in the project resolves to the file it names.

    python3 tools/verify_resource_uids.py

Godot writes references two ways at once:

    [ext_resource type="Sky" uid="uid://2ub5vhde6en" path="res://materials/sky_fernandito.tres" ...]

The uid is authoritative and the path is a fallback. A uid is only portable if the TARGET file
declares it, and where that declaration lives depends on the kind of resource:

    imported assets (.fbx, .ogg, .png)   uid= in the sibling .import file
    scripts (.cs, .gd)                   a .uid sidecar next to the script
    hand-written resources (.tres)       uid= in the [gd_resource ...] header line

When the target declares nothing, Godot invents a uid, keeps it only in .godot/uid_cache.bin, and
writes THAT into whatever scene references it. The cache is local and gitignored, so the reference
resolves on the machine that wrote it and nowhere else.

That is what happened to materials/sky_fernandito.tres. It had never carried a uid in any commit;
a new main_menu_background.tscn was authored in the editor and recorded the uid from that machine's
cache; and every other clone logged

    invalid UID: uid://2ub5vhde6en - using text path instead: res://materials/sky_fernandito.tres

on load. It kept working, because Godot falls back to the path - which is exactly why it survived
review. The fix is one line in the .tres header, and after adding it the uid cache must be deleted
and the project reimported before Godot registers it.

Worth knowing while reading a failure here: this project deliberately keeps hand-written comments
in its .tres files and reverts the churn Godot adds on save, which includes uid= lines. That is a
habit this check exists to make safe - reverting a uid= line in one file can break a reference in
another, and the only symptom is a warning.
"""

import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

## Where references can appear. Scenes and resources both use the ext_resource syntax.
SEARCH_GLOBS = ["scenes/**/*.tscn", "materials/**/*.tres", "textures/**/*.tres"]

## uid and path can appear in either order on the line, so both are matched independently within
## a single [ext_resource ...] block.
EXT = re.compile(r"\[ext_resource ([^\]]*)\]")
UID = re.compile(r'uid="(uid://[^"]+)"')
PATH = re.compile(r'path="res://([^"]+)"')

HEADER_UID = re.compile(r'^\[gd_(?:resource|scene)[^\]]*uid="(uid://[^"]+)"')


def declared_uid(rel):
    """The uid the target file itself declares, and where it declares it."""
    path = ROOT / rel

    sidecar = ROOT / (rel + ".uid")
    if sidecar.exists():
        return sidecar.read_text().strip(), rel + ".uid"

    imported = ROOT / (rel + ".import")
    if imported.exists():
        m = UID.search(imported.read_text())
        return (m.group(1) if m else None), rel + ".import"

    if path.exists() and path.suffix in (".tres", ".tscn"):
        first = path.read_text().split("\n", 1)[0]
        m = HEADER_UID.match(first)
        return (m.group(1) if m else None), rel

    return None, rel


def references():
    """[(referencing file, uid, target path)] for every uid-bearing ext_resource."""
    out = []
    for pattern in SEARCH_GLOBS:
        for f in sorted(ROOT.glob(pattern)):
            for block in EXT.findall(f.read_text()):
                uid = UID.search(block)
                target = PATH.search(block)
                if uid and target:
                    out.append((str(f.relative_to(ROOT)), uid.group(1), target.group(1)))
    return out


def main():
    refs = references()
    if not refs:
        raise SystemExit("found no uid-bearing references; has the scene format changed?")

    failures = 0
    checked = set()
    for source, uid, target in refs:
        if not (ROOT / target).exists():
            print("  FAIL  %s references %s, which does not exist" % (source, target))
            failures += 1
            continue

        declared, where = declared_uid(target)
        if declared == uid:
            checked.add(target)
            continue

        failures += 1
        if declared is None:
            print("  FAIL  %s declares no uid, but %s references it as %s."
                  " Godot invented that uid and kept it only in the local"
                  " .godot/uid_cache.bin, so the reference resolves on one machine and nowhere"
                  " else. Add uid=\"%s\" to %s, delete .godot/uid_cache.bin and reimport."
                  % (target, source, uid, uid, where))
        else:
            print("  FAIL  %s declares %s in %s, but %s references it as %s"
                  % (target, declared, where, source, uid))

    print("")
    if failures:
        print("FAIL: %d of %d uid reference(s) do not resolve" % (failures, len(refs)))
    else:
        print("PASS: %d uid references across %d target(s)" % (len(refs), len(checked)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
