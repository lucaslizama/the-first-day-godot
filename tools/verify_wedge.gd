extends SceneTree

## Jumping into a wall must never pin the character in mid-air.
##
##   godot-mono --headless --path . --script tools/verify_wedge.gd
##
## REPORTED FROM PLAY: in the first room, jump towards the back wall and you hang there.
## Gravity keeps accumulating in Velocity - vy swept from +8.3 through zero to -2.7 - but the
## POSITION never changed, y and z both frozen to the millimetre. Direction could still be
## changed, and the animation sat on the jump clip's last frame because IsJumping never cleared.
##
## The cause was not the code that decides gravity, which was working the whole time. It was
## `MoveAndSlide` resolving nothing: the capsule caught on the seams of the wall prop's trimesh
## collision and the depenetration margin was too small to push it clear, so every tick asked for
## motion and got exactly none. Measured, by driving this repro under a range of settings:
##
##     max_slides   12 or 24        still stuck  (so it was never slide-budget exhaustion)
##     safe_margin  0.001 default   stuck
##                  0.02 .. 0.04    stuck
##                  0.05            frees him - but that is the THRESHOLD
##                  0.08            frees him with room to spare   <- chosen
##
## `safe_margin = 0.08` is set on the Player in scenes/player.tscn. It is not a patch for this one
## prop: Godot's 0.001 default is small for ConcavePolygonShape3D, and this level is trimesh
## throughout - LevelShell builds 53 bodies that way and PropCollision more - so any seam could do
## the same thing. See docs/level-port-scope.md.
##
## THIS CHECKS THE BEHAVIOUR, NOT THE SETTING. Asserting `safe_margin == 0.08` would pass while
## the player was welded to a wall by some other cause; asserting he comes back down cannot.


const SPOTS := [
	# label, start position, whether to run at the wall rather than walk
	["walking into the first room's back wall", Vector3(0.0, 0.2, 4.0), false],
	["running into the first room's back wall", Vector3(0.0, 0.2, 4.0), true],
]

## Airborne ticks with no vertical movement at all before we call it pinned. A real jump changes
## height every tick; even at the apex it only passes through zero for one.
const PINNED_TICKS := 20

var index := 0
var level: Node3D
var player: CharacterBody3D
var tick := 0
var phase := 0
var jumped_at := -1
var last_y := 0.0
var pinned := 0
var peak_y := -999.0
var failures := 0
var checks := 0


func _initialize() -> void:
	_start()


func _start() -> void:
	if level != null:
		level.free()
	level = (load("res://scenes/level.tscn") as PackedScene).instantiate()
	root.add_child(level)
	player = level.get_node("Player")
	tick = 0
	phase = 0
	jumped_at = -1
	pinned = 0
	peak_y = -999.0


func _physics_process(_delta: float) -> bool:
	tick += 1
	if tick < 15:
		return false

	if phase == 0:
		player.global_position = SPOTS[index][1]
		player.velocity = Vector3.ZERO
		Input.action_press("move_forward")
		if SPOTS[index][2]:
			Input.action_press("run")
		phase = 1
		return false

	# Walk up to the wall, then jump into it.
	if phase == 1:
		if player.global_position.z >= 6.40 and player.is_on_floor():
			Input.action_press("jump")
			jumped_at = tick
			last_y = player.global_position.y
			phase = 2
		elif tick > 300:
			_fail("%s: never reached the wall (z=%.2f); the repro cannot run"
				% [SPOTS[index][0], player.global_position.z])
			checks += 1
			return _advance()
		return false

	if tick == jumped_at + 2:
		Input.action_release("jump")

	peak_y = maxf(peak_y, player.global_position.y)

	if not player.is_on_floor() and absf(player.global_position.y - last_y) < 0.0005:
		pinned += 1
	else:
		pinned = 0
	last_y = player.global_position.y

	if pinned >= PINNED_TICKS:
		checks += 1
		_fail("%s: PINNED - %d ticks airborne at y=%.3f with no vertical movement, while Velocity.y=%+.2f"
			% [SPOTS[index][0], pinned, player.global_position.y, player.velocity.y])
		return _advance()

	# Back on the ground: the jump completed, which is all that was ever asked of it.
	if player.is_on_floor() and tick > jumped_at + 15:
		checks += 1
		_ok("%s: jumped to y=%.2f and came back down" % [SPOTS[index][0], peak_y])
		return _advance()

	if tick > jumped_at + 240:
		checks += 1
		_fail("%s: still airborne after 4 s at y=%.3f" % [SPOTS[index][0], player.global_position.y])
		return _advance()
	return false


func _advance() -> bool:
	Input.action_release("move_forward")
	Input.action_release("run")
	Input.action_release("jump")
	index += 1
	if index >= SPOTS.size():
		print("")
		if failures > 0:
			print("FAIL: %d of %d checks failed" % [failures, checks])
			quit(1)
		else:
			print("PASS: %d checks" % checks)
			quit(0)
		return true
	_start()
	return false


func _ok(m: String) -> void:
	print("  ok    ", m)


func _fail(m: String) -> void:
	failures += 1
	print("  FAIL  ", m)
