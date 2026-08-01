extends SceneTree

## Numeric check on death_distortion.gdshader.
##
##   godot-mono --headless --path . --script tools/verify_death_shader.gd -- <out_dir>
##
## Renders a synthetic source through the shader and, separately, without it, then predicts
## every pixel of the shaded render from the unshaded one and compares. Comparing against the
## engine's own unshaded render rather than an assumed source value keeps colour-space handling
## out of the comparison entirely - both renders travel the same path, so whatever transform sits
## between a Color and a stored byte cancels.
##
## The source's green channel is a linear ramp in x, which makes the shifted green tap
## predictable: bilinear filtering of a linear ramp is exact. Red and blue are constant, so they
## isolate the vignette mask.
##
## IT USED TO ASSERT NOTHING. For most of its life this file rendered three PNGs to /tmp and
## exited 0 - the comparison the paragraph above describes was left to a human with an image
## viewer, and nobody ever ran it. It sat in the tools/verify_* sweep reporting success
## unconditionally, which is worse than not existing, because it occupied the space where a
## missing check would have been noticed. It did not catch, and could not have caught, the
## shader never being instantiated in the level at all; tools/verify_death_effect.gd covers that
## and this one deliberately stays numeric.
##
## THE PREDICTION, straight off the shader:
##
##     mask(uv)   = max(1 - cornerWeight(uv) * (1/(1-vignette) - 1), 0)
##     uvG        = uv - texel * aberration * coords * cornerWeight(uv)
##     out.r      = src.r(uv)  * mask(uv)
##     out.b      = src.b(uv)  * mask(uv)
##     out.g      = src.g(uvG) * mask(uvG)      <- the green tap is shifted, r and b are not
##
## Two calibration facts, both measured rather than assumed, because guessing either would have
## produced a check that fails for the wrong reason:
##
##   * The multiply lands in STORED space, not linear. Predicting `src * mask` on the byte values
##     matches to 0.3; decoding to linear, multiplying and re-encoding is off by more than 10.
##   * With that model, max |error| over 5329 samples per case is 0.56 of an 8-bit unit - half a
##     quantisation step, i.e. rounding and nothing else. TOLERANCE is 1.0, which leaves a wide
##     margin over rounding while still catching any real change in the maths.
##
## Screen-space Y orientation is deliberately not pinned down, because nothing here can see it:
## cornerWeight is symmetric about 0.5 in y, and the mask depends on (2*uvG.y - 1) squared, which
## is invariant under uvG.y -> 1 - uvG.y. Green ramps in x only. So a flipped Y gives identical
## predictions and the check does not need to know.

const SHADER := "res://shaders/death_distortion.gdshader"
const SIZE := 512
const RED := 128
const BLUE := 64

## 8-bit units. See the calibration note above: observed worst case is 0.56.
const TOLERANCE := 1.0

## Sampling stride. 7 is coprime with 512, so the grid does not align to any power-of-two
## structure in the image and walks across texel phases rather than landing on the same one.
const STRIDE := 7

## The outermost texels are where the sampler's edge clamp and the viewport border interact;
## excluded because the shader's behaviour there is the sampler's, not the shader's.
const MARGIN := 2

# vignette_intensity, chromatic_aberration: the values GameManager writes at
# deathConstant 0 and 1.
const CASES := [
	["k0", 0.1, 2.0],
	["k1", 0.4, 10.0],
]

var _viewport: SubViewport
var _overlay: ColorRect
var _out := "/tmp"
var _frame := 0
var _stage := 0
var _images := {}
var _failures := 0
var _checks := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]

	_viewport = SubViewport.new()
	_viewport.size = Vector2i(SIZE, SIZE)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)

	var image := Image.create(SIZE, SIZE, false, Image.FORMAT_RGB8)
	for x in SIZE:
		var green := float(x) / float(SIZE - 1)
		for y in SIZE:
			image.set_pixel(x, y, Color8(RED, int(round(green * 255.0)), BLUE))

	var source := TextureRect.new()
	source.texture = ImageTexture.create_from_image(image)
	source.size = Vector2(SIZE, SIZE)
	_viewport.add_child(source)

	_overlay = ColorRect.new()
	_overlay.size = Vector2(SIZE, SIZE)
	var material := ShaderMaterial.new()
	material.shader = load(SHADER)
	_overlay.material = material
	_overlay.visible = false
	_viewport.add_child(_overlay)

	print("size=%d red=%d blue=%d tolerance=%.1f/255" % [SIZE, RED, BLUE, TOLERANCE])


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame < 150:
		return false
	if (_frame - 150) % 8 != 0:
		return false

	# Stage 0 grabs the source with the overlay hidden; each later stage grabs one
	# parameter case.
	if _stage == 0:
		_grab("source")
		_overlay.visible = true
		_apply(0)
		_stage += 1
		return false

	if _stage <= CASES.size():
		_grab(CASES[_stage - 1][0])
		if _stage < CASES.size():
			_apply(_stage)
		_stage += 1
		return false

	_analyse()
	return true


func _apply(index: int) -> void:
	var material := _overlay.material as ShaderMaterial
	material.set_shader_parameter("vignette_intensity", CASES[index][1])
	material.set_shader_parameter("chromatic_aberration", CASES[index][2])


## Keeps the render in memory for the comparison AND writes it out, since the PNGs are the thing
## to look at when a number below goes wrong.
func _grab(label: String) -> void:
	var image := _viewport.get_texture().get_image()
	_images[label] = image
	var path := "%s/death_%s.png" % [_out, label]
	var error := image.save_png(path)
	if error != OK:
		printerr("save failed (%d): %s" % [error, path])
	else:
		print("wrote ", path)


func _analyse() -> void:
	print("")
	var source: Image = _images["source"]

	for case in CASES:
		var label: String = case[0]
		var vignette: float = case[1]
		var aberration: float = case[2]
		var worst := _compare(source, _images[label], vignette, aberration)

		for channel in 3:
			_checks += 1
			var channel_name: String = ["red", "green", "blue"][channel]
			if worst[channel] <= TOLERANCE:
				_ok("%s  %-5s vignette %.2f aberration %4.1f px: worst error %.2f/255"
					% [label, channel_name, vignette, aberration, worst[channel]])
			else:
				_fail("%s  %s channel is off by %.2f/255, over the %.2f tolerance"
					% [label, channel_name, worst[channel], TOLERANCE])

	# The corners at k1. scaled = 1/(1-0.4) - 1 = 0.6667 and cornerWeight reaches 2, so the mask
	# goes to -0.33 and the shader's max(..., 0) is the only thing standing between that and
	# garbage. Unity got away without it because its render target clamped; this must not rely on
	# that, so the clamp is asserted directly.
	var k1: Image = _images["k1"]
	_checks += 1
	var corners := [
		Vector2i(0, 0),
		Vector2i(SIZE - 1, 0),
		Vector2i(0, SIZE - 1),
		Vector2i(SIZE - 1, SIZE - 1),
	]
	var brightest := 0.0
	for c in corners:
		var pixel := k1.get_pixel(c.x, c.y)
		brightest = maxf(brightest, maxf(pixel.r, maxf(pixel.g, pixel.b)) * 255.0)
	if brightest <= TOLERANCE:
		_ok("k1  the corners clamp to black rather than going negative (brightest %.2f/255)"
			% brightest)
	else:
		_fail("k1  a corner is %.2f/255, so the mask's max(..., 0) is not holding" % brightest)

	# NEGATIVE CONTROL. Everything above is a comparison that could pass by being insensitive -
	# which is exactly how this file spent its life. Predicting k1 with k0's parameters must be
	# REJECTED, or the numbers above prove nothing.
	_checks += 1
	var mispredicted := _compare(source, _images["k1"], CASES[0][1], CASES[0][2])
	var largest: float = maxf(mispredicted[0], maxf(mispredicted[1], mispredicted[2]))
	if largest > TOLERANCE:
		_ok("the comparison has teeth: k1 checked against k0's parameters is rejected, off by %.1f/255"
			% largest)
	else:
		_fail("k1 PASSES against k0's parameters, off by only %.2f/255 - this check cannot tell the two apart and proves nothing"
			% largest)

	print("")
	if _failures > 0:
		print("FAIL: %d of %d checks failed" % [_failures, _checks])
		quit(1)
	else:
		print("PASS: %d checks" % _checks)
		quit(0)


## Worst absolute per-channel error, in 8-bit units, between the shaded render and what the
## shader should have produced from the unshaded one.
func _compare(source: Image, shaded: Image, vignette: float, aberration: float) -> Array:
	var scaled := 1.0 / (1.0 - vignette) - 1.0
	var texel := 1.0 / float(SIZE)
	var worst := [0.0, 0.0, 0.0]

	var y := MARGIN
	while y < SIZE - MARGIN:
		var x := MARGIN
		while x < SIZE - MARGIN:
			var u := (float(x) + 0.5) * texel
			var v := (float(y) + 0.5) * texel
			var cx := (u - 0.5) * 2.0
			var cy := (v - 0.5) * 2.0
			var corner_weight := (cx * cx) + (cy * cy)

			var mask := maxf(1.0 - corner_weight * scaled, 0.0)
			var ug := u - (texel * aberration * cx * corner_weight)
			var vg := v - (texel * aberration * cy * corner_weight)
			var mask_green := maxf(
				1.0 - ((((ug - 0.5) * 2.0) ** 2) + (((vg - 0.5) * 2.0) ** 2)) * scaled, 0.0)

			var src := source.get_pixel(x, y)
			var got := shaded.get_pixel(x, y)

			var expected_r := src.r * mask
			var expected_b := src.b * mask
			var expected_g := _bilinear_green(source, ug, vg) * mask_green

			worst[0] = maxf(worst[0], absf(expected_r - got.r) * 255.0)
			worst[1] = maxf(worst[1], absf(expected_g - got.g) * 255.0)
			worst[2] = maxf(worst[2], absf(expected_b - got.b) * 255.0)
			x += STRIDE
		y += STRIDE

	return worst


## The green channel sampled the way the shader's sampler does: bilinear, clamped at the edges
## (the shader declares repeat_disable, filter_linear).
func _bilinear_green(image: Image, u: float, v: float) -> float:
	var fx := (clampf(u, 0.0, 1.0) * float(SIZE)) - 0.5
	var fy := (clampf(v, 0.0, 1.0) * float(SIZE)) - 0.5
	var x0 := int(floor(fx))
	var y0 := int(floor(fy))
	var tx := fx - float(x0)
	var ty := fy - float(y0)

	var g00 := _green_at(image, x0, y0)
	var g10 := _green_at(image, x0 + 1, y0)
	var g01 := _green_at(image, x0, y0 + 1)
	var g11 := _green_at(image, x0 + 1, y0 + 1)

	return lerpf(lerpf(g00, g10, tx), lerpf(g01, g11, tx), ty)


func _green_at(image: Image, x: int, y: int) -> float:
	return image.get_pixel(clampi(x, 0, SIZE - 1), clampi(y, 0, SIZE - 1)).g


func _ok(m: String) -> void:
	print("  ok    ", m)


func _fail(m: String) -> void:
	_failures += 1
	print("  FAIL  ", m)
