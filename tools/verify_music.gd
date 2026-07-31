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
##
## Fortunato is DELIBERATELY not Unity's +20 dB - see default_bus_layout.tres. At +20 the footstep
## arrived at +7.53 dBTP and clipped the master bus by 7.5 dB, so part of the original's footstep
## prominence was the transient being squared off and cannot be reproduced cleanly.
const EXPECTED_BUSES := {
	"Master": 0.0,
	"Music": -5.205642,
	"Coworkers": 0.0,
	"Ambience": -9.332112,
	"Fortunato": 9.5,
}
const BUS_TOLERANCE_DB := 0.01

## True peaks come from audio/audio_levels.json, which tools/verify_audio_assets.py measures with
## ffmpeg. Peak headroom cannot be computed in GDScript, and asserting numbers nobody measured is
## how the whisper shipped inaudible twice.
const LEVELS := "res://audio/audio_levels.json"

## Worst-case gain when all 13 whisper emitters sum at the loudest point on the player's route at
## full death constant, measured by tools/verify_whispers.gd. Held here so the headroom budget is
## explicit; if the whisper count or its unit_size growth changes, re-measure.
const WHISPER_SUM_GAIN_DB := 4.91

## Ceiling the master limiter is set to, and the budget every source has to fit under.
const MASTER_CEILING_DB := -0.5

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
	_check_no_source_clips()
	_check_master_limiter()

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


## The level's continuous 2D beds, checked identically because they ARE identical in kind: both are
## a GameObject in nivelEscena carrying only a Transform and an AudioSource, with PlayOnAwake 1,
## Loop 1, volume 1, Spatialize 0 and no script. Listed rather than discovered so that a bed going
## missing fails instead of silently reducing the number of things checked.
const BEDS := [
	{"node": "Music", "bus": "Music"},
	{"node": "Ambience", "bus": "Ambience"},
]


func _bed(name: String) -> Node:
	return level.get_node_or_null(name)


func _check_present_and_playing() -> void:
	for bed in BEDS:
		checks += 1
		_check_one_bed(String(bed["node"]), String(bed["bus"]))


func _check_one_bed(node_name: String, bus_name: String) -> void:
	var m := _bed(node_name)
	if m == null:
		_fail("the level has no %s node" % node_name)
		return
	if m is AudioStreamPlayer3D:
		_fail("%s is an AudioStreamPlayer3D, so its volume changes with the listener's position. Unity's source had Spatialize 0 and a flat pan curve - it must be a plain AudioStreamPlayer." % node_name)
		return
	if not (m is AudioStreamPlayer):
		_fail("%s is a %s, not an AudioStreamPlayer" % [node_name, m.get_class()])
		return

	var player := m as AudioStreamPlayer
	if player.stream == null:
		_fail("the %s node has no stream assigned" % node_name)
	elif not player.autoplay:
		_fail("%s has autoplay off, so nothing starts it - the original's AudioSource had PlayOnAwake 1 and no script to start it" % node_name)
	elif not player.playing:
		_fail("%s has autoplay on but is not playing after %d frames" % [node_name, frame])
	elif String(player.bus) != bus_name:
		_fail("%s plays on bus '%s' rather than the %s group" % [node_name, player.bus, bus_name])
	else:
		_ok("%s is a non-positional AudioStreamPlayer, autoplaying on the %s bus (%.1f s of audio)" % [
			node_name, bus_name, player.stream.get_length()])


## Reads the flag off the IMPORTED stream, not the .import file, so an un-reimported change
## cannot pass this.
func _check_loops() -> void:
	for bed in BEDS:
		checks += 1
		_check_one_loops(String(bed["node"]))


func _check_one_loops(node_name: String) -> void:
	var m := _bed(node_name) as AudioStreamPlayer
	if m == null or m.stream == null:
		_fail("no %s stream to check for looping" % node_name)
		return
	var stream := m.stream
	var loops: Variant = stream.get("loop")
	if loops == null:
		_fail("cannot read a loop flag off a %s" % stream.get_class())
	elif bool(loops):
		_ok("the %s stream loops, so it carries past its %.1f s" % [node_name, stream.get_length()])
	else:
		_fail("the %s stream does not loop: it will stop after %.1f s and never restart. Set loop=true in its .import and REIMPORT - Godot defaults .ogg to loop=false." % [
			node_name, stream.get_length()])


## "The same volume" - a non-positional player is unaffected by where the listener stands, so
## this moves the camera the length of the level and requires the mixed level to be identical.
func _check_constant_volume() -> void:
	checks += 1
	var m := _bed("Music") as AudioStreamPlayer
	var cam := level.get_node_or_null("Camera") as Camera3D
	if m == null or cam == null:
		_fail("cannot sample the music volume; Music or Camera is missing")
		return

	# RESTORED afterwards. An earlier version left the camera 159 m down the level, and
	# _check_no_source_clips then budgeted the footstep against a listener at the far end - it
	# reported -27.03 dBTP instead of -2.97 and passed on a meaningless number. Any check that
	# moves the world has to put it back, or it silently rewrites the ones after it.
	var was := cam.global_position
	var at_spawn := m.volume_db
	cam.global_position = FAR_AWAY
	var far := m.volume_db
	cam.global_position = was

	if is_equal_approx(at_spawn, far):
		_ok("volume is %.2f dB at the spawn and at the far end of the level; the -5.21 dB sits on the bus" % at_spawn)
	else:
		_fail("volume changed from %.2f dB to %.2f dB when the listener moved %.0f m" % [
			at_spawn, far, FAR_AWAY.length()])


func _levels() -> Dictionary:
	var f := FileAccess.open(LEVELS, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}


func _bus_db(bus_name: StringName) -> float:
	var index := AudioServer.get_bus_index(bus_name)
	return AudioServer.get_bus_volume_db(index) if index >= 0 else 0.0


## Reported in play as clipping footsteps. step.wav peaks at -12.47 dBTP, its Unity AudioSource
## volume is 1, and its emitter's unit_size of 10 against a camera 3.16 m away caps the distance
## attenuation at 1.0 - so Unity's +20 dB bus delivered +7.53 dBTP, 7.5 dB past the ceiling.
##
## This is an ASSET-TIMES-BUS property. Neither the file nor the bus is wrong on its own, which is
## why nothing caught it: verify_audio_assets checks the files, this file checked the bus levels,
## and the product of the two was nobody's business.
func _check_no_source_clips() -> void:
	checks += 1
	var levels := _levels()
	if levels.is_empty():
		_fail("%s is missing. Run: python3 tools/verify_audio_assets.py" % LEVELS)
		return

	# Each source's true peak once its node volume, its bus and its worst-case gain are applied.
	var peaks := {}

	var step := level.get_node_or_null("Player/StepSound") as AudioStreamPlayer3D
	if step != null and levels.has("audio/step.wav"):
		# unit_size 10 with the camera ~3 m away means attenuation is capped at 1.0, so the
		# footstep gets its full gain at the listener. Not an approximation - measured.
		var attenuation: float = minf(1.0, step.unit_size / maxf(
			(level.get_node("Camera") as Camera3D).global_position.distance_to(step.global_position), 0.001))
		peaks["footstep"] = float((levels["audio/step.wav"] as Dictionary)["true_peak_db"]) \
			+ step.volume_db + _bus_db(step.bus) + linear_to_db(attenuation)

	for pair in [["Music", "audio/guille_experimental.ogg"], ["Ambience", "audio/wind_ambience.ogg"]]:
		var bed := level.get_node_or_null(String(pair[0])) as AudioStreamPlayer
		if bed != null and levels.has(pair[1]):
			peaks[String(pair[0]).to_lower()] = float((levels[pair[1]] as Dictionary)["true_peak_db"]) \
				+ bed.volume_db + _bus_db(bed.bus)

	var whispers := level.get_node_or_null("Whispers")
	if whispers != null and levels.has("audio/susurro_loko.ogg"):
		var one := whispers.get_child(0) as AudioStreamPlayer3D
		# PeakVolumeDb, i.e. what the emitters reach at full death constant, plus the measured
		# worst-case summing of all 13 at the loudest point on the route.
		var peak_volume := float(one.get("PeakVolumeDb"))
		peaks["whispers"] = float((levels["audio/susurro_loko.ogg"] as Dictionary)["true_peak_db"]) \
			+ peak_volume + _bus_db(one.bus) + WHISPER_SUM_GAIN_DB

	if peaks.is_empty():
		_fail("could not find any of the level's audio sources to budget")
		return

	var over: Array[String] = []
	var power := 0.0
	var report: Array[String] = []
	for name in peaks:
		var db: float = peaks[name]
		power += db_to_linear(db) * db_to_linear(db)
		report.append("%s %+.2f" % [name, db])
		if db > MASTER_CEILING_DB:
			over.append("%s alone reaches %+.2f dBTP" % [name, db])
	var combined := linear_to_db(sqrt(power))

	if over.is_empty():
		_ok("no source clips: %s dBTP, combining to %+.2f in the pathological case where all peak at once (limiter ceiling %.1f)" % [
			", ".join(report), combined, MASTER_CEILING_DB])
	else:
		_fail(("a source exceeds the master ceiling on its own: %s (ceiling %.1f dBTP)." +
			" This is asset true peak times node volume times bus gain - check all three." +
			" Measured: %s") % [str(over), MASTER_CEILING_DB, ", ".join(report)])


## The limiter is a net, not a sound. It exists because three independent sources at their
## individual true peaks can still sum past the ceiling even when none of them clips alone.
func _check_master_limiter() -> void:
	checks += 1
	var master := AudioServer.get_bus_index("Master")
	if master < 0:
		_fail("there is no Master bus")
		return

	for i in AudioServer.get_bus_effect_count(master):
		var effect := AudioServer.get_bus_effect(master, i)
		if effect is AudioEffectHardLimiter:
			var ceiling := (effect as AudioEffectHardLimiter).ceiling_db
			if AudioServer.is_bus_effect_enabled(master, i) and ceiling <= 0.0:
				_ok("Master carries an enabled hard limiter at %.1f dB, so coincident peaks cannot clip" % ceiling)
			else:
				_fail("Master's hard limiter is disabled or its ceiling is %+.1f dB" % ceiling)
			return

	_fail("Master has no AudioEffectHardLimiter. Sources that are individually safe can still sum past 0 dBTP when their peaks coincide; see default_bus_layout.tres.")


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
