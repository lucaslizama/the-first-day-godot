// Shared colour-space helpers for the shaders ported from Unity.
//
// Unity 5.4 ran this project in Gamma colour space (m_ActiveColorSpace: 0):
// shading math ran directly on sRGB-encoded values and the result reached the
// framebuffer untouched. Godot is linear-only, so the ported shaders do their
// lighting math in gamma space and convert back on the way out. Without that the
// colours come out right but the falloff curve does not.
//
// to_gamma is the exact inverse of the decode Godot's source_color hint applies,
// using the real sRGB curve rather than a 2.2 approximation so the round trip
// does not introduce its own error.

vec3 to_gamma(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

vec3 to_linear(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}
