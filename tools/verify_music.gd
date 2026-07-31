# Checks the level's background music: present, playing, looping, at a constant volume
# everywhere, and routed through the ported mixer.
#
#   godot-mono --headless --path . --script tools/verify_music.gd
#
# The requirement was "heard in the main level all the time at the same volume". Each half of
# that is a separate failure mode and both are checked:
#
#   all the time      the stream must LOOP. Godot imports .ogg with loop=false, so a clip that
#                     plays correctly for its first 68.4 s and then stops forever looks fine in
#                     any short test. This reads the imported stream's own loop flag rather
#                     than the .import file, so it cannot pass on a stale reimport.
#   the same volume   the node must be an AudioStreamPlayer, NOT an AudioStreamPlayer3D. A
#                     non-positional player has no attenuation and no panning by construction,
#                     which is stronger than measuring a flat level at sampled points. It also
#                     matches Unity, whose source had Spatialize 0 and a flat pan curve.
#
# The bus check exists because the mixer went in at the same time. Unity's ObsCourseMixer put
# Music at -5.21 dB, Fortunato at +20 and Ambience at -9.33, and the port had run with no buses
# at all until then - so the whisper level was tuned against footsteps 20 dB quieter than the
# original's. Asserting the bus levels here pins what that tuning is now relative to.
extends SceneTree

const LEVEL := "res://scenes/level.tscn"

## Metres. The music must not change level with distance, so it is sampled at the spawn and at
## the far end of the level; a positional player would differ hugely between the two.
const FAR_AWAY := Vector3(-13.0, 4.5, -155.0)

## From ObsCourseMixer.mixer's snapshot. Tolerance is generous because these are stored as
## 32-bit floats in Unity and re-serialised here.
const EXPECTED_BUSES := {
	"Master": 0.0,
	"Music": -5.205642,
	"Coworkers": 0.0,
	"Ambience": -9.332112,
	"Fortunato": 20.0,
}
const BUS_TOLERANCE_DB := 0.01

var frame := 0
var level: Node
var checks := 0
var failures := 0


func _process(_delta: float) -> bool:
	frame += 1
	if frame == 1:
		_check_buses()
		_check_routing()
		level = (load(LEVEL) as PackedScene).instantiate()
		root.add_child(level)
		return false
	if frame < 6:
		return false

	_check_present_and_playing()
	_check_loops()
	_check_constant_volume()

	print("")
	if failures == 0:
		print("PASS: %d checks" % checks)
	else:
		print("FAIL: %d of %d checks failed" % [failures, checks])
	quit(1 if failures > 0 else 0)
	return true


func _check_buses() -> void:
	checks += 1
	var problems: Array[String] = []
	for name in EXPECTED_BUSES:
		var index := AudioServer.get_bus_index(name)
		if index < 0:
			problems.append("%s is missing" % name)
			continue
		var actual := AudioServer.get_bus_volume_db(index)
		var want: float = EXPECTED_BUSES[name]
		if absf(actual - want) > BUS_TOLERANCE_DB:
			problems.append("%s is at %.3f dB, expected %.3f" % [name, actual, want])

	if problems.is_empty():
		_ok("all %d mixer buses match ObsCourseMixer's snapshot" % EXPECTED_BUSES.size())
	else:
		_fail("the bus layout does not match the Unity mixer: %s. Is default_bus_layout.tres at the project root?" % str(problems))


## Routing, checked from the scene files so it is a property of the artefacts. Nothing may sit
## on Master by accident - that was the state the whisper level got tuned in.
func _check_routing() -> void:
	checks += 1
	var want := {
		"res://scenes/whisper.tscn": "Coworkers",
		"res://scenes/player.tscn": "Fortunato",
	}
	var problems: Array[String] = []
	for path in want:
		var scene := (load(path) as PackedScene).instantiate()
		var players := _players_3d(scene)
		if players.is_empty():
			problems.append("%s has no 3D emitter" % path)
		for p in players:
			if String(p.bus) != want[path]:
				problems.append("%s/%s is on bus '%s', expected '%s'" % [
					path, p.name, p.bus, want[path]])
		scene.free()

	if problems.is_empty():
		_ok("the 3D emitters are routed to their Unity mixer groups, not left on Master")
	else:
		_fail("audio routing is wrong: %s" % str(problems))


func _music() -> Node:
	return level.get_node_or_null("Music")


func _check_present_and_playing() -> void:
	checks += 1
	var m := _music()
	if m == null:
		_fail("the level has no Music node")
		return
	if m is AudioStreamPlayer3D:
		_fail("Music is an AudioStreamPlayer3D, so its volume changes with the listener's position. Unity's source had Spatialize 0 and a flat pan curve - it must be a plain AudioStreamPlayer.")
		return
	if not (m is AudioStreamPlayer):
		_fail("Music is a %s, not an AudioStreamPlayer" % m.get_class())
		return

	var player := m as AudioStreamPlayer
	if player.stream == null:
		_fail("the Music node has no stream assigned")
	elif not player.autoplay:
		_fail("Music has autoplay off, so nothing starts it - the original's AudioSource had PlayOnAwake 1 and no script to start it")
	elif not player.playing:
		_fail("Music has autoplay on but is not playing after %d frames" % frame)
	elif String(player.bus) != "Music":
		_fail("Music plays on bus '%s' rather than the Music group" % player.bus)
	else:
		_ok("Music is a non-positional AudioStreamPlayer, autoplaying on the Music bus (%.1f s of audio)" % player.stream.get_length())


## Reads the flag off the IMPORTED stream, not the .import file, so an un-reimported change
## cannot pass this.
func _check_loops() -> void:
	checks += 1
	var m := _music() as AudioStreamPlayer
	if m == null or m.stream == null:
		_fail("no music stream to check for looping")
		return
	var stream := m.stream
	var loops: Variant = stream.get("loop")
	if loops == null:
		_fail("cannot read a loop flag off a %s" % stream.get_class())
	elif bool(loops):
		_ok("the music stream loops, so it carries past its %.1f s" % stream.get_length())
	else:
		_fail("the music stream does not loop: it will stop after %.1f s and never restart. Set loop=true in audio/guille_experimental.ogg.import and REIMPORT - Godot defaults .ogg to loop=false." % stream.get_length())


## "The same volume" - a non-positional player is unaffected by where the listener stands, so
## this moves the camera the length of the level and requires the mixed level to be identical.
func _check_constant_volume() -> void:
	checks += 1
	var m := _music() as AudioStreamPlayer
	var cam := level.get_node_or_null("Camera") as Camera3D
	if m == null or cam == null:
		_fail("cannot sample the music volume; Music or Camera is missing")
		return

	var at_spawn := m.volume_db
	cam.global_position = FAR_AWAY
	var far := m.volume_db

	if is_equal_approx(at_spawn, far):
		_ok("volume is %.2f dB at the spawn and at the far end of the level; the -5.21 dB sits on the bus" % at_spawn)
	else:
		_fail("volume changed from %.2f dB to %.2f dB when the listener moved %.0f m" % [
			at_spawn, far, FAR_AWAY.length()])


func _players_3d(n: Node) -> Array[AudioStreamPlayer3D]:
	var out: Array[AudioStreamPlayer3D] = []
	if n is AudioStreamPlayer3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_players_3d(c))
	return out


func _ok(m: String) -> void:
	print("  ok    ", m)


func _fail(m: String) -> void:
	failures += 1
	print("  FAIL  ", m)
