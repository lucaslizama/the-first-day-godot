extends SceneTree

## Re-shoots the itch.io page images from the real game.
##
##   xvfb-run -a -s "-screen 0 1920x1080x24" godot-mono --path . --script tools/capture_itch_shots.gd
##
## Writes to user://itch — on Linux, ~/.local/share/godot/app_userdata/The First Day/itch.
## The results are NOT committed: they are 3.7 MB of derived PNGs against an 11 MB repository, and
## re-shooting for each release would grow it without bound. This file is the thing worth keeping,
## because it holds the part that was expensive to work out — where to stand.
##
## WHERE THE POSITIONS CAME FROM. The first attempt guessed three camera spots that looked
## plausible on the level map and turned out to be over the void; it produced three shots of
## nothing, with the player at y=-148, and two of them nearly reached the page. The positions below
## were found by raycasting straight down through the level at 6 m intervals and recording where
## there was actually floor. The guard in _process refuses to save a shot where the player has
## fallen, so that failure cannot repeat silently.
##
## The cover images are ImageMagick crops of two of these; the exact commands are in
## docs/itch-page.md, which is also where each shot's purpose is written down.

const OUT := "user://itch"

## label, player position, deaths, extra settle seconds beyond the fade-in.
## A null position means the MAIN MENU rather than the level - that is where the recommended
## cover is cropped from. Every other position stands on verified floor; see the note above.
##
## The "deaths" column is 9 rather than 10 on the distorted shots: GameManager saturates at
## MaxMeaningfulDeaths = 10, and 9 is the last value that still reads as "this can get worse".
const SHOTS := [
	["00_menu", null, 0, 0.0],
	["01_start", Vector3(0.0, 0.3, 4.0), 0, 0.0],
	["02_hammers", Vector3(0.0, 0.3, -76.0), 0, 1.6],
	["03_hammers_deaths", Vector3(0.0, 0.3, -76.0), 9, 1.6],
	["04_platforms", Vector3(0.0, 0.3, -46.0), 0, 0.4],
	["05_ending", Vector3(0.0, 12.3, -172.0), 0, 0.4],
	["06_start_deaths", Vector3(0.0, 0.3, 4.0), 9, 0.0],
]

## The level opens out of black: FadeInDelay 1 s, then 1/FadeInSpeed = 1/1.5 s. Waiting less than
## this photographs the fade rather than the game.
const FADE_SECONDS := 2.8

var index := 0
var scene: Node
var player: CharacterBody3D
var clock := 0.0
var placed := false
var start_y := 0.0
var failures := 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	_start()


func _start() -> void:
	if scene != null:
		scene.free()
	var path := "res://scenes/level.tscn"
	if SHOTS[index][1] == null:
		path = "res://scenes/main_menu.tscn"
	scene = (load(path) as PackedScene).instantiate()
	player = null
	clock = 0.0
	placed = false
	root.add_child(scene)


func _process(delta: float) -> bool:
	clock += delta

	if not placed:
		placed = true
		player = scene.get_node_or_null("Player") as CharacterBody3D
		if player != null and SHOTS[index][1] != null:
			player.global_position = SHOTS[index][1]
			player.velocity = Vector3.ZERO
			start_y = SHOTS[index][1].y
			var gm := root.get_node("GameManager")
			gm.call("ResetDeaths")
			for i in int(SHOTS[index][2]):
				gm.call("AddDeath")
		return false

	if clock < FADE_SECONDS + float(SHOTS[index][3]):
		return false

	var label: String = SHOTS[index][0]
	var fell := player != null and player.global_position.y < start_y - 3.0
	if fell:
		failures += 1
		print("FELL  %-18s y=%.2f - NOT saved; this position has no floor" % [
			label, player.global_position.y])
	else:
		var img := root.get_texture().get_image()
		var err := img.save_png("%s/%s.png" % [OUT, label])
		if err != OK:
			failures += 1
			print("ERR   %-18s save failed (%d)" % [label, err])
		else:
			print("ok    %-18s %dx%d deaths=%d" % [
				label, img.get_width(), img.get_height(), int(SHOTS[index][2])])

	index += 1
	if index >= SHOTS.size():
		print("")
		print("%d shot(s) written to %s" % [SHOTS.size() - failures, ProjectSettings.globalize_path(OUT)])
		if failures > 0:
			print("FAIL: %d shot(s) could not be taken" % failures)
			quit(1)
		else:
			print("Crop the two covers from 00_menu.png and 05_ending.png - commands are in")
			print("docs/itch-page.md.")
			quit(0)
		return true
	_start()
	return false
