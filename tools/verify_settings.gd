# Drives GameSettings and checks that a player can change things without damaging the ported mix.
#
#   godot-mono --headless --path . --script tools/verify_settings.gd
#
# The options screen is a DELIBERATE ADDITION - the 2016 original had no settings at all - so there
# is no Unity behaviour to compare against. What there IS to protect is everything the port already
# tuned, and the audio mix is the sharpest edge: CLAUDE.md states that the balance lives in
# default_bus_layout.tres and not in the emitters, and Fortunato sits at +9.5 dB precisely because
# Unity's +20 drove the footstep to +1.55 dBTP and clipped the master.
#
# So the claim this file exists to pin is not "the sliders work". It is:
#
#     THE SHIPPED MIX IS THE LOUDEST THING A PLAYER CAN CHOOSE.
#
# Every volume is an OFFSET from the dB the layout authored, snapshotted before anything is applied,
# and the offset can only ever be <= 0. That makes verify_music.gd's clipping budget permanently
# valid instead of valid-until-somebody-drags-a-slider-up, and it is checked here by sweeping every
# slider position rather than by reading the one line of code that promises it.
#
# GameSettings is instantiated directly, with ConfigPath pointed at a scratch file. Two reasons:
# the developer's own user://settings.cfg must not be clobbered by running a check, and the autoload
# deliberately loads NOTHING under --script (see the note in GameSettings._Ready), so the loading
# path would otherwise never be exercised at all.
extends SceneTree

const SCRATCH := "user://settings_verify.cfg"

## GameSettings.Section, which crosses into GDScript as a plain int.
const SECTION_GAME := 0
const SECTION_AUDIO := 1
const SECTION_VIDEO := 2
const SECTION_INPUT := 3

## default_bus_layout.tres, read out of the file rather than restated here - the point of the check
## is that these numbers survive, so hardcoding them would only prove this script can hold a copy.
var authored := {}

var settings: Node
var failures := 0
var checks := 0


func _initialize() -> void:
	for bus_name in ["Master", "Music", "Ambience", "Coworkers", "Fortunato"]:
		var index := AudioServer.get_bus_index(bus_name)
		if index < 0:
			print("FAIL: default_bus_layout.tres has no bus named '%s'" % bus_name)
			quit(1)
			return
		authored[bus_name] = AudioServer.get_bus_volume_db(index)

	settings = load("res://scripts/Utils/GameSettings.cs").new()
	settings.set("ConfigPath", SCRATCH)
	root.add_child(settings)
	# _Ready lands the frame AFTER add_child in a --script run, and the authored-dB snapshot is
	# taken there. Measured, not assumed: without this wait AuthoredBusDb returns 0.0.
	await process_frame

	_clear_scratch()

	print("")
	_check_snapshot()
	_check_defaults_reproduce_the_layout()
	_check_shipped_mix_is_the_ceiling()
	_check_one_slider_moves_one_bus()
	_check_mute()
	# AWAITED, because it waits a frame for the second instance's _Ready. Called without `await` a
	# coroutine returns at its first yield and the rest of it runs after quit() - so its checks
	# silently never ran and the total still read PASS. That happened.
	await _check_round_trip()
	_check_reset()
	_check_corrupt_file_is_survivable()
	_check_video_reaches_the_engine()

	# Save FIRST, then delete. GameSettings flushes any pending change on _ExitTree, so deleting the
	# scratch file while something was still dirty just had it written straight back after this script
	# finished - leaving a file behind that the next run would read. Saving clears the dirty flag.
	settings.call("Save")
	_clear_scratch()

	print("")
	if failures == 0:
		print("PASS: %d checks" % checks)
	else:
		print("FAIL: %d of %d checks failed" % [failures, checks])
	quit(1 if failures > 0 else 0)


## The snapshot is the whole foundation: if it is wrong, every offset below is measured from the
## wrong place and the mix drifts without anything looking broken.
func _check_snapshot() -> void:
	var problems: Array[String] = []
	for bus_name in authored:
		var got: float = settings.call("AuthoredBusDb", bus_name)
		if abs(got - authored[bus_name]) > 0.01:
			problems.append("%s snapshot %.4f, layout %.4f" % [bus_name, got, authored[bus_name]])

	checks += 1
	if problems.is_empty():
		_ok("the authored dB of all %d buses is snapshotted from the layout" % authored.size())
	else:
		_fail("the snapshot does not match default_bus_layout.tres: %s" % str(problems))


## A player who never opens the options screen must hear the game as it was tagged.
func _check_defaults_reproduce_the_layout() -> void:
	settings.call("ResetSection", SECTION_AUDIO)
	_expect_layout_mix("with no settings file, every bus is at the dB the layout authored")


## THE CLAIM THIS FILE IS FOR. Swept across every slider position, not argued from the code.
func _check_shipped_mix_is_the_ceiling() -> void:
	var louder: Array[String] = []
	for step in range(0, 21):
		var linear := float(step) / 20.0
		for key in _volume_keys():
			settings.call("SetVolume", key, linear)
		settings.call("MarkChanged", SECTION_AUDIO)

		for bus_name in authored:
			var got := AudioServer.get_bus_volume_db(AudioServer.get_bus_index(bus_name))
			# 0.01 dB of slack for float round-tripping, not for a real boost.
			if got > authored[bus_name] + 0.01:
				louder.append("%s at slider %.2f reached %.2f dB, above the layout's %.2f"
					% [bus_name, linear, got, authored[bus_name]])

	checks += 1
	if louder.is_empty():
		_ok("no slider position makes any bus louder than the layout; the clipping budget cannot be undone from the options screen")
	else:
		_fail("a slider raised a bus above its authored level: %s" % str(louder.slice(0, 3)))

	settings.call("ResetSection", SECTION_AUDIO)


## Turning the music down must not move the whispers. A player fixing one thing must not
## silently retune the mix's balance.
func _check_one_slider_moves_one_bus() -> void:
	settings.call("SetVolume", "music", 0.5)
	settings.call("MarkChanged", SECTION_AUDIO)

	var expected: float = authored["Music"] + linear_to_db(0.5)
	var music := AudioServer.get_bus_volume_db(AudioServer.get_bus_index("Music"))

	checks += 1
	if abs(music - expected) > 0.01:
		_fail("Music at 50%% is %.2f dB, expected %.2f (%.2f authored %+.2f offset)"
			% [music, expected, authored["Music"], linear_to_db(0.5)])
	else:
		_ok("Music at 50%% offsets to %.2f dB, %.2f dB below its authored level" % [music, linear_to_db(0.5)])

	var moved: Array[String] = []
	for bus_name in authored:
		if bus_name == "Music":
			continue
		var got := AudioServer.get_bus_volume_db(AudioServer.get_bus_index(bus_name))
		if abs(got - authored[bus_name]) > 0.01:
			moved.append("%s moved to %.2f" % [bus_name, got])

	checks += 1
	if moved.is_empty():
		_ok("turning the music down leaves the other four buses exactly where the layout put them")
	else:
		_fail("the music slider moved buses it does not own: %s" % str(moved))

	settings.call("ResetSection", SECTION_AUDIO)


## Zero must be silence, not negative infinity written into a bus volume.
func _check_mute() -> void:
	settings.call("SetVolume", "music", 0.0)
	settings.call("MarkChanged", SECTION_AUDIO)

	var index := AudioServer.get_bus_index("Music")
	var db := AudioServer.get_bus_volume_db(index)

	checks += 1
	if AudioServer.is_bus_mute(index) and is_finite(db):
		_ok("a slider at zero mutes the bus and leaves its volume finite (%.2f dB)" % db)
	else:
		_fail("a slider at zero left mute=%s volume=%s; -inf in a bus volume is not a thing to discover later"
			% [AudioServer.is_bus_mute(index), db])

	settings.call("ResetSection", SECTION_AUDIO)

	checks += 1
	if not AudioServer.is_bus_mute(index):
		_ok("resetting unmutes it again")
	else:
		_fail("the bus is still muted after a reset")


## A setting a player changes must still be there next time they play.
func _check_round_trip() -> void:
	settings.call("SetVolume", "music", 0.35)
	settings.set("LookSensitivityX", 1.75)
	settings.set("InvertLookY", true)
	settings.set("FieldOfView", 92.0)
	settings.set("ScreenEffects", 0.25)
	settings.set("MaxFpsIndex", 2)
	settings.call("MarkChanged", SECTION_AUDIO)
	settings.call("MarkChanged", SECTION_GAME)
	settings.call("Save")

	checks += 1
	if not FileAccess.file_exists(SCRATCH):
		_fail("Save() wrote no file at %s" % SCRATCH)
		return
	_ok("Save() writes a settings file")

	# Put the buses back BEFORE the second instance exists. Its own snapshot is taken in _Ready, so
	# leaving them attenuated would have it record the attenuated levels as "authored" and every
	# later comparison would be measured from the wrong place.
	settings.call("ResetSection", SECTION_AUDIO)

	var reloaded = load("res://scripts/Utils/GameSettings.cs").new()
	reloaded.set("ConfigPath", SCRATCH)
	root.add_child(reloaded)
	await process_frame
	reloaded.call("Load")

	var problems: Array[String] = []
	if abs(float(reloaded.call("GetVolume", "music")) - 0.35) > 0.001:
		problems.append("music %s" % reloaded.call("GetVolume", "music"))
	if abs(float(reloaded.get("LookSensitivityX")) - 1.75) > 0.001:
		problems.append("LookSensitivityX %s" % reloaded.get("LookSensitivityX"))
	if not bool(reloaded.get("InvertLookY")):
		problems.append("InvertLookY false")
	if abs(float(reloaded.get("FieldOfView")) - 92.0) > 0.001:
		problems.append("FieldOfView %s" % reloaded.get("FieldOfView"))
	if abs(float(reloaded.get("ScreenEffects")) - 0.25) > 0.001:
		problems.append("ScreenEffects %s" % reloaded.get("ScreenEffects"))
	if int(reloaded.get("MaxFpsIndex")) != 2:
		problems.append("MaxFpsIndex %s" % reloaded.get("MaxFpsIndex"))

	checks += 1
	if problems.is_empty():
		_ok("every changed setting comes back after a restart")
	else:
		_fail("settings did not survive the round trip: %s" % str(problems))

	reloaded.call("ResetSection", SECTION_AUDIO)
	reloaded.queue_free()
	await process_frame

	settings.call("ResetSection", SECTION_AUDIO)
	settings.call("ResetSection", SECTION_GAME)
	settings.call("ResetSection", SECTION_VIDEO)


func _check_reset() -> void:
	for key in _volume_keys():
		settings.call("SetVolume", key, 0.2)
	settings.call("MarkChanged", SECTION_AUDIO)
	settings.call("ResetSection", SECTION_AUDIO)
	_expect_layout_mix("resetting the sound section puts all five buses back to the layout")

	settings.set("LookSensitivityX", 2.4)
	settings.set("InvertLookY", true)
	settings.set("FieldOfView", 61.0)
	settings.call("ResetSection", SECTION_GAME)

	checks += 1
	if abs(float(settings.get("LookSensitivityX")) - 1.0) < 0.001 \
			and not bool(settings.get("InvertLookY")) \
			and abs(float(settings.get("FieldOfView")) - 75.0) < 0.001:
		_ok("resetting the game section restores the shipped 1.0 sensitivity, upright look and 75 degree view")
	else:
		_fail("the game section did not reset: sensitivity %s invert %s fov %s"
			% [settings.get("LookSensitivityX"), settings.get("InvertLookY"), settings.get("FieldOfView")])


## A hand-mangled or truncated file must yield a playable game at the shipped settings. Not a
## crash, not silence, and not an unbound action.
func _check_corrupt_file_is_survivable() -> void:
	var file := FileAccess.open(SCRATCH, FileAccess.WRITE)
	file.store_string("this is not a config file\n[audio\nmusic=\"loud\"\nnonsense\n")
	file.close()

	settings.call("Load")
	_expect_layout_mix("a corrupt settings file falls back to the layout's mix rather than a broken one")

	checks += 1
	if abs(float(settings.get("LookSensitivityX")) - 1.0) < 0.001:
		_ok("a corrupt file leaves the game settings at their defaults")
	else:
		_fail("a corrupt file produced LookSensitivityX %s" % settings.get("LookSensitivityX"))

	# Out-of-range values must clamp, not pass through. A field of view of 4000 is not a setting.
	var wild := FileAccess.open(SCRATCH, FileAccess.WRITE)
	wild.store_string("[game]\nfield_of_view=4000.0\nscreen_effects=-8.0\nlook_sensitivity_x=99.0\n"
		+ "[audio]\nmusic=7.5\n[video]\nmsaa=99\n")
	wild.close()

	settings.call("Load")

	checks += 1
	var fov := float(settings.get("FieldOfView"))
	var effects := float(settings.get("ScreenEffects"))
	var sens := float(settings.get("LookSensitivityX"))
	var music := float(settings.call("GetVolume", "music"))
	var msaa := int(settings.get("MsaaIndex"))
	if fov <= 110.0 and effects >= 0.0 and sens <= 3.0 and music <= 1.0 and msaa == 2:
		_ok("out-of-range values clamp (fov %.0f, effects %.2f, sensitivity %.2f, music %.2f, msaa index %d)"
			% [fov, effects, sens, music, msaa])
	else:
		_fail("out-of-range values were not clamped: fov %s effects %s sensitivity %s music %s msaa %s"
			% [fov, effects, sens, music, msaa])

	settings.call("ResetSection", SECTION_GAME)
	settings.call("ResetSection", SECTION_AUDIO)
	settings.call("ResetSection", SECTION_VIDEO)


## The video settings that ARE real engine state headlessly. Window mode and vsync are not - the
## dummy display server ignores both - so they are skipped out loud rather than asserted vacuously,
## the same way verify_pause_menu.gd handles mouse mode.
func _check_video_reaches_the_engine() -> void:
	settings.set("MaxFpsIndex", 2)
	settings.set("MsaaIndex", 0)
	settings.call("MarkChanged", SECTION_VIDEO)

	var want_fps: int = settings.call("FpsCapAt", 2)

	checks += 1
	if Engine.max_fps == want_fps:
		_ok("a frame cap of %d is what the engine is actually running at" % want_fps)
	else:
		_fail("Engine.max_fps is %d, expected %d" % [Engine.max_fps, want_fps])

	checks += 1
	if root.msaa_3d == Viewport.MSAA_DISABLED:
		_ok("turning anti-aliasing off reaches the root viewport, which every scene renders into")
	else:
		_fail("root.msaa_3d is %d, expected %d" % [root.msaa_3d, Viewport.MSAA_DISABLED])

	settings.call("ResetSection", SECTION_VIDEO)

	checks += 1
	if root.msaa_3d == Viewport.MSAA_4X and Engine.max_fps == 0:
		_ok("resetting restores project.godot's 4x MSAA and an uncapped frame rate")
	else:
		_fail("reset left msaa_3d=%d max_fps=%d, expected 4x and 0" % [root.msaa_3d, Engine.max_fps])

	print("  NOTE  window mode and vsync are ignored by the headless display server, so they are not asserted")


func _expect_layout_mix(label: String) -> void:
	var problems: Array[String] = []
	for bus_name in authored:
		var index := AudioServer.get_bus_index(bus_name)
		var got := AudioServer.get_bus_volume_db(index)
		if abs(got - authored[bus_name]) > 0.01 or AudioServer.is_bus_mute(index):
			problems.append("%s at %.4f%s, layout %.4f"
				% [bus_name, got, " (muted)" if AudioServer.is_bus_mute(index) else "", authored[bus_name]])

	checks += 1
	if problems.is_empty():
		_ok(label)
	else:
		_fail("%s - but %s" % [label, str(problems)])


func _volume_keys() -> Array:
	return ["master", "music", "ambience", "whispers", "footsteps"]


func _clear_scratch() -> void:
	if FileAccess.file_exists(SCRATCH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRATCH))


func _ok(m: String) -> void:
	print("  ok    ", m)


func _fail(m: String) -> void:
	failures += 1
	print("  FAIL  ", m)
