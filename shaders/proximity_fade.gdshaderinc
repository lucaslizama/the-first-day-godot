// Fades a surface out as it approaches the camera, so geometry between the camera and the
// player stops filling the screen.
//
// Included by shaders/level_lit.gdshader and shaders/level_fade.gdshader. The props are all
// StandardMaterial3D and get the same effect from Godot's built-in `distance_fade_mode`
// instead - see tools/set_proximity_fade.py, which keeps the distances in this file's
// uniforms and the props' materials in lockstep.
//
// NOT part of the Unity original. The 2016 project had no fade of any kind: its camera
// asset (AdvancedUtilities BasicCameraController) shipped a ThicknessChecking feature that
// nivelEscena leaves disabled, and mat_generalTransparencia's transparency is driven by
// vertex colour for the dissolving platform columns, not by distance. This is a deliberate
// addition, and the reason is measurable: the camera holds a hard MinimumDistance of 2 m
// from the player, so in the starting room, which is smaller than that, it cannot retreat.
// Sampled across the room, 11 to 15 of every 24 view angles put a wall between the camera
// and the player.
//
// Two ways to hide a surface, and the choice per shader is deliberate:
//
//   * DITHER (this file's `proximity_fade_discard`) drops individual pixels in a 4x4
//     ordered pattern. The surface stays fully OPAQUE as far as the renderer is concerned.
//     Used by level_lit, the level's main opaque surface, and by the props via Godot's
//     equivalent DISTANCE_FADE_PIXEL_DITHER.
//   * ALPHA, simply multiplying into ALPHA, is smoother and has no grain. Used ONLY by
//     level_fade, whose columns are alpha-blended by the original's own vertex-colour
//     transparency - so multiplying costs nothing there and changes no render state.
//
// DO NOT "improve" level_lit to smooth alpha. That was tried and measured, and it changes
// how the level is LIT, not just how it fades. Giving level_lit `blend_mix,
// depth_prepass_alpha` and an ALPHA of the fade factor takes it off the opaque path, and on
// the starting-room view the mean frame colour went from (67, 72, 83) to (101, 106, 109) -
// a markedly brighter floor, plus a player shadow that is not there in the original. Same
// for the props at DISTANCE_FADE_PIXEL_ALPHA. With dither the same view is unchanged: mean
// colour identical to the baseline and 29 differing pixels out of 630,000.
//
// The cost of dither is honest and worth knowing: a surface at LOW opacity is drawn as
// isolated single pixels rather than a faint wash, so in the fade tail you get a sparse
// speckle - about 10 pixels in a 150x110 region in the worst case measured, against dark
// geometry. Smooth alpha has none of that. It is simply the cheaper of the two evils, since
// the other one alters the whole level's shading.

// Distance from the camera at which the surface is completely gone.
uniform float proximity_fade_near = 0.5;

// Distance at which it is fully solid again. Must exceed proximity_fade_near.
uniform float proximity_fade_far = 1.8;

// 4x4 ordered (Bayer) matrix, the standard screen-door pattern, arranged so that as the
// threshold rises the pixels that switch off are maximally spread out - which is what makes
// the result read as a uniform veil rather than as visible blocks.
//
// The thresholds are 1/16 .. 16/16, NOT the textbook 0/16 .. 15/16, and the difference is
// visible rather than pedantic. The rule below discards when `fade < threshold`. With a
// threshold of exactly 0, `0.0 < 0.0` is false, so one pixel in every 16 survives even at
// full fade - which showed up as a sparse white speckle of the vanished wall sprayed across
// everything behind it. Shifting the range up by one step makes the two ends exact: at
// fade 0 every threshold exceeds it and the surface is completely gone, and at fade 1
// nothing exceeds 1.0 so the surface is completely solid.
const float PROXIMITY_FADE_BAYER[16] = {
	 1.0 / 16.0,  9.0 / 16.0,  3.0 / 16.0, 11.0 / 16.0,
	13.0 / 16.0,  5.0 / 16.0, 15.0 / 16.0,  7.0 / 16.0,
	 4.0 / 16.0, 12.0 / 16.0,  2.0 / 16.0, 10.0 / 16.0,
	16.0 / 16.0,  8.0 / 16.0, 14.0 / 16.0,  6.0 / 16.0
};

// 0.0 where the surface should be invisible, 1.0 where it should be solid.
//
// `view_position` is the fragment's position in view space, which is what VERTEX holds in
// fragment(); its length is the distance to the camera. Deliberately not -view_position.z,
// the perpendicular depth, because that measures distance to the camera PLANE: a wall
// beside the camera would then read as near and fade while it was never in the way.
float proximity_fade_factor(vec3 view_position) {
	return smoothstep(proximity_fade_near, proximity_fade_far, length(view_position));
}

// True when this pixel should be dropped. Uses FRAGCOORD.xy, so the pattern is locked to
// the screen rather than to the surface - a dither anchored to the geometry would swim
// about as the camera moved.
bool proximity_fade_discard(float fade, vec2 frag_coord) {
	int x = int(mod(frag_coord.x, 4.0));
	int y = int(mod(frag_coord.y, 4.0));
	return fade < PROXIMITY_FADE_BAYER[y * 4 + x];
}
