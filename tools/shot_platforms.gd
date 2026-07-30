extends SceneTree

## Renders scenes/platforms.tscn on its own, with the level's two lights but none
## of its geometry, so the platforms can be judged without the shell in the way.
## Each platform is a 2 x 2 m top face on a 20 m column that fades out downward,
## which is easy to mistake for level architecture in a full-level shot.
##
##   --script tools/shot_platforms.gd -- <out-dir>

var _viewport: SubViewport
var _camera: Camera3D
var _out := "/tmp"
var _frame := 0
var _shot := 0

## Camera position and aim point per shot.
## Aimed obliquely on purpose. A camera looking straight down is degenerate
## against the default up vector and produces a basis that renders nonsense.
const VIEWS := [
	## Eye height, looking along the collapsing walkway the way the player crosses
	## it: 8 falling platforms tiling edge to edge, with a 2 m gap at z = -50.97.
	[Vector3(0.0, 1.6, -41.0), Vector3(0.0, 1.0, -62.0)],
	## The same walkway from three-quarters above, where the 2 x 2 m tops read as
	## squares and the gap is unambiguous.
	[Vector3(12.0, 10.0, -38.0), Vector3(0.0, -3.0, -53.0)],
	## Side elevation: the 20 m columns and the downward fade the vertex colours
	## drive through mat_generalTransparencia.
	[Vector3(24.0, -3.0, -53.0), Vector3(0.0, -7.0, -53.0)],
	## The moving platforms, spread over x -8..11 and z -102..-132. At rest each
	## body sits 5 m along its local -x, the start of the slide, so the tops are
	## offset from their instance origins.
	[Vector3(22.0, 16.0, -94.0), Vector3(0.0, -3.0, -117.0)],
]

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	_out = a[0] if a.size() > 0 else "/tmp"

func _build() -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(1200, 800)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.05, 0.05, 0.06)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.22352943, 0.23529413, 0.22352943)
	env.environment = e
	_viewport.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.light_color = Color(1.0, 0.95686275, 0.8392157)
	_viewport.add_child(sun)
	sun.look_at_from_position(Vector3(20.0, 30.0, -30.0), Vector3(0.0, 0.0, -60.0))

	_viewport.add_child((load("res://scenes/platforms.tscn") as PackedScene).instantiate())
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
	var path := "%s/platforms_%d.png" % [_out, _shot]
	_viewport.get_texture().get_image().save_png(path)
	print("wrote ", path)
	_shot += 1
	if _shot < VIEWS.size():
		_aim(_shot)
	return false
