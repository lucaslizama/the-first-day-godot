shader_type canvas_item;

// Port of the two image-effect passes Unity's GameManager drove through
// VignetteAndChromaticAberration: Hidden/Vignetting pass 0, then
// Hidden/ChromaticAberration pass 1.
//
// The scene configured the effect as mode: Simple with blur: 0, which strips it
// down to two per-pixel operations with no intermediate render targets, so both
// fold into this single pass:
//
//   * Vignette darkens by a radial mask, a plain multiply.
//   * "Simple" chromatic aberration offsets ONLY the green channel along the
//     radial direction. Red and blue are untouched - that asymmetry is the
//     effect, not an oversight.
//
// Combining them is exact rather than an approximation: the vignette is a
// per-pixel multiply by mask(uv), so applying mask at each sample's own uv gives
// the same result as vignetting the whole buffer and then sampling it. The green
// tap therefore uses mask(uvG), not mask(uv).
//
// Unity's remaining knobs are inert at these settings: axialAberration,
// blurSpread, luminanceDependency and blurDistance are only read by the advanced
// pass (2) and the blur prepass, neither of which runs.

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;

// GameManager wrote 0.1 + 0.3 * deathConstant here.
uniform float vignette_intensity : hint_range(0.0, 0.95) = 0.1;

// GameManager wrote 2.0 + 8.0 * deathConstant here. Measured in pixels, since
// Unity scaled it by _MainTex_TexelSize.
uniform float chromatic_aberration : hint_range(0.0, 32.0) = 2.0;

// Radial falloff shared by both effects: 0 at the centre, 2 at the corners.
float corner_weight(vec2 uv) {
	vec2 coords = (uv - 0.5) * 2.0;
	return dot(coords, coords);
}

float vignette_mask(vec2 uv) {
	// Unity fed the shader 1/(1 - intensity) - 1 rather than intensity itself.
	float scaled = 1.0 / (1.0 - vignette_intensity) - 1.0;
	// Clamped low because the original goes negative in the corners once
	// intensity passes ~0.33 - at 10 deaths the mask reaches -0.33 - and Unity
	// only avoided garbage because the render target clamped it to black.
	return max(1.0 - corner_weight(uv) * scaled, 0.0);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 texel = 1.0 / vec2(textureSize(screen_texture, 0));
	vec2 coords = (uv - 0.5) * 2.0;

	vec2 uv_green = uv - texel * chromatic_aberration * coords * corner_weight(uv);

	vec3 color = texture(screen_texture, uv).rgb * vignette_mask(uv);
	color.g = texture(screen_texture, uv_green).g * vignette_mask(uv_green);

	COLOR = vec4(color, 1.0);
}
