# Drives the credits scene and checks what a player would actually see.
#
#   godot-mono --headless --path . --script tools/verify_credits.gd
#
# The credits are a scene of their own now, reached from the level's ending AND from the
# main menu's Credits button. A black screen with the text rolling up from below the bottom
# edge until it clears the top, then back to the menu; any press cuts it short.
#
# The roll is DISTANCE-driven, not time-driven, and that is the point of the rewrite: Unity's
# was `while (creditsTime > 0)` with creditsTime 10 and scrollspeed 3, so it travelled 30
# units and stopped wherever it had reached. Adding a name to a timed scroll silently pushes
# that name off the end. The checks below are written against that failure - "the text leaves
# the screen", not "it scrolled for N seconds".
#
# MainMenuScenePath is cleared throughout so finishing does not tear the tree down mid-test.
# "Finished" is then observed the only way that is visible from outside: the roll STOPS.
extends SceneTree

var credits: Control
var roll: Label
var failures := 0
var checks := 0


func _initialize() -> void:
	if not await _open():
		return

	var view := root.get_visible_rect().size

	# Black, opaque, and covering everything - "just a black background" is the brief.
	var bg := credits.get_node("Background") as ColorRect
	checks += 1
	if bg.color == Color(0, 0, 0, 1) and bg.size.x >= view.x and bg.size.y >= view.y:
		_ok("the background is opaque black over the whole %d x %d viewport" % [view.x, view.y])
	else:
		_fail("background is %s at %s; expected opaque black filling %s" % [bg.color, bg.size, view])

	# Nothing is legible on the first frame: the text starts BELOW the bottom edge and rises
	# into view, which is what makes it read as a roll rather than a scroll already in progress.
	checks += 1
	if roll.position.y >= view.y - 1.0:
		_ok("the text starts below the bottom edge, at y=%.0f for a %d-high viewport"
			% [roll.position.y, view.y])
	else:
		_fail("the text starts at y=%.0f, already on screen for a %d-high viewport"
			% [roll.position.y, view.y])

	checks += 1
	if roll.size.y > view.y:
		_ok("the text is %.0f px tall, taller than the screen, so it must roll to be read"
			% roll.size.y)
	else:
		_ok("the text is %.0f px tall and fits on screen; it still rolls" % roll.size.y)

	# It goes UP.
	var before := roll.position.y
	await _wait(0.5)
	checks += 1
	if roll.position.y < before:
		_ok("the text moves upward: y went %.0f -> %.0f in half a second"
			% [before, roll.position.y])
	else:
		_fail("the text did not move up: y stayed at %.0f" % roll.position.y)

	# THE WHOLE TEXT LEAVES. This is the check Unity's timed scroll would fail, and the one
	# that keeps a newly added credit from being cut off: it asserts the LAST line clears the
	# top, so the required travel grows with the text.
	await _open()
	credits.set("ScrollSpeed", 4000.0)
	var travel: float = view.y + roll.size.y
	await _wait((travel / 4000.0) + 0.5)
	checks += 1
	if roll.position.y <= -roll.size.y:
		_ok("the whole text clears the top edge: y=%.0f, past -%.0f" % [roll.position.y, roll.size.y])
	else:
		_fail("the text stopped at y=%.0f, short of -%.0f - it has not fully left the screen"
			% [roll.position.y, roll.size.y])

	# ...and then it stops, rather than rolling on into the void forever.
	var resting := roll.position.y
	await _wait(0.3)
	checks += 1
	if is_equal_approx(roll.position.y, resting):
		_ok("the roll stops once the text is gone, rather than scrolling forever")
	else:
		_fail("the roll kept going after the end: %.0f -> %.0f" % [resting, roll.position.y])

	# A press cuts it short.
	await _open()
	await _wait(float(credits.get("SkipGuardSeconds")) + 0.2)
	var before_skip := roll.position.y
	await _press(KEY_SPACE)
	await _wait(0.3)
	checks += 1
	if is_equal_approx(roll.position.y, before_skip) or roll.position.y > before_skip - 5.0:
		_ok("a key press stops the roll, so the credits can be skipped")
	else:
		_fail("the roll continued through a key press: %.0f -> %.0f"
			% [before_skip, roll.position.y])

	# ...but not the press that opened the scene. The menu's Credits button is activated with
	# the same key that would skip, and ChangeSceneToFile lands the release here.
	await _open()
	await _press(KEY_SPACE)
	var guarded := roll.position.y
	await _wait(0.3)
	checks += 1
	if roll.position.y < guarded:
		_ok("a press inside the %.2f s guard is ignored, so the opening keypress cannot skip"
			% float(credits.get("SkipGuardSeconds")))
	else:
		_fail("a press inside the guard window stopped the roll at y=%.0f" % roll.position.y)

	# The attributions have to survive edits to this text; freesound's licences require them.
	await _open()
	var text: String = roll.text
	for who in ["thanvannispen", "speedygonzo", "robinhood76", "Guillermo Rojas", "Lucas Lizama"]:
		checks += 1
		if text.contains(who):
			_ok("the credits still name %s" % who)
		else:
			_fail("the credits no longer name %s" % who)

	checks += 1
	if text.contains("looping-hollow-open-air-wind"):
		_ok("the wind is credited under its real filename, with the 'open' the old text dropped")
	else:
		_fail("the wind's filename is wrong or missing; the asset is looping-hollow-open-air-wind.wav")

	print("")
	if failures > 0:
		print("FAIL: %d of %d checks failed" % [failures, checks])
		quit(1)
	else:
		print("PASS: %d checks" % checks)
		quit(0)


## Loads a fresh copy of the scene, with the exit route disabled so finishing does not tear
## down the tree. Each behaviour gets its own copy: the roll is stateful and one-way.
func _open() -> bool:
	if credits != null:
		credits.queue_free()
		await process_frame

	var packed := load("res://scenes/credits.tscn") as PackedScene
	if packed == null:
		print("FAIL: could not load res://scenes/credits.tscn")
		quit(1)
		return false

	credits = packed.instantiate() as Control
	credits.set("MainMenuScenePath", "")
	root.add_child(credits)
	await process_frame
	roll = credits.get_node("Roll") as Label
	return true


func _wait(seconds: float) -> void:
	var left := seconds
	while left > 0.0:
		left -= root.get_process_delta_time()
		await process_frame


func _press(code: Key) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.physical_keycode = code
		ev.pressed = pressed
		Input.parse_input_event(ev)
		await process_frame


func _ok(m: String) -> void:
	print("  ok    ", m)


func _fail(m: String) -> void:
	failures += 1
	print("  FAIL  ", m)
