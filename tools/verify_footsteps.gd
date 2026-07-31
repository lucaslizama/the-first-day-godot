extends SceneTree
## Checks that the re-added footstep events actually fire, and when.
##
## Two things can go wrong quietly here. The method tracks point at ".." relative to
## the AnimationPlayer's root_node, and PlayerCharacter strips tracks whose node does
## not resolve - so a wrong path means the events are deleted at load with no warning.
## And the walk cycle's first footfall sits at exactly t = 0, which is the kind of key
## an animation player can step straight past.
##
## Steps are counted by watching the step sound turn on, which needs a dedupe window
## longer than the 37 ms sound - otherwise one play at a low pitch is counted on two
## consecutive ticks - and needs the sound silenced between clips, or the previous
## clip's last step is counted as the next one's first. Both of those bit this check
## before they were handled.
##
## Run: godot-mono --headless --script tools/verify_footsteps.gd

const CLIPS := {"walk": [0.0, 0.783], "run": [0.1, 0.6]}

## How much of each clip to play, in cycles. A little over 2 so the second stride's last
## footfall is comfortably inside the window: at exactly 2.0 whether it landed was
## decided by frame pacing, and this check failed about one run in three by counting 3
## steps instead of 4.
const CYCLES := 2.25

## How far a step may land from its measured footfall, in ANIMATION time.
##
## THE BOUND USED TO ENCODE A FRAME RATE, which is why this check sat red. It compared the
## step against `_elapsed`, a sum of PHYSICS deltas, while an AnimationPlayer advances on the
## IDLE clock by default - so a method key fires up to one whole rendered frame after its own
## key time, and the gap was set by however fast the machine happened to render. Five frames
## is comfortable at 60 fps and not at this environment's ~17, where the gap measured 0.100 s
## against the 0.083 s limit. The events were never wrong.
##
## Both halves of that are fixed rather than widened. The player is switched to the physics
## callback mode for the duration of the check, so the clip advances in lockstep with the loop
## that polls it, and the step is recorded at the animation's own playhead rather than at a
## wall clock. The remaining error is then bounded by mechanism instead of by hardware: the key
## fires on the first tick whose playhead has passed it (under 1 tick), and the poll may see it
## on the following tick (1 more), so under 2 ticks. Three sits strictly above that, which is
## the property the previous bound lacked - the old 0.05 s was exactly equal to a value the gap
## could take, so a `>` comparison was a coin flip.
##
## Still discriminating easily: run's footfalls are 0.5 s apart, so this is a tenth of the
## spacing.
const MAX_GAP := 3.0 / 60.0

var _frames := 0
var _player: CharacterBody3D
var _anim: AnimationPlayer
var _clip_names: Array[String] = []
var _index := -1
var _elapsed := 0.0
var _fired: Array[float] = []

## Animation-time position of each recorded step, parallel to _fired. See MAX_GAP.
var _fired_position: Array[float] = []
var _failed := false

func _process(_d: float) -> bool:
	_frames += 1
	if _frames == 4:
		_player = (load("res://scenes/player.tscn") as PackedScene).instantiate()
		root.add_child(_player)
		_anim = _player.get_node("AnimationPlayer")
		# The player picks its own clip every physics tick, and in an empty scene it is
		# falling, so it would replace the clip under test with "fall" within five ticks.
		# Its _PhysicsProcess is the only thing that does that; method tracks fire
		# regardless of it.
		_player.set_physics_process(false)

		# Advance the clip on the PHYSICS clock, so it moves in lockstep with the loop below that
		# polls for the sound. The game leaves this on Idle, and that is fine there - the key times
		# inside the clip are identical either way - but measuring them from a differently-clocked
		# loop is what made this check's gap a function of the render rate. See MAX_GAP.
		_anim.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS

		for name in CLIPS:
			_clip_names.append(name)
		_check_tracks()
		_next_clip()
	return false

func _physics_process(delta: float) -> bool:
	if _index < 0 or _index >= _clip_names.size():
		return false
	_elapsed += delta

	# Sniffing "is the step sound playing" needs a dedupe window longer than the sound
	# itself, or one 37 ms play at a low pitch gets counted on two consecutive ticks.
	var step: AudioStreamPlayer3D = _player.get_node("StepSound")
	if step.playing and (_fired.is_empty() or _elapsed - _fired[_fired.size() - 1] > 0.15):
		_fired.append(_elapsed)
		# Where in the CLIP the step landed. The dedupe above needs a monotonic clock, since the
		# playhead wraps every cycle, so both are kept: _elapsed for counting and de-duplicating,
		# this for the timing assertion.
		_fired_position.append(_anim.current_animation_position)

	var clip := _anim.get_animation(_clip_names[_index])
	if _elapsed < clip.length * CYCLES:
		return false

	_report_clip(clip)
	_next_clip()
	if _index >= _clip_names.size():
		quit(1 if _failed else 0)
		return true
	return false

## The tracks have to survive PlayerCharacter._Ready, which drops tracks whose node
## does not resolve from the animation's root.
func _check_tracks() -> void:
	for name in _clip_names:
		var clip := _anim.get_animation(name)
		# Count PlayStepSound keys specifically. These clips also carry a second method
		# track for SetLeftJump/SetRightJump, on the same footfalls, which is how Unity
		# had it - counting every method key instead makes this fail at 4 when the
		# footsteps are perfectly fine. They need separate tracks because
		# Animation.track_insert_key replaces any key already at that time.
		var found := 0
		var times: Array[String] = []
		for t in clip.get_track_count():
			if clip.track_get_type(t) != Animation.TYPE_METHOD:
				continue
			for k in clip.track_get_key_count(t):
				var method := clip.method_track_get_name(t, k)
				if method == "PlayStepSound":
					found += 1
				times.append("%.3fs %s" % [clip.track_get_key_time(t, k), method])
		print("%s: %d PlayStepSound keys of %d method keys: %s" % [
			name, found, times.size(), ", ".join(times)])
		if found != CLIPS[name].size():
			printerr("FAIL: %s should carry %d footstep keys, not %d. A track pointing at a" % [
				name, CLIPS[name].size(), found])
			printerr("      node that does not resolve is stripped at load without a warning.")
			_failed = true

		# The key TIMES, asserted statically. This is the real property - where the events sit in the
		# clip - and it needs no playback at all, so it cannot be perturbed by frame pacing the way the
		# runtime measurement below can. Playing the clip then only has to show the events fire.
		for t in clip.get_track_count():
			if clip.track_get_type(t) != Animation.TYPE_METHOD:
				continue
			for k in clip.track_get_key_count(t):
				if clip.method_track_get_name(t, k) != "PlayStepSound":
					continue
				var key_time := clip.track_get_key_time(t, k)
				# Circular distance, because these clips LOOP: walk's first footfall is at t = 0 and
				# its key is written at t = length instead, half a frame short of the seam, since a
				# playhead arrives at 0 by wrapping rather than by advancing onto it. Comparing
				# linearly makes that key look 0.750 s misplaced when it is exactly right.
				var nearest := INF
				for e in CLIPS[name]:
					var d: float = absf(key_time - float(e))
					nearest = minf(nearest, minf(d, clip.length - d))
				if nearest > 0.002:
					printerr("FAIL: %s has a PlayStepSound key at %.3f s, %.3f s from any measured footfall %s." % [
						name, key_time, nearest, str(CLIPS[name])])
					printerr("      Regenerate with tools/add_footstep_events.gd; the times come from the rig.")
					_failed = true

func _next_clip() -> void:
	_index += 1
	_elapsed = 0.0
	_fired.clear()
	_fired_position.clear()
	# Silence anything still ringing from the previous clip, or its last step gets
	# counted as this clip's first.
	if _player != null:
		(_player.get_node("StepSound") as AudioStreamPlayer3D).stop()
	if _index < _clip_names.size():
		_anim.play(_clip_names[_index])

func _report_clip(clip: Animation) -> void:
	var name := _clip_names[_index]
	var expected: Array = CLIPS[name]
	var per_cycle: float = float(_fired.size()) / CYCLES
	var times: Array[String] = []
	for f in _fired:
		times.append("%.3fs" % f)
	print("%s: %d steps over %.1f cycles (%.1f per cycle, expected %d) at %s" % [
		name, _fired.size(), CYCLES, per_cycle, expected.size(), ", ".join(times)])

	if _fired.is_empty():
		printerr("FAIL: %s fired no footsteps at all." % name)
		_failed = true
		return

	# Each fired step should land near one of the expected footfalls, modulo the loop.
	# Positions come off the playhead, so they are already inside [0, length) and need no fmod of a
	# wall clock - which is what previously compared two different clocks against each other.
	var worst := 0.0
	for phase in _fired_position:
		var best := INF
		for e in expected:
			best = minf(best, minf(absf(phase - e), clip.length - absf(phase - e)))
		worst = maxf(worst, best)
	print("%s: worst gap between a step and a measured footfall: %.3f s" % [name, worst])
	# Two bounds rather than a rate. Playing for CYCLES cycles crosses each footfall
	# CYCLES times, plus up to one more per footfall from the partial cycle the window
	# ends in - so the ideal is a range, not a single number.
	var ideal: int = int(expected.size() * CYCLES)
	if worst > MAX_GAP:
		printerr("FAIL: %s played a step %.3f s away from any footfall (limit %.3f s)." % [
			name, worst, MAX_GAP])
		_failed = true
	elif _fired.size() < ideal or _fired.size() > ideal + expected.size():
		printerr("FAIL: %s played %d steps, expected %d to %d." % [
			name, _fired.size(), ideal, ideal + expected.size()])
		_failed = true
	else:
		print("%s: OK - %d steps, each on a measured footfall." % [name, _fired.size()])
