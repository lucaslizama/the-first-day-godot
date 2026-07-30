#!/usr/bin/env python3
"""Converts Unity's six-sided skybox into one equirectangular panorama for Godot.

    python3 tools/build_skybox_panorama.py <unity Assets/Textures/Skybox> <out.png> [width]

Unity's mat_skyboxFernandito uses the built-in Skybox/6 Sided shader (shader
fileID 104), which textures the inside of a cube with six separate images. Godot
has no six-sided sky material; PanoramaSkyMaterial takes one equirectangular
image, so the faces have to be resampled into that projection. Godot can also
import a cubemap from a strip, but that needs a custom sky shader and gets the
face order and per-face orientation wrong silently. A panorama is one function
whose output can be inspected and whose seams can be measured, which is why this
route was chosen.

Two mappings have to be right, and both are easy to get backwards.

Face assignment. Unity's inspector labels are Front [+Z], Back [-Z], Left [+X],
Right [-X], Up [+Y], Down [-Y] - note Left is +X, which reads wrong but is what
Unity means. The material then crosses the two horizontal images:

    _LeftTex  (Unity +X) = right.tif
    _RightTex (Unity -X) = left.tif
    _FrontTex (Unity +Z) = front.tif
    _BackTex  (Unity -Z) = back.tif
    _UpTex    (Unity +Y) = top.tif
    _DownTex  (Unity -Y) = bot.tif

Then the whole level - this sky included - is conjugated by M = diag(-1, 1, 1)
into Godot's space, which swaps the two horizontal faces back:

    Godot +X = left.tif     Godot +Y = top.tif     Godot +Z = front.tif
    Godot -X = right.tif    Godot -Y = bot.tif     Godot -Z = back.tif

So the filenames coincidentally match Godot's own axis naming, after being
crossed twice. Do not "simplify" this by dropping either swap - they are two
independent facts that happen to cancel.

Sampling uses the standard OpenGL cubemap face conventions. Rather than trust
that Unity's cube laid its UVs out the same way, --check measures colour
continuity across all eight vertical seams; a rotated or mirrored face shows up
as a large discontinuity there. The painting also gives visual invariants: the
horizon must be level and unbroken all the way round, buildings upright, and the
bright glow on +Z.

The tint is (0.5, 0.5, 0.5, 0.5) and the exposure 1, which for this shader means
neutral - 0.5 grey is its no-op tint - so no colour correction is applied here.
Rotation is 0.
"""

import os
import sys

import numpy as np
from PIL import Image

# Godot axis -> Unity's filename for that direction. See the docstring; this is
# the result of Unity's own face labelling plus the diag(-1, 1, 1) conjugation.
FACES = {
    "+x": "left.tif",
    "-x": "right.tif",
    "+y": "top.tif",
    "-y": "bot.tif",
    "+z": "front.tif",
    "-z": "back.tif",
}


def load_faces(folder):
    out = {}
    size = None
    for axis, filename in FACES.items():
        path = os.path.join(folder, filename)
        if not os.path.exists(path):
            sys.exit("missing face: %s" % path)
        img = Image.open(path).convert("RGB")
        if size is None:
            size = img.size
        elif img.size != size:
            sys.exit("faces differ in size: %s is %s, expected %s" % (filename, img.size, size))
        out[axis] = np.asarray(img, dtype=np.uint8)
    print("loaded 6 faces at %dx%d" % size)
    return out, size[0]


def sample(faces, face_size, dirs):
    """Sample the cube for an array of unit directions, shape (..., 3) -> (..., 3) RGB.

    NOT the OpenGL cubemap convention, which is the trap here. GL cubemap faces are
    defined as seen from OUTSIDE the cube; a skybox's faces are painted to be seen
    from INSIDE it. For the four side faces that is a horizontal mirror, so using the
    GL formulas directly produces a sky that is continuous but mirrored - and it
    measures as continuous, because seam continuity cannot see handedness. It has to
    be derived instead.

    Derivation. For an observer looking along f with up u, the right vector is
    r = cross(f, u). Check it against the one case Godot fixes for us: its camera
    looks along -Z with up +Y and +X to the right, and cross(-Z, +Y) = +X. Correct.
    So looking along +Z, right = cross(+Z, +Y) = -X: +X is on the observer's LEFT.

    Then for a direction d on the face, the image coordinates are the projections
    onto r and u, divided by the major axis:

        horizontal = d . r / |major|        vertical = d . u / |major|

    giving, with up = +Y for the four sides:

        +X: r = +Z    h =  z/|x|      -X: r = -Z    h = -z/|x|
        +Z: r = -X    h = -x/|z|      -Z: r = +X    h =  x/|z|

    all with v = y/|major|. Every one of those is the horizontal negation of the GL
    formula, which is exactly the inside/outside mirror.

    The two pole faces have no natural up vector, so their orientation is Unity's
    choice rather than something derivable. POLE_ORIENT holds it, found by measuring
    seam continuity against the already-derived side faces; see find_pole_orientation.
    """
    x, y, z = dirs[..., 0], dirs[..., 1], dirs[..., 2]
    ax, ay, az = np.abs(x), np.abs(y), np.abs(z)
    out = np.zeros(dirs.shape[:-1] + (3,), dtype=np.uint8)

    # (mask, face key, horizontal, vertical, major). Vertical is negated when turned
    # into a row index below, so that +Y ends up at the top of the image.
    cases = [
        ((ax >= ay) & (ax >= az) & (x > 0), "+x", lambda: z, lambda: y, lambda: ax),
        ((ax >= ay) & (ax >= az) & (x <= 0), "-x", lambda: -z, lambda: y, lambda: ax),
        ((ay > ax) & (ay >= az) & (y > 0), "+y", lambda: x, lambda: z, lambda: ay),
        ((ay > ax) & (ay >= az) & (y <= 0), "-y", lambda: x, lambda: -z, lambda: ay),
        ((az > ax) & (az > ay) & (z > 0), "+z", lambda: -x, lambda: y, lambda: az),
        ((az > ax) & (az > ay) & (z <= 0), "-z", lambda: x, lambda: y, lambda: az),
    ]

    for mask, key, h_fn, v_fn, major_fn in cases:
        if not mask.any():
            continue
        major = major_fn()[mask]
        h = h_fn()[mask] / major
        v = v_fn()[mask] / major
        # [-1, 1] -> pixel indices, clamped: Unity had wrapMode Clamp.
        px = np.clip(((h + 1.0) * 0.5 * face_size).astype(np.int32), 0, face_size - 1)
        py = np.clip(((1.0 - v) * 0.5 * face_size).astype(np.int32), 0, face_size - 1)
        out[mask] = faces[key][py, px]

    return out


# The eight ways an image can be laid on a square face.
ORIENTATIONS = {
    "as-is": lambda a: a,
    "rot90": lambda a: np.rot90(a, 1),
    "rot180": lambda a: np.rot90(a, 2),
    "rot270": lambda a: np.rot90(a, 3),
    "flip": lambda a: np.fliplr(a),
    "flip-rot90": lambda a: np.rot90(np.fliplr(a), 1),
    "flip-rot180": lambda a: np.rot90(np.fliplr(a), 2),
    "flip-rot270": lambda a: np.rot90(np.fliplr(a), 3),
}


def find_pole_orientation(faces, face_size, key, verbose=True):
    """Pick the orientation of a pole face by seam continuity against the sides.

    The side faces are derived, so they are the fixed reference. Each candidate is
    scored across the four seams where the pole face meets a side.
    """
    sign = 1.0 if key == "+y" else -1.0
    lat = sign * (np.pi / 4.0)
    lons = np.array([0.0, np.pi / 2.0, np.pi, -np.pi / 2.0])
    eps = 2e-3

    results = []
    for name, fn in ORIENTATIONS.items():
        trial = dict(faces)
        trial[key] = fn(faces[key])
        total = 0.0
        for lon in lons:
            a = _ring(trial, face_size, lon, np.array([lat - sign * eps]))
            b = _ring(trial, face_size, lon, np.array([lat + sign * eps]))
            total += float(np.mean(np.abs(a.astype(np.int32) - b.astype(np.int32))))
        results.append((total / len(lons), name))

    results.sort()
    if verbose:
        best, runner = results[0], results[1]
        print("  %s: %s (%.2f); next best %s (%.2f)"
              % (key, best[1], best[0], runner[1], runner[0]))
        if best[0] > 6.0:
            print("     no orientation fits well - this face may be near-featureless,")
            print("     in which case the choice is cosmetically irrelevant.")
    return results[0][1]


def build(faces, face_size, width):
    height = width // 2
    # Godot's PanoramaSkyMaterial: u wraps longitude, v is latitude from the top.
    lon = (np.arange(width, dtype=np.float64) + 0.5) / width * 2.0 * np.pi - np.pi
    lat = np.pi * 0.5 - (np.arange(height, dtype=np.float64) + 0.5) / height * np.pi
    lon, lat = np.meshgrid(lon, lat)

    cos_lat = np.cos(lat)
    dirs = np.stack([
        cos_lat * np.sin(lon),
        np.sin(lat),
        -cos_lat * np.cos(lon),
    ], axis=-1)

    return sample(faces, face_size, dirs)


def check_seams(faces, face_size):
    """Measure colour continuity across the eight vertical cube seams.

    A face that is rotated or mirrored relative to the convention above produces a
    large jump here, which a visual check can easily miss on soft painted art.
    """
    print("\nseam continuity (mean |difference| per channel, 0-255):")
    eps = 1e-4
    worst = 0.0
    for name, angle in [
        ("+z/+x", -np.pi / 4), ("+x/-z", -3 * np.pi / 4),
        ("-z/-x", 3 * np.pi / 4), ("-x/+z", np.pi / 4),
    ]:
        lat = np.linspace(-np.pi / 3, np.pi / 3, 400)
        for side, delta in [("before", -eps), ("after", eps)]:
            pass
        a = _ring(faces, face_size, angle - eps, lat)
        b = _ring(faces, face_size, angle + eps, lat)
        diff = float(np.mean(np.abs(a.astype(np.int32) - b.astype(np.int32))))
        worst = max(worst, diff)
        flag = "ok" if diff < 8.0 else "SUSPECT"
        print("  %-8s %6.2f  %s" % (name, diff, flag))
    print("  worst: %.2f" % worst)
    if worst >= 8.0:
        print("  A seam this visible means a face is rotated, mirrored or swapped.")
        print("  Check the face assignment in FACES and the conventions in sample().")
    return worst


def _ring(faces, face_size, lon, lat):
    cos_lat = np.cos(lat)
    dirs = np.stack([
        cos_lat * np.sin(np.full_like(lat, lon)),
        np.sin(lat),
        -cos_lat * np.cos(np.full_like(lat, lon)),
    ], axis=-1)
    return sample(faces, face_size, dirs)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__.strip().splitlines()[2].strip())
    folder, out = sys.argv[1], sys.argv[2]
    width = int(sys.argv[3]) if len(sys.argv) > 3 else 4096

    faces, face_size = load_faces(folder)

    print("\npole face orientation, by seam continuity against the derived sides:")
    for key in ("+y", "-y"):
        faces[key] = ORIENTATIONS[find_pole_orientation(faces, face_size, key)](faces[key])

    check_seams(faces, face_size)

    print("\nbuilding %dx%d panorama..." % (width, width // 2))
    Image.fromarray(build(faces, face_size, width)).save(out, optimize=True)
    print("wrote %s (%.2f MB)" % (out, os.path.getsize(out) / 1e6))


if __name__ == "__main__":
    main()
