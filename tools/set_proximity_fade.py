#!/usr/bin/env python3
"""Sets the proximity-fade distances on every material that has one.

    python3 tools/set_proximity_fade.py [--near 0.5] [--far 1.8]
    python3 tools/set_proximity_fade.py --off          # remove it everywhere

Surfaces fade out as they approach the camera, so geometry between the camera and the
player stops filling the screen. The reason it is needed is measurable: the camera holds a
hard MinimumDistance of 2 m from the player, so in the starting room - which is smaller
than that - it cannot retreat. Sampled across the room, 11 to 15 of every 24 view angles
put a wall between the camera and the player.

This exists because the same two distances have to be written into two unrelated kinds of
file, and a fade that starts at 0.5 m on the walls and 0.8 m on the shell would look like a
bug:

  * the 14 props are StandardMaterial3D, and use Godot's built-in distance fade
    (distance_fade_mode / _min_distance / _max_distance). Mode 2 is PIXEL_DITHER.
  * the 2 level-shell materials are ShaderMaterial on hand-written shaders, and take
    shader_parameter/proximity_fade_near and _far. See shaders/proximity_fade.gdshaderinc.

Mode 2 (dither), not mode 1 (alpha), and that is a measured choice rather than a taste one.
Smooth alpha looks cleaner in the fade tail, but it takes these surfaces off the opaque path
and changes how the level is LIT: on the starting-room view the mean frame colour went from
(67, 72, 83) to (101, 106, 109), a visibly brighter floor plus a player shadow the original
does not have. Dither leaves that view identical - same mean colour, 29 differing pixels out
of 630,000. The cost of dither is a sparse speckle where a surface is faintly visible, which
is the cheaper problem. The one place alpha IS used is level_fade, whose columns are blended
already by the original's vertex-colour transparency, so multiplying into ALPHA there changes
no render state.

Note this is NOT part of the Unity original, which had no distance fade at all: its camera
asset shipped a ThicknessChecking feature that nivelEscena leaves disabled, and
mat_generalTransparencia's transparency comes from vertex colour, not distance.

tools/verify_proximity_fade.gd checks every material agrees on the distances and that the
effect actually happens, so a material added later without a fade does not go unnoticed.
"""

import argparse
import glob
import os
import re
import sys

PROPS = "materials/props/*.tres"
SHELL = ["materials/level_general.tres", "materials/level_transparent.tres"]

# StandardMaterial3D.DistanceFadeMode.DISTANCE_FADE_PIXEL_DITHER
DITHER = 2

PROP_KEYS = (
    "distance_fade_mode",
    "distance_fade_min_distance",
    "distance_fade_max_distance",
)
SHELL_KEYS = (
    "shader_parameter/proximity_fade_near",
    "shader_parameter/proximity_fade_far",
)


def set_keys(path, pairs, drop_keys):
    """Rewrites `key = value` lines in a .tres, appending any that are absent.

    Only ever touches the listed keys, so the hand-written comment block at the top of
    every one of these files survives - which is the whole reason this edits the text
    rather than loading and re-saving the resource through Godot, which strips comments.
    """
    with open(path) as f:
        text = f.read()

    for key in drop_keys:
        text = re.sub(r"^%s = .*\n" % re.escape(key), "", text, flags=re.M)

    added = []
    for key, value in pairs:
        line = "%s = %s" % (key, value)
        pattern = r"^%s = .*$" % re.escape(key)
        if re.search(pattern, text, flags=re.M):
            text = re.sub(pattern, line, text, flags=re.M)
        else:
            if not text.endswith("\n"):
                text += "\n"
            text += line + "\n"
            added.append(key)

    with open(path, "w") as f:
        f.write(text)
    return added


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--near", type=float, default=0.5)
    ap.add_argument("--far", type=float, default=1.8)
    ap.add_argument("--off", action="store_true")
    args = ap.parse_args()

    if not args.off and args.near >= args.far:
        sys.exit(
            "near (%.3f) must be less than far (%.3f); Godot reads min >= max as a fade in "
            "the opposite direction, which would hide everything FAR away instead."
            % (args.near, args.far)
        )

    props = sorted(glob.glob(PROPS))
    if not props:
        sys.exit("no prop materials found at %s - run this from the project root" % PROPS)

    touched = 0
    for path in props:
        if args.off:
            set_keys(path, [], PROP_KEYS)
        else:
            set_keys(
                path,
                [
                    ("distance_fade_mode", str(DITHER)),
                    ("distance_fade_min_distance", "%.3f" % args.near),
                    ("distance_fade_max_distance", "%.3f" % args.far),
                ],
                [],
            )
        touched += 1

    for path in SHELL:
        if not os.path.exists(path):
            sys.exit("missing %s" % path)
        if args.off:
            set_keys(path, [], SHELL_KEYS)
        else:
            set_keys(
                path,
                [
                    ("shader_parameter/proximity_fade_near", "%.3f" % args.near),
                    ("shader_parameter/proximity_fade_far", "%.3f" % args.far),
                ],
                [],
            )
        touched += 1

    if args.off:
        print("removed the proximity fade from %d materials" % touched)
    else:
        print(
            "%d materials fade between %.3f m and %.3f m (props dithered, mode %d)"
            % (touched, args.near, args.far, DITHER)
        )


if __name__ == "__main__":
    main()
