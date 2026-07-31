#!/usr/bin/env python3
"""Checks that every stream feeding an AudioStreamPlayer3D is mono, and that no audio asset
has a dead channel.

    python3 tools/verify_audio_assets.py

Reported in play as hearing the coworkers' whispers "from the right ear, none from the left",
after they had already been fixed for coverage and then for volume. Neither the placement nor
the code was wrong this time - the ASSET was:

    susurro_loko.wav   stereo, left channel -inf dB, all content in the right

That is how it ships in the Unity project, and the port's Ogg conversion preserved it
faithfully. It was inaudible as a bug in Unity because Unity DOWNMIXES a spatialised source to
mono before panning it. Godot's AudioStreamPlayer3D does not: a stereo stream's channels go
out to the bus, so a silent left channel stays silent wherever the emitter is standing. Every
whisper in the level came from one ear.

So the rule below is not "no dead channels", it is the stronger and simpler one:

    a stream played through an AudioStreamPlayer3D must be MONO

because a stereo stream does not get positional panning at all - it merely happens to sound
acceptable when its two channels are identical. step.wav was exactly that case: dual mono,
channel difference peaking at -68 dB, so it sounded centred and correct while never actually
being spatialised. Both are mono now.

Non-3D players (music, UI) are exempt and may be stereo; this only walks the 3D ones. Needs
ffprobe and ffmpeg on PATH.
"""

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

## A channel this far below the file's loudest one is dead rather than quiet. -inf reads as a
## very large negative number, so any finite threshold catches it; 40 dB is chosen to also
## catch a channel that is merely bleed rather than silence.
DEAD_CHANNEL_DB = 40.0

EXT = re.compile(
    r'\[ext_resource type="AudioStream" (?:uid="[^"]*" )?path="res://([^"]+)"[^\]]*id="([^"]+)"'
)
NODE_3D = re.compile(r'\[node name="([^"]+)" type="AudioStreamPlayer3D"')
STREAM = re.compile(r'stream = ExtResource\("([^"]+)"\)')


def probe_channels(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "stream=channels",
         "-of", "json", str(path)],
        capture_output=True, text=True, check=True,
    )
    return json.loads(out.stdout)["streams"][0]["channels"]


def channel_rms(path, channel):
    """dB RMS of one channel; -inf comes back as -999.0 so callers can compare numerically."""
    out = subprocess.run(
        ["ffmpeg", "-hide_banner", "-i", str(path),
         "-af", "pan=mono|c0=c%d,astats" % channel, "-f", "null", "-"],
        capture_output=True, text=True,
    )
    for line in out.stderr.splitlines():
        if "RMS level dB" in line:
            value = line.split(":")[-1].strip()
            return -999.0 if value.lstrip("-").startswith("inf") else float(value)
    raise SystemExit("could not read the RMS of channel %d of %s" % (channel, path))


def streams_of_3d_players():
    """{res-relative audio path: [scene:node, ...]} for every AudioStreamPlayer3D found."""
    found = {}
    for scene in sorted((ROOT / "scenes").glob("*.tscn")):
        text = scene.read_text()
        by_id = {i: p for p, i in EXT.findall(text)}
        if not by_id:
            continue
        # Node blocks, in order, so a stream override can be tied back to its node.
        for block in re.split(r"(?=\[node )", text):
            node = NODE_3D.search(block)
            if node is None:
                continue
            stream = STREAM.search(block)
            # No override on the node means it inherits from an instanced scene, which is
            # checked where that scene declares it.
            if stream is None or stream.group(1) not in by_id:
                continue
            path = by_id[stream.group(1)]
            found.setdefault(path, []).append("%s:%s" % (scene.name, node.group(1)))
    return found


def main():
    players = streams_of_3d_players()
    if not players:
        raise SystemExit("found no AudioStreamPlayer3D with a stream; has the scene format changed?")

    failures = 0
    for rel, users in sorted(players.items()):
        path = ROOT / rel
        if not path.exists():
            print("  FAIL  %s is referenced by %s but does not exist" % (rel, ", ".join(users)))
            failures += 1
            continue

        channels = probe_channels(path)
        levels = [channel_rms(path, c) for c in range(channels)]

        if channels != 1:
            loudest = max(levels)
            dead = [c for c, db in enumerate(levels) if loudest - db >= DEAD_CHANNEL_DB]
            detail = " Channel(s) %s are dead, so that side is silent wherever the emitter is." % dead if dead else ""
            print("  FAIL  %s has %d channels and is played through a 3D emitter (%s)."
                  " Godot does not spatialise a stereo stream.%s"
                  " Convert with: ffmpeg -i in -af 'pan=mono|c0=c0' out"
                  % (rel, channels, ", ".join(users), detail))
            failures += 1
        else:
            print("  ok    %s is mono at %.1f dB RMS, used by %s"
                  % (rel, levels[0], ", ".join(users)))

    print("")
    if failures:
        print("FAIL: %d of %d 3D audio asset(s) failed" % (failures, len(players)))
    else:
        print("PASS: %d 3D audio asset(s)" % len(players))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
