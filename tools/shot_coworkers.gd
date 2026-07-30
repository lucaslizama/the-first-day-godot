extends SceneTree

## Renders the coworkers in place in the level, which is the check that matters for
## them: raycasts cannot confirm the placement of figures that mostly stand in open
## space, but a picture shows whether they are the right size, upright, facing the
## camera and standing rather than sunk.
##
##   --script tools/shot_coworkers.gd -- <out-dir>

var _viewport: SubViewport
var _camera: Camera3D
var _out := "/tmp"
var _frame := 0
var _shot := 0

## Camera position and aim point per shot.
const VIEWS := [
	## Two coworkers that land flush on the floor plane at y = 13, in nivel_p2.
	[Vector3(-6.0, 14.6, -132.0), Vector3(-17.5, 14.0, -141.0)],
	## The same pair closer, to check they stand on the floor rather than in it.
	[Vector3(-13.0, 13.9, -137.0), Vector3(-17.5, 13.8, -141.0)],
	## The cluster behind the outer wall at x = -60, seen from inside the building
	## looking out through the windows.
	[Vector3(-40.0, 20.0, -95.0), Vector3(-60.0, 18.0, -97.0)],
	## A group of the larger, non-uniformly scaled coworkers.
	[Vector3(-45.0, 28.0, -20.0), Vector3(-60.0, 27.0, -16.0)],
]

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	_out = a[0] if a.size() > 0 else "/tmp"

func _build() -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(1200, 800)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)
	_viewport.add_child((load("res://scenes/level.tscn") as PackedScene).instantiate())
	_camera = Camera3D.new()
	_viewport.add_child(_camera)
	_aim(0)

func _aim(i: int) -> void:
	_camera.look_at_from_position(VIEWS[i][0], VIEWS[i][1])

func _process(_d: float) -> bool:
	_frame += 1
	if _frame == 2:
		_build()
		return false
	if _frame < 150:
		return false
	if (_frame - 150) % 8 != 0:
		return false
	if _shot >= VIEWS.size():
		return true
	var path := "%s/coworkers_%d.png" % [_out, _shot]
	_viewport.get_texture().get_image().save_png(path)
	print("wrote ", path)
	_shot += 1
	if _shot < VIEWS.size():
		_aim(_shot)
	return false
