extends SceneTree

## Renders a scene from an explicit camera position and target, so a single prop can
## be inspected without the camera ending up inside geometry.
##
##   godot-mono --path . --script tools/shot_at.gd -- <out.png> camx camy camz tgtx tgty tgtz [scene]
##
## Not --headless: that uses the dummy rasteriser, which cannot render and simply
## hangs. On a machine with no display use `xvfb-run -a` and drop --headless.
##
## The camera arguments used to be silently ignored. level.tscn contains its own
## Camera3D (the third-person player camera), and Godot makes the first camera to
## enter a viewport the current one - so the camera this script adds second was never
## active, and every shot came out from the player's viewpoint no matter what
## coordinates were passed. That cost a whole port's worth of screenshots: the level
## was only ever inspected from the spawn, and a mirrored-placement bug across the
## entire level had to be caught by raycast statistics and by a human looking at the
## game instead.
##
## So this script now does three things it did not before: it clears `current` on
## every camera in the loaded scene, it calls make_current() on its own, and it
## VERIFIES it actually owns the viewport before saving, failing loudly if not. A
## screenshot tool that quietly shows you the wrong view is worse than no tool.

const SETTLE_FRAMES := 160
const SIZE := Vector2i(900, 700)

var _vp: SubViewport
var _out := ""
var _scene := "res://scenes/level.tscn"
var _cam_pos := Vector3.ZERO
var _tgt := Vector3.ZERO
var _cam: Camera3D
var _frame := 0
var _failed := false


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() < 7:
		# Previously this fell through to a degenerate (0,0,0) -> (0,0,0) camera and
		# rendered something anyway, which hid the mistake.
		print("usage: shot_at.gd -- <out.png> camx camy camz tgtx tgty tgtz [scene]")
		_failed = true
		quit(2)
		return

	_out = a[0]
	_cam_pos = Vector3(float(a[1]), float(a[2]), float(a[3]))
	_tgt = Vector3(float(a[4]), float(a[5]), float(a[6]))
	if a.size() >= 8:
		_scene = a[7]

	if _cam_pos.is_equal_approx(_tgt):
		print("camera position and target are the same point; nothing to look at")
		_failed = true
		quit(2)


func _process(_d: float) -> bool:
	if _failed:
		return true

	_frame += 1
	if _frame == 2:
		_vp = SubViewport.new()
		_vp.size = SIZE
		_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(_vp)

		var packed := load(_scene) as PackedScene
		if packed == null:
			print("cannot load ", _scene)
			_failed = true
			quit(2)
			return true
		var scene_root := packed.instantiate()
		_vp.add_child(scene_root)

		# Stand down the scene's own cameras first, so nothing competes for the
		# viewport. Without this the player camera wins simply by entering first.
		var stood_down := _release_cameras(scene_root)
		if stood_down > 0:
			print("stood down %d camera(s) belonging to the scene" % stood_down)

		_cam = Camera3D.new()
		_vp.add_child(_cam)
		_look()
		_cam.make_current()
		return false

	if _frame < SETTLE_FRAMES:
		return false

	# Re-assert and then check. A script in the scene could have taken the viewport
	# during its _ready or while these frames ran; if that happens the shot is of the
	# wrong view and must not be presented as the requested one.
	_cam.make_current()
	_look()
	var active := _vp.get_camera_3d()
	if active != _cam:
		print("FAILED: the viewport is owned by '%s', not this script's camera."
			% [active.name if active != null else "<none>"])
		print("        The requested position was ignored, so no image was written.")
		print("        Something in %s claims the camera; give this one priority." % _scene)
		quit(1)
		return true

	_vp.get_texture().get_image().save_png(_out)
	print("wrote %s  from %.3v looking at %.3v" % [_out, _cam_pos, _tgt])
	return true


func _look() -> void:
	# look_at_from_position errors if the view direction is parallel to up, so pick a
	# different up vector for a straight-down or straight-up shot.
	var up := Vector3.UP
	if absf((_tgt - _cam_pos).normalized().dot(Vector3.UP)) > 0.999:
		up = Vector3.FORWARD
	_cam.look_at_from_position(_cam_pos, _tgt, up)


## Clears `current` on every Camera3D in the tree, returning how many were found.
func _release_cameras(node: Node) -> int:
	var n := 0
	if node is Camera3D:
		(node as Camera3D).current = false
		n += 1
	for child in node.get_children():
		n += _release_cameras(child)
	return n
