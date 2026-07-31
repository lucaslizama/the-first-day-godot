# Checks the coworkers' whispers: every coworker covered, both sides of the level, and the
# audio kept out of the coworkers scene.
#
#   godot-mono --headless --path . --script tools/verify_whispers.gd
#
# Reported in play as missing audio from the coworkers on the left-hand side of the level.
# Measured over the 74 placed coworkers, with the emitters still living in coworkers.tscn:
#
#     side               coworkers   emitters   mean unit_size/distance to the nearest
#     negative x (left)      25          0                0.53
#     positive x (right)     49          7               46.1
#
# All seven emitters were at positive x. The 25 on the left had nothing nearer than 90 m, so
# what whisper they got was a distant wash rather than the sound of the people in front of
# them. Cause: tools/extract_coworkers.py only looks for an AudioSource on a coworker GROUP
# ROOT, and the groups it found were all on one side.
#
# The emitters are now clustered from our own coworker placement by
# tools/generate_whispers_scene.py, so coverage follows where the coworkers actually are.
#
# The check that matters most is the last one. These emitters are SILENT at level start by
# design - WhisperEmitter takes its volume from GameManager's death constant, which is 0
# until the player dies - so "no whisper is audible" is the correct state most of the time,
# and a genuinely broken emitter is indistinguishable from a working one by listening at
# spawn. It therefore drives the death constant and requires the volume to follow.
extends SceneTree

const COWORKERS := "res://scenes/coworkers.tscn"
const WHISPERS := "res://scenes/whispers.tscn"
const LEVEL := "res://scenes/level.tscn"

## Metres. No coworker may be further than this from the nearest emitter. The generator's
## default 18 m clustering achieves 13.0 m, so this has headroom without being vacuous - it
## is well under the 90 m the left-hand side used to suffer.
const MAX_GAP := 30.0

## Neither side may hold less than this share of the emitters. The bug was 0 of 7 on one
## side; a 1-in-4 floor would have caught it while leaving the clustering free to be uneven,
## which it legitimately is - the coworkers are not symmetrically placed.
const MIN_SIDE_SHARE := 0.25

const SILENCE_DB := -80.0

## Route audibility, the property that broke on the FIRST attempt at this fix and that no
## check here covered. Coverage of the coworkers and audibility to the player are different
## things: clustering at 18 m put an emitter within 13 m of every coworker and was audible on
## only 3 of 28 route points, because unit_size comes from the cluster extent and small
## clusters are quiet. Sampled over the platform tops plus the spawn and the end of the level,
## taking the loudest emitter at each point:
##
##     the original 7 emitters      mean 0.610    21 / 28 above 0.5
##     18 m radius (the mistake)    mean 0.431     3 / 28
##     25 m radius (current)        mean 0.707    27 / 28
##
## The bounds are "at least as good as the original", which the mistake fails on both counts.
const MIN_ROUTE_MEAN := 0.55
const MIN_ROUTE_AUDIBLE_SHARE := 0.7
const AUDIBLE := 0.5

var frame := 0
var level: Node3D
var checks := 0
var failures := 0
var coworkers: Array[Vector3] = []
var emitters: Array[Dictionary] = []


func _process(_delta: float) -> bool:
	frame += 1
	if frame == 1:
		_load_positions()
		_check_coverage()
		_check_both_sides()
		_check_unit_sizes()
		_check_separation()
		_check_route_audibility()
		level = (load(LEVEL) as PackedScene).instantiate()
		root.add_child(level)
		return false
	if frame < 5:
		return false

	_check_in_level()
	_check_becomes_audible()
	_check_audible_while_dying()

	print("")
	if failures == 0:
		print("PASS: %d checks" % checks)
	else:
		print("FAIL: %d of %d checks failed" % [failures, checks])
	quit(1 if failures > 0 else 0)
	return true


## Read from the scenes directly, not from the live level, so the two scenes are checked as
## the artefacts they are.
func _load_positions() -> void:
	var cw := (load(COWORKERS) as PackedScene).instantiate()
	for c in cw.get_children():
		coworkers.append((c as Node3D).position)
	cw.free()

	var wh := (load(WHISPERS) as PackedScene).instantiate()
	for c in wh.get_children():
		emitters.append({
			"name": String(c.name),
			"pos": (c as Node3D).position,
			"unit": float(c.get("MinDistance")),
			"grown": float(c.get("MaxMinDistance")),
		})
	wh.free()


func _check_coverage() -> void:
	checks += 1
	if coworkers.is_empty() or emitters.is_empty():
		_fail("found %d coworkers and %d emitters; something is not loading" % [
			coworkers.size(), emitters.size()])
		return

	var worst := 0.0
	var stranded := 0
	for p in coworkers:
		var nearest := INF
		for e in emitters:
			nearest = minf(nearest, p.distance_to(e["pos"] as Vector3))
		worst = maxf(worst, nearest)
		if nearest > MAX_GAP:
			stranded += 1

	if stranded == 0:
		_ok("all %d coworkers are within %.1f m of an emitter (worst %.1f m, limit %.0f)" % [
			coworkers.size(), worst, worst, MAX_GAP])
	else:
		_fail("%d of %d coworkers have no emitter within %.0f m (worst %.1f m). Regenerate with tools/generate_whispers_scene.py, or lower its --radius." % [
			stranded, coworkers.size(), MAX_GAP, worst])


## The actual bug: emitters all on one side of the level.
func _check_both_sides() -> void:
	checks += 1
	var left := 0
	for e in emitters:
		if (e["pos"] as Vector3).x < 0.0:
			left += 1
	var right := emitters.size() - left
	var share := float(mini(left, right)) / float(emitters.size())

	if share >= MIN_SIDE_SHARE:
		_ok("emitters are on both sides: %d at negative x, %d at positive (%.0f%% on the thinner side)" % [
			left, right, share * 100.0])
	else:
		_fail("%d emitters at negative x and %d at positive - one side of the level is starved, which is the bug this exists for" % [
			left, right])


## An emitter whose unit_size is smaller than its own cluster cannot be heard properly by
## someone standing at the edge of that cluster.
func _check_unit_sizes() -> void:
	checks += 1
	var problems: Array[String] = []
	for e in emitters:
		if e["unit"] <= 0.0:
			problems.append("%s has unit_size %.2f" % [e["name"], e["unit"]])
		elif e["grown"] < e["unit"]:
			problems.append("%s grows from %.1f to %.1f, which shrinks it" % [
				e["name"], e["unit"], e["grown"]])
	if problems.is_empty():
		_ok("all %d emitters have a positive unit_size that grows with the death constant" % emitters.size())
	else:
		_fail("emitter attenuation is wrong: %s" % str(problems))


## Godot's ATTENUATION_INVERSE_DISTANCE is unit_size / distance, capped at unattenuated.
func _attenuation_at(p: Vector3) -> float:
	var best := 0.0
	for e in emitters:
		var d: float = p.distance_to(e["pos"] as Vector3)
		best = maxf(best, minf(1.0, float(e["unit"]) / maxf(d, 0.001)))
	return best


## Where the player actually goes: the platform tops, the spawn, and the end of the level.
func _route() -> Array[Vector3]:
	var out: Array[Vector3] = []
	var plats := (load("res://scenes/platforms.tscn") as PackedScene).instantiate()
	for c in plats.get_children():
		out.append((c as Node3D).position + Vector3(0.0, 1.5, 0.0))
	plats.free()
	out.append(Vector3(0.0, 1.5, 4.018))
	out.append(Vector3(-13.0, 4.5, -155.0))
	return out


func _check_route_audibility() -> void:
	checks += 1
	var route := _route()
	if route.is_empty():
		_fail("could not build a route to sample; platforms.tscn gave no children")
		return

	var total := 0.0
	var audible := 0
	var worst := INF
	for p in route:
		var a := _attenuation_at(p)
		total += a
		worst = minf(worst, a)
		if a >= AUDIBLE:
			audible += 1
	var mean := total / float(route.size())
	var share := float(audible) / float(route.size())

	if mean >= MIN_ROUTE_MEAN and share >= MIN_ROUTE_AUDIBLE_SHARE:
		_ok("audible along the route: mean %.3f over %d points, %d of them at or above %.1f (quietest %.3f)" % [
			mean, route.size(), audible, AUDIBLE, worst])
	else:
		_fail("the whispers do not carry: mean %.3f (need %.2f) and %d of %d points at or above %.1f (need %d%%). unit_size comes from the cluster extent, so a SMALLER --radius makes them quieter as well as more numerous." % [
			mean, MIN_ROUTE_MEAN, audible, route.size(), AUDIBLE, int(MIN_ROUTE_AUDIBLE_SHARE * 100.0)])


## What the user asked for: the audio is not part of the coworkers scene any more.
func _check_separation() -> void:
	checks += 1
	var cw := (load(COWORKERS) as PackedScene).instantiate()
	var players := _audio_nodes(cw)
	cw.free()
	if players.is_empty():
		_ok("coworkers.tscn holds no audio nodes; the whispers are their own scene")
	else:
		_fail("coworkers.tscn still contains %d audio node(s): %s" % [players.size(), str(players)])


## Scoped to the Whispers subtree, NOT every AudioStreamPlayer3D in the level. An earlier
## version counted all of them and picked up the player's own StepSound, which is a 16th
## player that is correctly audible with no deaths - so it reported two failures that were
## both the check's fault rather than the feature's.
func _check_in_level() -> void:
	checks += 1
	var found := _audio_nodes(_whispers_root())
	if found.size() == emitters.size():
		_ok("the level instances all %d emitters" % found.size())
	else:
		_fail("the level has %d emitters but whispers.tscn defines %d; is Whispers instanced in level.tscn?" % [
			found.size(), emitters.size()])


## Drives the real signal rather than poking the players, so the wiring is covered too.
func _check_becomes_audible() -> void:
	checks += 1
	var nodes := _audio_players(_whispers_root())
	if nodes.is_empty():
		_fail("no emitters in the level to test")
		return

	var silent_at_start := 0
	for n in nodes:
		if n.volume_db <= SILENCE_DB + 0.001:
			silent_at_start += 1

	# Ten deaths is Max_Meaningful_Deaths, where the death constant reaches 1.
	var target = _game_manager()
	if target == null:
		_fail("cannot reach the GameManager autoload, so the death constant cannot be driven")
		return
	for i in 10:
		target.call("AddDeath")

	var audible := 0
	for n in nodes:
		if n.volume_db > SILENCE_DB + 0.001:
			audible += 1

	if silent_at_start == nodes.size() and audible == nodes.size():
		_ok("all %d emitters are silent at 0 deaths and audible at 10, following the death constant" % nodes.size())
	elif silent_at_start != nodes.size():
		_fail("%d of %d emitters are already audible with no deaths; the whisper is meant to arrive with dying" % [
			nodes.size() - silent_at_start, nodes.size()])
	else:
		_fail("only %d of %d emitters became audible after 10 deaths; the rest never respond to the death constant" % [
			audible, nodes.size()])


## Reported in play as "not hearing the whispers really well", with every check above
## passing. Two blind spots, and this one check closes both:
##
##   * _check_route_audibility models GEOMETRIC ATTENUATION ONLY and ignores volume_db, so a
##     whisper turned down to a whisper of a whisper scored a perfect 0.707.
##   * _check_becomes_audible tests 0 deaths and 10 deaths - the two ENDPOINTS. Ordinary play
##     produces one to four deaths, so every death count a player actually reaches went
##     untested.
##
## The bug that hid in the gap: volume came from Mathf.LinearToDb(deathConstant) and the
## constant is deaths / 10, so the first death played at 0.1 amplitude, -20 dB, while the
## player's own footsteps play at 0 dB in their ear. Full volume existed only at ten deaths.
##
## So this walks the death count up one at a time and reads volume_db and unit_size back OFF
## THE LIVE NODES rather than re-deriving them. Re-implementing the formula here is what makes
## a check drift away from the code it is checking - and this file has already been wrong
## twice that way.
## Effective dB required at the FIRST death, averaged over the route, measured against FULL
## SCALE. The old curve managed about -23 dB here; the current one about -12, which is the level
## that was settled on by listening.
##
## It used to be phrased "against the footsteps at 0 dB", which stopped being true the moment
## the Unity mixer was ported: StepSound now runs through the Fortunato bus at +20 dB, so the
## footsteps are a moving target and referencing them would make this bound drift with a mixer
## change it has no opinion about. Full scale does not move.
##
## Worth knowing while reading the numbers below: the whispers are on the Coworkers bus at 0 dB
## and so sit about 20 dB under the footsteps. That is what the original's mix was, chosen
## deliberately - see default_bus_layout.tres. If it wants changing, change the bus.
const MIN_FIRST_DEATH_DB := -16.0

## The escalation has to be real. Unity's own was minDistance 40 -> 45, a 12% change that is
## essentially inaudible, so "it grows" is not enough - it has to grow audibly.
const MIN_ESCALATION_DB := 8.0


func _check_audible_while_dying() -> void:
	checks += 1
	var nodes := _audio_players(_whispers_root())
	var route := _route()
	if nodes.is_empty() or route.is_empty():
		_fail("no emitters or no route to sample")
		return

	var gm: Variant = _game_manager()
	if gm == null:
		_fail("cannot reach the GameManager autoload, so the death constant cannot be driven")
		return
	gm.call("ResetDeaths")

	var curve: Array[float] = []
	for deaths in range(1, 11):
		gm.call("AddDeath")
		var total := 0.0
		for p in route:
			var best := 0.0
			for n in nodes:
				var d: float = p.distance_to(n.global_position)
				var attenuation := minf(1.0, n.unit_size / maxf(d, 0.001))
				best = maxf(best, db_to_linear(n.volume_db) * attenuation)
			total += best
		curve.append(linear_to_db(total / float(route.size())))

	var first := curve[0]
	var last := curve[curve.size() - 1]
	var escalation := last - first

	if first >= MIN_FIRST_DEATH_DB and escalation >= MIN_ESCALATION_DB:
		_ok("audible from the first death: %.1f dB at 1 death rising to %.1f dB at 10 (%.1f dB of escalation), below full scale" % [
			first, last, escalation])
	elif first < MIN_FIRST_DEATH_DB:
		_fail("the whisper is inaudible while dying: %.1f dB below full scale, averaged over the route at ONE death (need %.1f). Volume must ramp in dB from an audible onset, not from a linear amplitude of deaths/10." % [
			first, MIN_FIRST_DEATH_DB])
	else:
		_fail("the whisper does not escalate: %.1f dB at 1 death and %.1f dB at 10, only %.1f dB apart (need %.1f). An escalation nobody can hear is not one." % [
			first, last, escalation, MIN_ESCALATION_DB])


func _game_manager():
	if Engine.has_singleton("GameManager"):
		return Engine.get_singleton("GameManager")
	return root.get_node_or_null("/root/GameManager")


## The instanced whispers.tscn inside the level, or the level itself if it is missing - which
## makes _check_in_level report 0 emitters rather than crashing.
func _whispers_root() -> Node:
	var w := level.get_node_or_null("Whispers")
	return w if w != null else Node.new()


func _audio_nodes(n: Node) -> Array[String]:
	var out: Array[String] = []
	if n is AudioStreamPlayer3D or n is AudioStreamPlayer:
		out.append(String(n.name))
	for c in n.get_children():
		out.append_array(_audio_nodes(c))
	return out


func _audio_players(n: Node) -> Array[AudioStreamPlayer3D]:
	var out: Array[AudioStreamPlayer3D] = []
	if n is AudioStreamPlayer3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_audio_players(c))
	return out


func _ok(m: String) -> void:
	print("  ok    ", m)


func _fail(m: String) -> void:
	failures += 1
	print("  FAIL  ", m)
