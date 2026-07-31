extends SceneTree
## Checks the coworker placement against the level geometry, independently of the
## extraction that produced it, and then checks the whisper emitters (now in their own
## scene, scenes/whispers.tscn - see tools/verify_whispers.gd for their coverage) respond to the
## death constant.
##
## The extraction has to compose three transforms - the scene instance, the group
## prefab's internal hierarchy, and the coworker's own - and a mistake in that chain
## produces coordinates that still look reasonable in a JSON file. An earlier
## version of the extractor double-counted the prefab root and put coworkers at
## x = -106 in a level that spans -59 to 67; the numbers alone did not give it away.
##
## So this asks the level instead: drop a ray from each coworker and measure the gap
## between its feet and whatever it is standing on. Coworkers standing on floors is
## not something a wrong transform chain produces by accident.
##
## The feet are the origin, not 0.64 m below it: the frames the animation uses were
## imported with alignment: 7, BottomCenter, so a coworker's Unity position is where
## its feet are. The scenes reproduce that with offset = (0, 64).
##
## Rays start half a metre above the origin rather than at it. The level's floors are
## thin slabs and a coworker standing on one has its origin flush with the top face;
## a ray fired from exactly there, or from below it, reports no hit at all - which is
## how this check first concluded that 72 of 74 coworkers were floating in the void.
##
## CORRECTION. This said "only ten of the 74 have any collision geometry beneath
## them", explained it as background silhouettes standing in open space, and asserted
## that "turning on backface_collision for all 53 trimeshes changes nothing, so this
## is not one-sided collision hiding floors". Both halves were wrong, and they had two
## separate causes:
##
##   * The placements were mirrored on X. Fixed by conjugating every world transform;
##     see the placement convention section of docs/level-port-scope.md.
##   * One-sided collision really was hiding the floors. This script never actually
##     set backface_collision - the claim that it changes nothing was never tested in
##     code. Setting it, as _enable_backfaces below now does, takes the count with
##     nothing beneath them from 24 to 1.
##
## So the alarming raycast result was right twice over and the reassuring explanation
## was wrong twice over. Visually confirmed afterwards: every coworker stands on or
## above visible scenery. A support probe measures collision coverage as much as it
## measures placement - do not let it argue that the level is fine, and do not let a
## rationalisation stand in for setting the flag and re-running.
##
## The evidence that the placement is nevertheless right is the precision of the ones
## that do land: three sit at a gap of exactly 0.0000 m on floor planes and three more
## at 0.0453 m. Exact alignment on independent coworkers is not something a wrong
## coordinate frame, a wrong pivot, or a mis-composed group hierarchy produces - each
## of those shifts everything by some amount, and no amount is zero.
##
## The split by kind matters too: direct instances and group children ground at the
## same low rate, which is what ruled out the group composition when this first
## looked alarming.
##
## Run: godot-mono --headless --script tools/verify_coworkers.gd

## How far above the origin to start each ray, to clear the slab it stands on.
const RAY_LIFT := 0.5

## A coworker whose feet are within this of the surface below counts as standing.
const TOLERANCE := 0.35

const RAY_LENGTH := 120.0

var _frames := 0
var _ticks := 0
var _level: Node3D
var _done := false

func _process(_d: float) -> bool:
	_frames += 1
	if _frames == 4:
		_level = (load("res://scenes/level.tscn") as PackedScene).instantiate()
		root.add_child(_level)
	return false

func _physics_process(_d: float) -> bool:
	if _level == null or _done:
		return false
	# Several ticks, not one. LevelShell builds the collision bodies in _Ready, but
	# the physics server only knows about them after it has stepped; querying too
	# early returns no hit for every ray, which reads exactly like 74 coworkers
	# floating in the void.
	_ticks += 1
	if _ticks < 10:
		return false
	_done = true
	_report()
	_report_whispers()
	quit()
	return true

## Trimesh shapes are one-sided by default, so a floor whose triangles wind away from
## a downward ray reports nothing and a correctly placed coworker scores as floating.
## This is not cosmetic: it was the whole of the "most of them have nothing beneath
## them" result.
func _enable_backfaces(node: Node) -> int:
	var n := 0
	if node is CollisionShape3D:
		var shape := (node as CollisionShape3D).shape
		if shape is ConcavePolygonShape3D:
			(shape as ConcavePolygonShape3D).backface_collision = true
			n += 1
	for child in node.get_children():
		n += _enable_backfaces(child)
	return n


func _report() -> void:
	var space := _level.get_viewport().find_world_3d().direct_space_state
	print("two-sided collision enabled on %d trimeshes before probing" % _enable_backfaces(_level))
	var standing := 0
	var flush := 0
	var floating: Array[String] = []
	var nothing: Array[String] = []
	var worst := 0.0
	var worst_name := ""

	# Sprites only. The whisper emitters used to share this parent; they are their own
	# scene now, so this filter is belt and braces rather than load-bearing.
	var coworkers: Array[Node] = []
	for child in _level.get_node("Coworkers").get_children():
		if child is AnimatedSprite3D:
			coworkers.append(child)

	for c in coworkers:
		var node: Node3D = c
		var feet: float = node.global_position.y
		var from := Vector3(node.global_position.x, feet + RAY_LIFT, node.global_position.z)
		var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * RAY_LENGTH)
		var hit := space.intersect_ray(query)

		if hit.is_empty():
			nothing.append("%s at (%.1f, %.1f, %.1f)" % [
				node.name, node.global_position.x, node.global_position.y, node.global_position.z,
			])
			continue

		var gap: float = feet - (hit["position"] as Vector3).y
		if absf(gap) <= TOLERANCE:
			standing += 1
			if absf(gap) < 0.02:
				flush += 1
		else:
			floating.append("%s %+.2f m" % [node.name, gap])
		if absf(gap) > absf(worst):
			worst = gap
			worst_name = String(node.name)

	print("coworkers: %d total" % coworkers.size())
	print("  standing on a surface (within %.2f m): %d" % [TOLERANCE, standing])
	print("    of those, flush within 2 cm:        %d" % flush)
	print("  off the surface below them:           %d" % floating.size())
	print("  no collision geometry beneath at all: %d" % nothing.size())
	print("  worst gap among those with a surface: %s %+.2f m" % [worst_name, worst])
	for f in floating.slice(0, 12):
		print("     off:  ", f)
	for f in nothing.slice(0, 8):
		print("     void: ", f)

	# Deliberately not a pass/fail assertion: most of these coworkers are background
	# figures with nothing under them by design, so a "how many are grounded" score
	# would fail a correct port. The signal is the flush count - see the header.
	if flush > 0:
		print("  placement corroborated: %d coworkers land exactly on a floor plane" % flush)
	else:
		print("  WARNING: not one coworker lands flush on a floor. With 74 of them and")
		print("           several known to stand on floors in the original, that points at")
		print("           the transform chain, the sprite pivot, or the level's offset.")

## The whisper emitters: that they loop, that they are staggered rather than in
## lockstep, that each cluster kept its own attenuation, and that both the radius and
## the volume follow the death constant. The last part is what Unity only half did -
## it set the volume once - so it is the part most worth having a check on.
func _report_whispers() -> void:
	# Under Whispers, not Coworkers: the emitters moved into scenes/whispers.tscn, because
	# they are derived coverage over the coworkers rather than part of their placement. This
	# check looked under Coworkers and reported "no whisper emitters in the level" once they
	# moved, which was stale rather than a real finding.
	var emitters: Array[AudioStreamPlayer3D] = []
	var host := _level.get_node_or_null("Whispers")
	if host == null:
		printerr("FAIL: level.tscn has no Whispers node; is scenes/whispers.tscn instanced?")
		return
	for c in host.get_children():
		if c is AudioStreamPlayer3D:
			emitters.append(c)

	print("whispers: %d emitters" % emitters.size())
	if emitters.is_empty():
		printerr("FAIL: no whisper emitters in the level.")
		return

	var silent := 0
	var positions: Array[String] = []
	for e in emitters:
		if not e.playing:
			silent += 1
		positions.append("%.1f" % e.get_playback_position())
	print("  looping: %s" % emitters[0].stream.loop)
	print("  start positions: %s" % ", ".join(positions))
	if silent > 0:
		printerr("FAIL: %d emitters are not playing. If the stream does not loop, one that" % silent)
		printerr("      starts near the end of the clip stops within a frame or two.")

	var by_setting := {}
	for e in emitters:
		var key := "%.0f/%.0f" % [e.MinDistance, e.MaxMinDistance]
		by_setting[key] = int(by_setting.get(key, 0)) + 1
	print("  per-cluster attenuation, unit_size/grown (sized from each cluster, NOT Unity's inconsistent 1/10 and 40/45): %s" % by_setting)

	var manager: Node = root.get_node_or_null("GameManager")
	if manager == null:
		printerr("FAIL: no GameManager autoload, so the death response cannot be checked.")
		return

	var sample := emitters[0]
	var before := Vector2(sample.unit_size, sample.volume_db)
	for i in GameManager_MAX_DEATHS:
		manager.AddDeath()
	var after := Vector2(sample.unit_size, sample.volume_db)
	print("  %s at 0 deaths: unit_size=%.2f volume_db=%.2f" % [sample.name, before.x, before.y])
	print("  %s at %d deaths: unit_size=%.2f volume_db=%.2f (linear %.2f)" % [
		sample.name, GameManager_MAX_DEATHS, after.x, after.y, db_to_linear(after.y),
	])
	# The volume maximum is PeakVolumeDb, READ OFF THE NODE, not 0 dB. This used to assert a
	# linear volume of 1.0 and went stale when the curve gained a ceiling: 13 emitters sum to
	# +4.9 dB at the worst point on the route and the clip peaks at -0.9 dBTP, so full volume
	# would drive the master limiter. Hardcoding the old maximum here made a deliberate change
	# look like a regression - see WhisperEmitter.PeakVolumeDb.
	var peak_volume := float(sample.get("PeakVolumeDb"))
	if after.x <= before.x or after.y <= before.y:
		printerr("FAIL: the whisper did not close in as deaths accumulated.")
	elif absf(sample.unit_size - sample.MaxMinDistance) > 0.01:
		printerr("FAIL: at full deaths the radius should reach MaxMinDistance (%.2f), not %.2f." % [
			sample.MaxMinDistance, sample.unit_size])
	elif absf(after.y - peak_volume) > 0.01:
		printerr("FAIL: at full deaths the volume should reach PeakVolumeDb (%.2f dB), not %.2f." % [
			peak_volume, after.y])
	else:
		print("  OK - radius reaches MaxMinDistance and volume reaches PeakVolumeDb (%.1f dB)." % peak_volume)

## GameManager.MaxMeaningfulDeaths, the count at which the death constant reaches 1.
const GameManager_MAX_DEATHS := 10
