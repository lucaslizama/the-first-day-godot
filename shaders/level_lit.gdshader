shader_type spatial;
render_mode ambient_light_disabled;

#include "res://shaders/unity_gamma.gdshaderinc"

// Port of the Shader Forge shader "Custom/shader_general" from the Unity
// original, used by mat_general - 27 references in nivelEscena, the level's main
// opaque surface.
//
// Much simpler than the character shaders: plain Lambert times a flat colour,
// with ambient added once. No specular, no light wrapping, no diffuse power.
//
// Note "once": shader_personaje and shader_corbata added
// UNITY_LIGHTMODEL_AMBIENT to indirect diffuse twice, because Shader Forge wired
// both its Ambient Light and Diffuse Ambient Light inputs. This graph wires only
// one, so this shader is genuinely half as bright in shadow as the character
// shaders, not a simplification of them.
//
// See character_lit.gdshader for why ALBEDO is 1.0 and why LIGHT_COLOR is
// divided by PI - both are engine behaviours that silently break a replaced
// light() function.

uniform bool gamma_space = true;

// _Color in mat_general.
uniform vec4 albedo_color : source_color = vec4(0.4582, 0.522, 0.522, 1.0);

// UNITY_LIGHTMODEL_AMBIENT: nivelEscena's flat ambient colour.
uniform vec4 ambient_color : source_color = vec4(0.22352943, 0.23529413, 0.22352943, 1.0);

vec3 shading_space(vec3 c) {
	return gamma_space ? to_gamma(c) : c;
}

vec3 output_space(vec3 c) {
	return gamma_space ? to_linear(c) : c;
}

void fragment() {
	// 1.0, not albedo_color: Godot multiplies DIFFUSE_LIGHT by ALBEDO after
	// light() returns, so the real albedo is applied inside light() instead.
	ALBEDO = vec3(1.0);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;

	// Ambient carries no light dependency, so it belongs here and survives with
	// no lights in range.
	EMISSION = output_space(shading_space(ambient_color.rgb) * shading_space(albedo_color.rgb));
}

void light() {
	vec3 albedo = shading_space(albedo_color.rgb);
	vec3 light_color = shading_space(LIGHT_COLOR / PI);
	float ndotl = max(0.0, dot(NORMAL, LIGHT));

	DIFFUSE_LIGHT += output_space(ndotl * light_color * ATTENUATION * albedo);
}
