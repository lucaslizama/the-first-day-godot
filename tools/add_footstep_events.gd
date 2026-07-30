extends SceneTree
## Re-adds the footstep animation events that did not survive the FBX export.
##
## Unity fired PlayStepSound from animation events on the walk and run clips, through
## FortunatoAnimFunctions. Animation events do not come across in an FBX, so the clips
## arrived silent and PlayerCharacter had no footsteps.
##
## The frames are measured, not guessed. Each foot's height is sampled from the live
## skeleton across the clip - the animation is played and each bone's global pose read,
## which is the only way to get a foot's real height, since the tracks are per-bone and
## local. A footfall is where a foot's contact *begins*; see _contacts for why that
## rather than the lowest point. Assuming 0% and 50% of the cycle would land close but
## not right, and landing the sound on the contact is the whole purpose of these events.
##
## Writes method tracks into models/fortunato/anims/walk.res and run.res, calling
## PlayStepSound on the player. Pass --dry to measure without writing.
##
## Run: godot-mono --headless --script tools/add_footstep_events.gd -- [--dry]

## Clips that have footfalls. jumpL/jumpR take off rather than step, and Unity played
## the landing sound from Fortunato.Update's land-state check, not from a clip event.
const CLIPS := ["walk", "run"]

## Bone names to track, per foot. Toes touch down before the ankle does.
const FEET := {"left": "Toes_L", "right": "Toes_R"}

## Sampling rate for the height curves.
const SAMPLE_HZ := 120.0

## A minimum only counts as a footfall if the foot is in the lower part of its range,
## which rejects the small dip a foot makes mid-swing.
const CONTACT_BAND := 0.35

## The method the events call, on the node the track points at.
const METHOD := "PlayStepSound"

## Where the method track points, relative to the AnimationPlayer's root_node
## ("../Model"), so this resolves back to the player itself.
const TRACK_PATH := ".."

var _frames := 0
var _dry := false

func _initialize() -> void:
	_dry = OS.get_cmdline_user_args().has("--dry")

func _process(_d: float) -> bool:
	_frames += 1
	if _frames < 4:
		return false

	var player := (load("res://scenes/player.tscn") as PackedScene).instantiate()
	root.add_child(player)
	var anim: AnimationPlayer = player.get_node("AnimationPlayer")
	var skeleton: Skeleton3D = _find_skeleton(player)
	if skeleton == null:
		printerr("FAIL: no Skeleton3D under the player.")
		quit(1)
		return true

	var bones := {}
	for side in FEET:
		var idx := skeleton.find_bone(FEET[side])
		if idx < 0:
			printerr("FAIL: no bone named '%s'. Bones look like: %s" % [
				FEET[side], _bone_names(skeleton).slice(0, 12)])
			quit(1)
			return true
		bones[side] = idx

	for clip_name in CLIPS:
		var clip := anim.get_animation(clip_name)
		if clip == null:
			printerr("FAIL: no '%s' animation in the library." % clip_name)
			quit(1)
			return true
		_process_clip(anim, skeleton, bones, clip_name, clip)

	quit(0)
	return true

func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for c in node.get_children():
		var found := _find_skeleton(c)
		if found != null:
			return found
	return null

func _bone_names(skeleton: Skeleton3D) -> Array[String]:
	var names: Array[String] = []
	for i in skeleton.get_bone_count():
		names.append(skeleton.get_bone_name(i))
	return names

func _process_clip(anim: AnimationPlayer, skeleton: Skeleton3D, bones: Dictionary,
		clip_name: String, clip: Animation) -> void:
	var steps := int(clip.length * SAMPLE_HZ)
	var curves := {}
	for side in bones:
		curves[side] = []

	anim.play(clip_name)
	for i in steps + 1:
		var t: float = minf(float(i) / SAMPLE_HZ, clip.length)
		anim.seek(t, true)
		for side in bones:
			curves[side].append(skeleton.get_bone_global_pose(bones[side]).origin.y)
	anim.stop()

	var contacts: Array[float] = []
	for side in bones:
		var found := _contacts(curves[side])
		print("%s: %-5s contacts at %s (height range %.3f..%.3f m)" % [
			clip_name, side, _times(found), _lo(curves[side]), _hi(curves[side])])
		for t in found:
			contacts.append(t)
	contacts.sort()

	if contacts.is_empty():
		printerr("FAIL: %s has no footfalls; nothing to hang the events on." % clip_name)
		return

	print("%s: %d footfalls over %.3f s -> %s" % [
		clip_name, contacts.size(), clip.length, _times(contacts)])

	if _dry:
		return
	_write_track(clip, clip_name, contacts)

## The moment each contact begins: the first sample of every run where the foot sits
## in the lower CONTACT_BAND of its own height range.
##
## Deliberately not local minima. A planted foot's height curve is not smooth - it
## wobbles by fractions of a millimetre for the dozens of frames it stays down - so
## minima-hunting found thirteen "low points" per foot in a two-step walk cycle. The
## start of the contact is also the better answer musically: that is when the foot
## lands, whereas the lowest sample falls somewhere in the middle of the plant.
func _contacts(curve: Array) -> Array[float]:
	var lo := _lo(curve)
	var hi := _hi(curve)
	var cutoff: float = lo + ((hi - lo) * CONTACT_BAND)

	var runs: Array[Vector2i] = []
	var start := -1
	for i in curve.size():
		var down: bool = curve[i] <= cutoff
		if down and start < 0:
			start = i
		elif not down and start >= 0:
			runs.append(Vector2i(start, i - 1))
			start = -1
	if start >= 0:
		runs.append(Vector2i(start, curve.size() - 1))

	# A clip that both ends and starts in contact is one contact seen across the loop
	# point, and its beginning is in the earlier run - so the run at index 0 is a
	# continuation, not a step.
	if runs.size() > 1 and runs[0].x == 0 and runs[runs.size() - 1].y == curve.size() - 1:
		runs.remove_at(0)

	var out: Array[float] = []
	for r in runs:
		out.append(float(r.x) / SAMPLE_HZ)
	return out

func _lo(curve: Array) -> float:
	var v := INF
	for c in curve:
		v = minf(v, c)
	return v

func _hi(curve: Array) -> float:
	var v := -INF
	for c in curve:
		v = maxf(v, c)
	return v

func _times(values: Array) -> String:
	var parts: Array[String] = []
	for v in values:
		parts.append("%.3fs" % v)
	return ", ".join(parts)

func _write_track(clip: Animation, clip_name: String, contacts: Array[float]) -> void:
	# Drop any method track this tool added before, so re-running is idempotent.
	for i in range(clip.get_track_count() - 1, -1, -1):
		if clip.track_get_type(i) == Animation.TYPE_METHOD:
			clip.remove_track(i)

	# These clips arrived from the FBX with loop_mode 0, like every other one, and a
	# locomotion cycle that does not loop fires its events once and stops. Unity looped
	# them: they are the walk_run_tree's two states. Without this the second stride is
	# silent, and PlayerCharacter has to restart the clip from scratch every cycle.
	clip.loop_mode = Animation.LOOP_LINEAR

	var track := clip.add_track(Animation.TYPE_METHOD)
	clip.track_set_path(track, NodePath(TRACK_PATH))
	for t in contacts:
		# A key at exactly 0 sits on the loop seam, where the playhead arrives by
		# wrapping rather than by advancing onto it. Nudged half a frame in so each
		# cycle actually crosses it.
		clip.track_insert_key(track, maxf(t, 0.008), {"method": METHOD, "args": []})

	var path := "res://models/fortunato/anims/%s.res" % clip_name
	var err := ResourceSaver.save(clip, path)
	if err != OK:
		printerr("FAIL: could not save %s (error %d)" % [path, err])
		return
	print("%s: wrote %d %s keys to %s" % [clip_name, contacts.size(), METHOD, path])
