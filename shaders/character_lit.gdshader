shader_type spatial;
render_mode ambient_light_disabled;

// Port of the Shader Forge shaders "Custom/shader_personaje" (Fortunato's suit,
// MAT_Kuro) and "Custom/shader_corbata" (his tie, MAT_Bluish) from the Unity
// original.
//
// Those two Unity shaders are the same program. Corbata is personaje with the
// light-wrapping term removed and the diffuse power at 1.0, so a black
// light_wrap_color and diffuse_power = 1.0 reproduce it exactly and both
// materials share this file.
//
// Colour space: Unity 5.4 ran this project in Gamma space
// (m_ActiveColorSpace: 0), meaning the shading math ran directly on
// sRGB-encoded values and the result reached the framebuffer untouched. Godot
// is linear-only, so shading here is done in gamma space and converted back on
// the way out. Without that the falloff curve lands well off the original:
// linear-space shading brightens the midtones the wrap term already lifts.
// Set gamma_space = false for ordinary linear shading.
//
// Ambient is a uniform rather than Godot's environment light (hence
// ambient_light_disabled) because the original read UNITY_LIGHTMODEL_AMBIENT,
// which came from the scene's flat ambient colour, not from a sky.

uniform bool gamma_space = true;

// _Color in the Unity material.
uniform vec4 albedo_color : source_color = vec4(0.029411793, 0.029411793, 0.029411793, 1.0);

// _Specular. Feeds both the direct highlight and the ambient specular term.
uniform vec4 specular_color : source_color = vec4(0.1029412, 0.1029412, 0.1029412, 1.0);

// _Gloss. Drives the Blinn exponent as exp2(gloss * 10 + 1), so 0.311 -> 17.3.
uniform float gloss : hint_range(0.0, 1.0) = 0.311;

// _LightWrappingColor. MAT_Kuro sets this to pure red, which is what makes the
// shadowed side of the suit bleed red. Black disables wrapping entirely.
uniform vec4 light_wrap_color : source_color = vec4(1.0, 0.0, 0.0, 1.0);

// Shader Forge's "diffpow" input on the Final node: 0.5 for the suit, 1.0 for
// the tie.
uniform float diffuse_power : hint_range(0.01, 4.0) = 0.5;

// UNITY_LIGHTMODEL_AMBIENT: nivelEscena's flat ambient colour.
uniform vec4 ambient_color : source_color = vec4(0.22352943, 0.23529413, 0.22352943, 1.0);

// Unity's base pass gated the highlight with floor(attenuation) - a full
// highlight where the surface is completely unshadowed and none at all
// anywhere else - while its additive passes used the attenuation directly.
// Godot's light() cannot tell the two apart, so this picks one. Left off by
// default: the smooth form matches the additive pass, differs from the base
// pass only inside shadows, and floor() would delete the point light's
// highlight outright, since an omni light's attenuation is below 1 almost
// everywhere.
uniform bool hard_shadow_specular = false;

// Inverse of the decode Godot's source_color hint applies, so the math below
// runs on the same numbers Unity's gamma pipeline used. The exact sRGB curve
// rather than a 2.2 approximation, to avoid a mismatched round trip.
vec3 to_gamma(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

vec3 to_linear(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

vec3 shading_space(vec3 c) {
	return gamma_space ? to_gamma(c) : c;
}

vec3 output_space(vec3 c) {
	return gamma_space ? to_linear(c) : c;
}

void fragment() {
	// Deliberately 1.0 rather than albedo_color: Godot multiplies DIFFUSE_LIGHT
	// by ALBEDO after light() returns, so setting the real albedo here would
	// apply it twice. It has to be applied inside light() instead, because the
	// gamma-space math needs it before the conversion back to linear - and with
	// an albedo this dark (0.029) the sRGB curve's straight segment makes
	// to_linear(a * b) and to_linear(a) * to_linear(b) meaningfully different.
	ALBEDO = vec3(1.0);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0; // light() supplies its own highlight.

	// Unity's indirect terms carry no light dependency, so they belong here
	// rather than in light(): Shader Forge emitted UNITY_LIGHTMODEL_AMBIENT
	// twice into indirectDiffuse ("Ambient Light" and "Diffuse Ambient Light"
	// are separate nodes wired to the same source), and once, times _Specular,
	// into indirectSpecular. Folding them into EMISSION keeps them alive even
	// with no lights in range.
	vec3 ambient = shading_space(ambient_color.rgb);
	vec3 indirect = ambient * 2.0 * shading_space(albedo_color.rgb)
			+ ambient * shading_space(specular_color.rgb);
	EMISSION = output_space(indirect);
}

void light() {
	vec3 albedo = shading_space(albedo_color.rgb);
	vec3 spec_color = shading_space(specular_color.rgb);
	// LIGHT_COLOR arrives pre-multiplied by PI: Godot's built-in Lambert divides
	// it back out inside its own diffuse term, so a shader that replaces light()
	// has to do that itself or every light lands PI times too bright. Measured,
	// not assumed - a constant DIFFUSE_LIGHT probe returned exactly PI * the
	// linear light colour.
	vec3 light_color = shading_space(LIGHT_COLOR / PI);

	// Light wrapping. The unlit side slides toward light_wrap_color instead of
	// reaching black, so the suit picks up red where it turns away.
	vec3 w = shading_space(light_wrap_color.rgb) * 0.5;
	float ndotl = dot(NORMAL, LIGHT);
	vec3 wrapped = pow(max(vec3(0.0), ndotl * (1.0 - w) + w), vec3(diffuse_power));

	DIFFUSE_LIGHT += output_space(wrapped * light_color * ATTENUATION * albedo);

	float spec_power = exp2(gloss * 10.0 + 1.0);
	vec3 half_dir = normalize(VIEW + LIGHT);
	float blinn = pow(max(0.0, dot(half_dir, NORMAL)), spec_power);
	float spec_atten = hard_shadow_specular ? floor(ATTENUATION) : ATTENUATION;

	SPECULAR_LIGHT += output_space(spec_atten * light_color * blinn * spec_color);
}
