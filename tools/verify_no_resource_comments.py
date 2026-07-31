#!/usr/bin/env python3
"""Asserts that no .tscn/.tres/.import file carries a ';' comment, and strips them with --fix.

    python3 tools/verify_no_resource_comments.py          # check, exit 1 if any are found
    python3 tools/verify_no_resource_comments.py --fix    # remove them

WHY THIS EXISTS. Comments in a Godot resource file are write-only memory. A Godot editor save
strips every one of them, and so does any ResourceSaver.save() - including the godot_mcp_toolkit
addon's audiobus command, which rewrites default_bus_layout.tres. This project lost ~40 lines of
mixer rationale that way, and level.tscn's material overrides three times over. Knowledge that
must survive goes in CLAUDE.md or docs/level-port-scope.md; see the rule in CLAUDE.md.

So this is not a style check. It is the guard that keeps 618 lines of reasoning from being written
back into files that cannot hold it - and it belongs in the repo rather than in whoever's memory,
because the failure mode is silent.

THE ONE EXCEPTION IS NOT DOCUMENTATION. tools/generate_shell_overrides.gd finds its generated
region in level.tscn by the two marker lines in KEEP below, and refuses to run without them. They
are that tool's syntax. Strip them and it appends a second copy of all 73 override blocks.

Two hazards in doing this correctly, both live in this project:

  1. A .tscn can hold a multi-line string value - level.tscn's Credits label spans 28 lines. A
     line inside one that starts with ';' is DATA. Getting this wrong silently rewrote the game's
     credits, so string state is tracked across lines and blank lines inside a string are never
     touched.
  2. A comment can contain an unbalanced quote (hammer.tscn's did), which corrupts that tracking.
     Comment lines are therefore identified and skipped BEFORE quote state is updated from them.
"""

import subprocess
import sys

KEEP = (
    "; >>> BEGIN generated shell overrides",
    "; <<< END generated shell overrides",
)


def scan(path):
    """Returns (offending_line_numbers, rewritten_lines_or_None_if_clean)."""
    with open(path) as f:
        lines = f.read().split("\n")

    out = []          # (line, was_inside_a_string)
    offenders = []
    in_string = False

    for number, line in enumerate(lines, 1):
        stripped = line.lstrip()
        if not in_string and stripped.startswith(";"):
            if any(stripped.startswith(k) for k in KEEP):
                out.append((line, False))
            else:
                offenders.append(number)
            # Deliberately NOT updating in_string from a comment: hazard 2.
            continue

        out.append((line, in_string))

        escaped = False
        for ch in line:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = not in_string

    if in_string:
        sys.exit("%s: unbalanced quotes; refusing to touch it" % path)

    if not offenders:
        return [], None

    # Collapse only the blank runs left behind OUTSIDE a string value: hazard 1.
    collapsed = []
    previous_blank_outside = False
    for line, inside in out:
        blank_outside = line == "" and not inside
        if blank_outside and previous_blank_outside:
            continue
        collapsed.append(line)
        previous_blank_outside = blank_outside

    return offenders, collapsed


def main():
    fix = "--fix" in sys.argv[1:]
    files = subprocess.check_output(
        ["git", "ls-files", "*.tscn", "*.tres", "*.import"], text=True
    ).split()

    total = 0
    dirty = 0
    for path in files:
        offenders, rewritten = scan(path)
        if not offenders:
            continue
        dirty += 1
        total += len(offenders)
        if fix:
            with open(path, "w") as f:
                f.write("\n".join(rewritten))
            print("%-44s -%d" % (path, len(offenders)))
        else:
            print(
                "  FAIL  %s: %d comment line(s) at %s"
                % (path, len(offenders), ", ".join(str(n) for n in offenders[:8]))
                + (" ..." if len(offenders) > 8 else "")
            )

    if fix:
        print("\nremoved %d comment line(s) from %d file(s)" % (total, dirty))
        return 0

    if total:
        print(
            "\nFAIL: %d comment line(s) in %d Godot resource file(s). They will not survive an"
            " editor save - move the knowledge to CLAUDE.md or docs/level-port-scope.md, then run"
            " this with --fix." % (total, dirty)
        )
        return 1

    print("PASS: %d Godot resource files carry no comments" % len(files))
    return 0


if __name__ == "__main__":
    sys.exit(main())
