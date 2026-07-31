shader_type spatial;
render_mode blend_mix, depth_draw_never, shadows_disabled, ambient_light_disabled;

#include "res://shaders/unity_gamma.gdshaderinc"
#include "res://shaders/proximity_fade.gdshaderinc"

// Port of the Shader Forge shader "Custom/shader_generalTransparencia" from the
// Unity original, used by mat_generalTransparencia - 57 references in
// nivelEscena, the most-used material in the level.
//
// Same Lambert-plus-ambient-once lighting as level_lit.gdshader, with two things
// layered on, both driven by the mesh's VERTEX COLOUR RED channel doing double
// duty:
//
//   * Wobble: the vertex is pushed along object-space (1,1,1) by
//     red * sin(speed * t) * 2.
//   * Transparency: alpha is 1 - red.
//
// So red areas of the mesh shimmer and are see-through, black areas stay solid
// and still, and the two effects are locked together by construction. That
// coupling is the effect - do not separate the two into independent controls.
//
// IMPORTANT: this depends on the meshes actually importing with vertex colours.
// Godot defaults COLOR to opaque white when a mesh has none, which makes alpha
// 1 - 1 = 0 and the geometry vanishes entirely. If a surface using this material
// disappears, check the vertex colours before suspecting the shader.
//
// shadows_disabled is faithful rather than a shortcut: Unity's base pass
// hardcoded attenuation = 1, so this surface never received shadows, while its
// additive pass used the real LIGHT_ATTENUATION. Disabling shadow reception
// while leaving ATTENUATION alone reproduces both at once - shadows off,
// distance falloff intact.

uniform bool gamma_space = true;

// _Color in mat_generalTransparencia, same value as mat_general.
uniform vec4 albedo_color : source_color = vec4(0.4582, 0.522, 0.522, 1.0);

uniform vec4 ambient_color : source_color = vec4(0.22352943, 0.23529413, 0.22352943, 1.0);

// _speed, 2.0 in the material.
uniform float wobble_speed = 2.0;

// The literal multiplier inside the Shader Forge graph, not a material property.
uniform float wobble_amplitude = 2.0;

vec3 shading_space(vec3 c) {
	return gamma_space ? to_gamma(c) : c;
}

vec3 output_space(vec3 c) {
	return gamma_space ? to_linear(c) : c;
}

void vertex() {
	// Unity displaced v.vertex before the model matrix, so this is object space -
	// which is Godot's default for VERTEX in vertex().
	float wobble = COLOR.r * (sin(wobble_speed * TIME) * wobble_amplitude);
	VERTEX += vec3(wobble);
}

void fragment() {
	ALBEDO = vec3(1.0);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
	// Vertex-colour transparency from the original, times the proximity fade. Multiplied
	// into ALPHA rather than dithered, unlike level_lit: this surface is alpha-blended
	// already, so a smooth fade is free here and dithering it would only add grain.
	// The multiply keeps the original's own transparency intact - a column that is
	// half see-through stays half see-through until the camera closes in on it.
	ALPHA = (1.0 - COLOR.r) * proximity_fade_factor(VERTEX);

	EMISSION = output_space(shading_space(ambient_color.rgb) * shading_space(albedo_color.rgb));
}

void light() {
	vec3 albedo = shading_space(albedo_color.rgb);
	vec3 light_color = shading_space(LIGHT_COLOR / PI);
	float ndotl = max(0.0, dot(NORMAL, LIGHT));

	DIFFUSE_LIGHT += output_space(ndotl * light_color * ATTENUATION * albedo);
}
