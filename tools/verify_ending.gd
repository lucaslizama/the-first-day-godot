# Drives the ending chain and checks each step against Unity's wiring.
#
#   godot-mono --headless --path . --script tools/verify_ending.gd
#
# The chain, read out of nivelEscena (TimerZone delay: 5):
#
#   player enters the volume ->  CanValidateInput = false, Fortunato.Cry(),
#                                fade's completion armed, confetti played
#   +5 s                     ->  FadeOut()
#   fade fully black         ->  the credits SCENE is loaded
#
# What matters here is the ORDER and the TIMING, since the failure modes are a race
# (arming the fade callback after calling FadeOut) and a wrong delay.
#
# THE LAST STEP CHANGED. Unity revealed a credits panel that was already sitting in the
# level - `Credits panel.SetActive(true)` - and this port did the same until the credits
# became a scene of their own, shared with the main menu's Credits button. So the old
# assertions about a Label's visibility and its creditsTime counting down are gone; what is
# asserted instead is that the scene change actually happens, and happens while black. The
# roll itself belongs to tools/verify_credits.gd now, which is where it is tested.
#
# The scene change is deliberately ALLOWED to happen here rather than blanked out. It is the
# last thing the chain does, so there is nothing left to tear down, and letting it run is the
# only way to prove the ending really arrives at the credits rather than merely intending to.
extends SceneTree

const TIMER_DELAY := 5.0
const TOL := 0.2

var level: Node3D
var player: Node3D
var fade: ColorRect
var timer_zone: Area3D

var frame := 0
var clock := 0.0
var entered_at := -1.0
var black_at := -1.0
var credits_at := -1.0
var input_disabled_at := -1.0
var done := false
var failures := 0


func _process(_d: float) -> bool:
	if level == null:
		level = (load("res://scenes/level.tscn") as PackedScene).instantiate()
		root.add_child(level)
		player = level.get_node("Player")
		fade = level.get_node("UI/FadeOverlay")
		timer_zone = level.get_node("TimerZone")

		var credits_scene: String = timer_zone.get("CreditsScenePath")
		if ResourceLoader.exists(credits_scene):
			print("  ok    CreditsScenePath resolves        %s" % credits_scene)
		else:
			_fail("CreditsScenePath '%s' does not exist; the ending would dead-end" % credits_scene)

		# Subscribe rather than sampling color.a. The tween reaches 1.0 on the same frame the
		# signal fires, so a sampled ">= 0.999" check is a coin flip - it passed on one run of
		# this script and missed on the next. The signal is what the chain depends on.
		fade.connect("FadeOutCompleted", _on_black)
	return false


func _on_black() -> void:
	if black_at < 0.0:
		black_at = clock
		_note("%5.2fs  fade reported fully black" % clock)


## The credits scene, wherever ChangeSceneToFile has put it. Found by script rather than by
## node name so renaming the root node does not silently turn this check off.
func _find_credits() -> Node:
	for child in root.get_children():
		if child == level:
			continue
		var script: Script = child.get_script()
		if script != null and script.resource_path.ends_with("Credits.cs"):
			return child
	return null


func _physics_process(delta: float) -> bool:
	if level == null or done:
		return false
	frame += 1
	clock += delta

	# Let the level settle, then put the player in the finish volume. The zone sits at
	# (-0.02, 12, -182.32) with its box offset (0, 2, 0), so this is inside it.
	if frame == 30 and is_instance_valid(player):
		_note("%5.2fs  placing the player in the finish volume" % clock)
		player.global_position = timer_zone.global_position + Vector3(0, 1.0, 0)
		entered_at = clock

	var input_node = Engine.get_singleton("PlayerInput") if Engine.has_singleton("PlayerInput") else null
	if input_node == null:
		input_node = root.get_node_or_null("PlayerInput")
	if input_disabled_at < 0.0 and input_node != null and not input_node.CanValidateInput:
		input_disabled_at = clock
		_note("%5.2fs  input disabled" % clock)

	if credits_at < 0.0 and _find_credits() != null:
		credits_at = clock
		_note("%5.2fs  the credits scene is loaded" % clock)
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
		# FadeOut is called delay seconds after entry, then takes FadeOutDelay (1 s) plus
		# 1/FadeOutSpeed (0.5 alpha/s -> 2 s) to reach black. Same arithmetic
		# verify_respawn.gd checks for the death fade: 1 + 2 = 3 s.
		_check("entry -> fully black", black_at - entered_at, TIMER_DELAY + 3.0)

	if credits_at < 0.0:
		_fail("the credits scene was never loaded; the ending dead-ends on a black screen")
	else:
		# The point of the ordering: the change happens BEHIND the fade, so the player never
		# sees the level being swapped out. Anything above a frame or two here is a visible cut.
		_check("black -> credits loaded", credits_at - black_at, 0.0)

	print("")
	if failures == 0:
		print("OK - crossed the line, lost control, faded to black, arrived at the credits.")
	else:
		print("FAIL - %d step(s) wrong" % failures)
