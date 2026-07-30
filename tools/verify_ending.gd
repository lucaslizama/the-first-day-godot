# Drives the ending chain and checks each step against Unity's wiring.
#
#   godot-mono --headless --path . --script tools/verify_ending.gd
#
# The chain, read out of nivelEscena (TimerZone delay: 5) and UI.prefab
# (scrollspeed 3, creditsTime 10):
#
#   player enters the volume ->  CanValidateInput = false, Fortunato.Cry(),
#                                fade's completion armed, confetti played
#   +5 s                     ->  FadeOut()
#   fade fully black         ->  credits shown and rolling
#   +10 s of rolling         ->  back to the main menu
#
# What matters here is the ORDER and the TIMING, since the failure modes are a race
# (arming the fade callback after calling FadeOut) and a wrong delay. The scene change
# at the end is deliberately not allowed to happen - it would tear down the tree
# mid-test - so the credits' own countdown reaching zero is checked instead.
extends SceneTree

const TIMER_DELAY := 5.0
const CREDITS_TIME := 10.0
const TOL := 0.2

var level: Node3D
var player: Node3D
var fade: ColorRect
var credits: Control
var timer_zone: Area3D

var frame := 0
var clock := 0.0
var entered_at := -1.0
var fade_started_at := -1.0
var black_at := -1.0
var credits_shown_at := -1.0
var credits_start_y := 0.0
var credits_moved := false
var input_disabled_at := -1.0
var done := false
var failures := 0
var notes: Array[String] = []


func _process(_d: float) -> bool:
	if level == null:
		level = (load("res://scenes/level.tscn") as PackedScene).instantiate()
		root.add_child(level)
		player = level.get_node("Player")
		fade = level.get_node("UI/FadeOverlay")
		credits = level.get_node("UI/Credits")
		timer_zone = level.get_node("TimerZone")
		# Check the real destination loads BEFORE blanking it, so the test still
		# asserts the wiring rather than skipping it. Then blank it, or changing the
		# scene would tear the tree down mid-test.
		var menu: String = credits.get("MainMenuScenePath")
		if ResourceLoader.exists(menu):
			print("  ok    MainMenuScenePath resolves       %s" % menu)
		else:
			_fail("MainMenuScenePath '%s' does not exist; the credits would dead-end" % menu)
		credits.set("MainMenuScenePath", "")
		# Subscribe rather than sampling color.a. The tween reaches 1.0 on the same
		# frame the signal fires, so a sampled ">= 0.999" check is a coin flip - it
		# passed on one run of this script and missed on the next. The signal is the
		# thing the chain actually depends on, so test that.
		fade.connect("FadeOutCompleted", _on_black)
	return false


func _on_black() -> void:
	if black_at < 0.0:
		black_at = clock
		_note("%5.2fs  fade reported fully black" % clock)


func _physics_process(delta: float) -> bool:
	if level == null or done:
		return false
	frame += 1
	clock += delta

	# Let the level settle, then put the player in the finish volume. The zone sits at
	# (-0.02, 12, -182.32) with its box offset (0, 2, 0), so this is inside it.
	if frame == 30:
		_note("%5.2fs  placing the player in the finish volume" % clock)
		player.global_position = timer_zone.global_position + Vector3(0, 1.0, 0)
		entered_at = clock

	var input_node = Engine.get_singleton("PlayerInput") if Engine.has_singleton("PlayerInput") else null
	if input_node == null:
		input_node = root.get_node_or_null("PlayerInput")
	if input_disabled_at < 0.0 and input_node != null and not input_node.CanValidateInput:
		input_disabled_at = clock
		_note("%5.2fs  input disabled" % clock)

	if credits_shown_at < 0.0 and credits.visible:
		credits_shown_at = clock
		credits_start_y = credits.position.y
		_note("%5.2fs  credits shown and rolling" % clock)
	elif credits_shown_at >= 0.0 and not credits_moved and credits.position.y < credits_start_y - 1.0:
		credits_moved = true
		_note("%5.2fs  credits have scrolled %.1f px upward" % [clock, credits_start_y - credits.position.y])

	if credits_shown_at >= 0.0 and credits.get("CreditsTime") <= 0.0:
		_note("%5.2fs  credits finished; GoToMainMenu reached" % clock)
		done = true
		_report()
		quit(1 if failures > 0 else 0)
		return true

	if clock > 45.0:
		_note("timed out at 45 s")
		done = true
		_report()
		quit(1)
		return true
	return false


func _note(message: String) -> void:
	notes.append(message)
	print("   ", message)


func _fail(message: String) -> void:
	failures += 1
	print("  FAIL  ", message)


func _check(label: String, got: float, want: float) -> void:
	if absf(got - want) > TOL:
		_fail("%s was %.2f s, expected %.2f s" % [label, got, want])
	else:
		print("  ok    %-34s %.2f s (expected %.2f)" % [label, got, want])


func _report() -> void:
	print("")
	if entered_at < 0.0:
		_fail("the player never entered the finish volume")
		return
	if input_disabled_at < 0.0:
		_fail("input was never disabled")
	else:
		_check("entry -> input disabled", input_disabled_at - entered_at, 0.0)

	if black_at < 0.0:
		_fail("the screen never went fully black")
	else:
		# FadeOut is called delay seconds after entry, then takes FadeOutDelay (1 s)
		# plus 1/FadeOutSpeed (0.5 alpha/s -> 2 s) to reach black. Same arithmetic
		# verify_respawn.gd checks for the death fade: 1 + 2 = 3 s.
		_check("entry -> fully black", black_at - entered_at, TIMER_DELAY + 3.0)

	if credits_shown_at < 0.0:
		_fail("the credits were never shown")
	else:
		_check("black -> credits shown", credits_shown_at - black_at, 0.0)
		if not credits_moved:
			_fail("the credits were shown but never scrolled")
		_check("credits roll duration", clock - credits_shown_at, CREDITS_TIME)

	print("")
	if failures == 0:
		print("OK - crossed the line, lost control, faded to black, rolled the credits, returned to the menu.")
	else:
		print("FAIL - %d step(s) wrong" % failures)
