shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never;

// Port of the Shader Forge shader "Custom/shader_torta" from the Unity original,
// used by mat_torta on the cake at the end of the level.
//
// Emission only, additive, and entirely hardcoded: the Unity shader declares no
// Properties at all. A pulsing rim glow, greyscale:
//
//   glow = pow(1 - max(0, dot(N, V)), 10) * 2 * sin(2 * t)
//
// The sine is deliberately unclamped in the original, so it spends half its
// period negative. With Blend One One that subtracts nothing visible - the
// framebuffer clamps at zero - so the glow pulses on and off rather than
// oscillating smoothly. Clamped here for the same result without relying on the
// blend to hide negative values.
//
// mat_torta stores a _Color of white and a _speed of 2, but shader_torta declares
// neither property, so both are ignored by Unity and are not carried over. The
// exponent, the doubling and the sine's rate are the graph's own literals, exposed
// here as uniforms only so they can be tuned; the defaults are the original.

uniform float rim_exponent = 10.0;
uniform float rim_strength = 2.0;
uniform float pulse_speed = 2.0;
uniform vec3 glow_tint : source_color = vec3(1.0, 1.0, 1.0);

void fragment() {
	float facing = max(0.0, dot(normalize(NORMAL), normalize(VIEW)));
	float rim = pow(1.0 - facing, rim_exponent);
	float pulse = sin(pulse_speed * TIME);

	// unshaded: ALBEDO is written straight out, and blend_add adds it.
	ALBEDO = max(rim * rim_strength * pulse, 0.0) * glow_tint;
}
