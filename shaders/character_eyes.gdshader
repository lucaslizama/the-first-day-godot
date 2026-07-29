shader_type spatial;
render_mode unshaded;

// Port of the Shader Forge shader "Custom/shader_ojos" (Fortunato's eyes,
// MAT_Ojos) from the Unity original.
//
// Emission only, no lighting at all: the Unity Final node had nothing but its
// emission input wired. The shape is an inverted Fresnel scaled by 100000,
// which saturates almost immediately - so this is not a soft rim, it is a hard
// binary edge. Flat white where the surface faces the camera, black the instant
// it turns away. Keep fresnel_scale high; lowering it turns the eyes into a
// gradient the original never had.
//
// See character_lit.gdshader for why the gamma_space handling is here: Unity
// ran in Gamma colour space and Godot is linear-only. With a white _Emision and
// a mask this close to binary the conversion changes almost nothing, but it is
// kept so both shaders behave the same way if the colour is ever changed.

uniform bool gamma_space = true;

// _Emision in the Unity material.
uniform vec4 emission_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

// The Fresnel node's EXP input.
uniform float fresnel_exponent = 5.0;

// The multiplier the Fresnel was fed through before being inverted.
uniform float fresnel_scale = 100000.0;

vec3 to_gamma(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

vec3 to_linear(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void fragment() {
	float facing = max(0.0, dot(normalize(NORMAL), normalize(VIEW)));
	float fresnel = pow(1.0 - facing, fresnel_exponent);
	float mask = clamp(1.0 - fresnel * fresnel_scale, 0.0, 1.0);

	// unshaded: ALBEDO is written straight out.
	vec3 color = gamma_space
			? to_linear(mask * to_gamma(emission_color.rgb))
			: mask * emission_color.rgb;
	ALBEDO = color;
}
