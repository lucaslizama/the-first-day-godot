extends SceneTree
## Drives the death-and-respawn sequence in the real level and reports the timeline.
##
## The chain is worth testing end to end rather than by inspection because it was
## never code in Unity: it was a UnityEvent graph whose targets and half its method
## names lived in prefab-instance overrides. Reading it wrong is easy and produces a
## sequence that looks plausible and respawns the player in the wrong place, at the
## wrong time, or with the fall speed still on them.
##
## The player is dropped into the kill volume, and this records when input is taken
## away, when the screen goes black, when the teleport happens, and when control comes
## back - against the fade's own numbers: 1 s of delay, 2 s to black, then the
## teleport, then a 1 s delay and 0.667 s back.
##
## Run: godot-mono --headless --script tools/verify_respawn.gd

## Where the player is put to start the fall: below the level, above the kill volume.
const DROP := Vector3(0.0, -4.0, 4.0)

const TIMEOUT_SECONDS := 12.0

var _frames := 0
var _level: Node3D
var _player: CharacterBody3D
var _fade: ColorRect
var _input: Node
var _manager: Node
var _elapsed := 0.0
var _log: Array[String] = []
var _was_input := true
var _was_alpha := -1.0
var _was_dead := false
var _last_pos := Vector3.ZERO
var _deaths := 0
var _teleport_at := -1.0
var _black_at := -1.0
var _died_at := -1.0
var _opened_at := -1.0
var _restored_at := -1.0

func _process(_d: float) -> bool:
	_frames += 1
	if _frames == 4:
		_level = (load("res://scenes/level.tscn") as PackedScene).instantiate()
		root.add_child(_level)
		_player = _level.get_node("Player")
		_fade = _level.get_node("UI/FadeOverlay")
		_input = root.get_node_or_null("PlayerInput")
		_manager = root.get_node_or_null("GameManager")
		_last_pos = _player.global_position
	return false

func _physics_process(delta: float) -> bool:
	if _level == null:
		return false
	_elapsed += delta

	# Only once the level has finished opening out of black. A fade already running
	# swallows further requests - GUIFadeEffect had the same guard - so a death during
	# the opening fade-in would drop the fade-out and the sequence would never start.
	# In play that cannot happen: the player stands on solid ground with input off
	# until that fade completes.
	if _opened_at < 0.0:
		if _elapsed > 0.5 and _fade.color.a <= 0.001 and not _fade.Fading:
			_opened_at = _elapsed
			_note("level finished opening out of black")
		return false

	# Drop the player into the kill volume.
	if _died_at < 0.0 and _player.global_position.y > -3.0:
		_player.global_position = DROP
		_note("dropped the player at y=%.1f, above the kill volume" % DROP.y)

	var alpha: float = _fade.color.a
	if _input != null and _input.CanValidateInput != _was_input:
		_was_input = _input.CanValidateInput
		_note("input %s" % ("enabled" if _was_input else "disabled"))
		if _was_input and _restored_at < 0.0 and _teleport_at >= 0.0:
			_restored_at = _elapsed
	if _player.IsDead != _was_dead:
		_was_dead = _player.IsDead
		_note("player %s" % ("died" if _was_dead else "revived"))
		if _was_dead:
			_died_at = _elapsed
	if _black_at < 0.0 and alpha >= 0.999 and _was_alpha < 0.999:
		_black_at = _elapsed
		_note("screen fully black")
	_was_alpha = alpha
	if _manager != null and _manager.Deaths != _deaths:
		_deaths = _manager.Deaths
		_note("death count now %d" % _deaths)
	# A jump of more than a metre in one tick is the teleport, not walking.
	if _player.global_position.distance_to(_last_pos) > 1.0 and _teleport_at < 0.0 and _black_at >= 0.0:
		_teleport_at = _elapsed
		_note("teleported to (%.2f, %.2f, %.2f)" % [
			_player.global_position.x, _player.global_position.y, _player.global_position.z])
	_last_pos = _player.global_position

	if _restored_at >= 0.0 or _elapsed > TIMEOUT_SECONDS:
		_report()
		quit(0 if _restored_at >= 0.0 else 1)
		return true
	return false

func _note(message: String) -> void:
	_log.append("  %5.2fs  %s" % [_elapsed, message])

func _report() -> void:
	print("respawn timeline:")
	for line in _log:
		print(line)

	if _restored_at < 0.0:
		printerr("FAIL: the sequence never handed control back within %.0f s." % TIMEOUT_SECONDS)
		return

	var to_black: float = _black_at - _died_at
	print("death to fully black: %.2f s (fadeOutDelay 1 + 2 s at 0.5 alpha/s = 3.00)" % to_black)
	print("teleport %.2f s after black, control back %.2f s after that" % [
		_teleport_at - _black_at, _restored_at - _teleport_at])

	var checkpoint: Node3D = _level.get_node("Zones/Checkpoint1")
	var gap: float = _player.global_position.distance_to(checkpoint.global_position)
	print("landed %.3f m from Checkpoint1 at (%.2f, %.2f, %.2f)" % [
		gap, checkpoint.global_position.x, checkpoint.global_position.y, checkpoint.global_position.z])

	if absf(to_black - 3.0) > 0.35:
		printerr("FAIL: %.2f s to black, expected 3.00 from the fade's own numbers." % to_black)
	elif _teleport_at < _black_at:
		printerr("FAIL: the teleport happened before the screen was black.")
	elif gap > 2.0:
		printerr("FAIL: the player did not end up at the checkpoint.")
	else:
		print("OK - died, faded, teleported to the checkpoint behind a black screen, control returned.")
