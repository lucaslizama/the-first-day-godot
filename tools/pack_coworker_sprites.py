#!/usr/bin/env python3
"""Packs the coworkers' sprite frames into one atlas each, with a SpriteFrames.

Run from the Unity project's Assets directory:

    cd ../the-first-day-unity/Assets && python3 <repo>/tools/pack_coworker_sprites.py <repo>

Writes, for each of mono1 and mono2:

    textures/coworkers/<name>.png        the atlas
    textures/coworkers/<name>_frames.tres  a SpriteFrames over it

Frame order comes from the animation clip, not from the filenames. mono1_anim's
PPtr curve names 81 sprites and the Sprites folder holds 153 PNGs, so a third of
them are unused takes; and the used ones are split across two naming schemes
(mono1_00NN and Untitled-4NNNN), which do not interleave in filename order the way
the animation plays them. Reading the clip is the only way to get this right.

Why atlas rather than 151 imported PNGs: at 128x128 each, the frames are 19 MB of
individual textures in the Unity project, and Godot would import every one as its
own resource. Packed, the whole cast is two textures.

Each frame gets a transparent gutter so bilinear filtering cannot bleed one frame
into the next. The tool checks that no frame has non-transparent pixels on its
border, which is what makes the transparent gutter provably lossless here rather
than merely convenient.
"""

import json
import os
import re
import sys

from PIL import Image

CLIPS = {
    "mono1": "Prefabs/Coworkers/Mono 1/Animations/mono1_anim.anim",
    "mono2": "Prefabs/Coworkers/Mono 2/Animations/mono2_anim.anim",
}

## Unity's m_SampleRate on both clips.
FPS = 30

## Transparent pixels between frames, so filtering cannot sample a neighbour.
GUTTER = 2


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


def clip_frames(path, guids):
    """Ordered (time, png path) for a clip's m_Sprite PPtr curve."""
    text = open(path, errors="ignore").read()
    keys = re.findall(
        r"- time: ([-\d.eE+]+)\s*\n\s*value: \{fileID: \d+, guid: (\w+), type: \d+\}", text
    )
    if not keys:
        sys.exit("%s: no PPtr keys found" % path)
    out = []
    for t, guid in keys:
        src = guids.get(guid)
        if src is None:
            sys.exit("%s: sprite guid %s resolves to no asset" % (path, guid))
        out.append((float(t), src))
    return out


def check_spacing(frames, label):
    """The clip must be an even 1/30 s flipbook for a SpriteFrames speed to match."""
    step = 1.0 / FPS
    for i in range(1, len(frames)):
        gap = frames[i][0] - frames[i - 1][0]
        if abs(gap - step) > 1e-4:
            sys.exit(
                "%s: frame %d is %.5f s after the previous, not %.5f. The clip is not "
                "an even flipbook and cannot be a SpriteFrames at a single speed."
                % (label, i, gap, step)
            )


def pack(name, frames, out_dir):
    images = [Image.open(src).convert("RGBA") for _, src in frames]
    w, h = images[0].size
    for img, (_, src) in zip(images, frames):
        if img.size != (w, h):
            sys.exit("%s: %s is %s, expected %s" % (name, src, img.size, (w, h)))

    border = 0
    for img in images:
        px = img.load()
        for x in range(w):
            border = max(border, px[x, 0][3], px[x, h - 1][3])
        for y in range(h):
            border = max(border, px[0, y][3], px[w - 1, y][3])

    cols = int(len(images) ** 0.5 + 0.999999)
    rows = (len(images) + cols - 1) // cols
    cell_w, cell_h = w + GUTTER * 2, h + GUTTER * 2
    atlas = Image.new("RGBA", (cols * cell_w, rows * cell_h), (0, 0, 0, 0))

    regions = []
    for i, img in enumerate(images):
        cx, cy = (i % cols) * cell_w + GUTTER, (i // cols) * cell_h + GUTTER
        atlas.paste(img, (cx, cy))
        regions.append((cx, cy, w, h))

    os.makedirs(out_dir, exist_ok=True)
    png = os.path.join(out_dir, "%s.png" % name)
    atlas.save(png)

    tres = os.path.join(out_dir, "%s_frames.tres" % name)
    # No ';' header: comments in a .tres do not survive an editor save or any
    # ResourceSaver.save(). The frame count, rate and source clip are reported to stdout
    # instead, and the atlas conventions are in docs/level-port-scope.md. See CLAUDE.md.
    lines = [
        '[gd_resource type="SpriteFrames" load_steps=%d format=3]' % (len(regions) + 2),
        "",
        '[ext_resource type="Texture2D" path="res://textures/coworkers/%s.png" id="1_atlas"]'
        % name,
        "",
    ]
    for i, (x, y, rw, rh) in enumerate(regions):
        lines += [
            '[sub_resource type="AtlasTexture" id="frame_%03d"]' % i,
            'atlas = ExtResource("1_atlas")',
            "region = Rect2(%d, %d, %d, %d)" % (x, y, rw, rh),
            "",
        ]
    entries = ", ".join(
        '{\n"duration": 1.0,\n"texture": SubResource("frame_%03d")\n}' % i
        for i in range(len(regions))
    )
    lines += [
        "[resource]",
        "animations = [{",
        '"frames": [%s],' % entries,
        '"loop": true,',
        '"name": &"default",',
        '"speed": %.1f' % FPS,
        "}]",
        "",
    ]
    open(tres, "w").write("\n".join(lines))

    return {
        "name": name,
        "frames": len(regions),
        "atlas": "%dx%d" % atlas.size,
        "cell": "%dx%d" % (w, h),
        "grid": "%dx%d" % (cols, rows),
        "seconds": round(len(regions) / FPS, 4),
        "border_alpha": border,
        "sources": len({src for _, src in frames}),
    }


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: pack_coworker_sprites.py <godot-repo-root>")
    repo = sys.argv[1]
    out_dir = os.path.join(repo, "textures", "coworkers")

    guids = guid_map()
    for name, clip in CLIPS.items():
        frames = clip_frames(clip, guids)
        check_spacing(frames, name)
        info = pack(name, frames, out_dir)

        folder = os.path.dirname(clip).replace("/Animations", "/Sprites")
        available = len([f for f in os.listdir(folder) if f.endswith(".png")])
        print(
            "%s: %d frames (%d distinct of %d PNGs available) -> %s atlas, %s grid of %s, %.4f s"
            % (
                info["name"], info["frames"], info["sources"], available,
                info["atlas"], info["grid"], info["cell"], info["seconds"],
            )
        )
        if info["border_alpha"] != 0:
            print(
                "   WARNING: a frame has alpha %d on its border, so the transparent "
                "gutter will fade its edge." % info["border_alpha"]
            )
        else:
            print("   no frame touches its border; the gutter is lossless")


if __name__ == "__main__":
    main()
