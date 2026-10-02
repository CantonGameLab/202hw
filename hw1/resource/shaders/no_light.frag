#version 440 core

#define MAX_LIGHTS 20

in vec3 f_world_pos;
in vec3 f_normal;
in vec2 f_uv;

uniform int   u_light_count;
uniform vec3  u_light_positions[MAX_LIGHTS];
uniform vec3  u_light_colors[MAX_LIGHTS];
uniform float u_light_intensities[MAX_LIGHTS];

// The travel direction of a directional light, meaning the way its rays go, not the way
// a surface points to reach it. It is zero for a point light, which has no single
// direction and is positioned instead -- so a zero here is also how the shader tells the
// two apart, without a separate kind array to keep in step.
uniform vec3  u_light_directions[MAX_LIGHTS];

// Shadow state, indexed by light slot rather than packed. The slots are light indices,
// so u_light_has_shadow is an array and not a count: with three lights of which only
// the second casts, the count would be one while the slot is two. u_light_view_projs is
// the same light view-projection the shadow pass rendered with, which is what makes the
// two depths comparable.
uniform sampler2D u_light_shadow_maps[MAX_LIGHTS];
uniform mat4      u_light_view_projs[MAX_LIGHTS];
uniform int       u_light_has_shadow[MAX_LIGHTS];

uniform mat4  u_camera_transform;

uniform vec4  u_base_color_factor;
uniform sampler2D u_base_color_texture;
uniform int   u_has_base_color_texture;

// Blinn-Phong exponents. These are not glTF roughness: roughness has to be mapped
// through a BRDF, which is a later step. 8..256 is the usable range for the
// classic Blinn-Phong lobe.
uniform float u_shininess;
uniform float u_specular_strength;

out vec4 FragColor;

// Two terms, not one. The floor term covers the depth error one shadow texel spans on a
// surface squarely facing the light. The slope term grows as the surface turns away from it,
// because a texel then covers a much longer stretch of that surface and the error grows with
// it. A single constant has to be sized for the worst slope in the scene, which makes it far
// too large on every surface that faces the light -- large enough to wash out real shadows.
const float SHADOW_BIAS_FLOOR = 0.003;
const float SHADOW_BIAS_SLOPE = 0.060;

void main() {
	// The factor is applied exactly once. Multiplying it in again after the texture
	// fetch squares it, which is invisible while the factor is (1,1,1,1) and wrong
	// the moment a material actually tints its base colour.
	vec4 base = u_base_color_factor;
	if (u_has_base_color_texture != 0) {
		base *= texture(u_base_color_texture, f_uv);
	}
	if (base.a < 0.01) {
		discard;
	}

	vec3 N = normalize(f_normal);
	vec3 V = normalize(u_camera_transform[3].xyz - f_world_pos);

	vec3 lit = vec3(0.0);
	for (int i = 0; i < MAX_LIGHTS; ++i) {
		if(i >= u_light_count) break;

		// A directional light is identified by carrying a travel direction. Its rays are
		// parallel and do not spread, so there is no distance falloff: dividing by the
		// squared distance to its nominal position would darken it by that distance even
		// though nothing about a sun gets dimmer with range.
		//
		// This is resolved before the shadow test rather than after it, because the bias
		// needs the angle at which the light meets the surface.
		vec3 L;
		float attenuation;
		if (dot(u_light_directions[i], u_light_directions[i]) > 0.0) {
			L = -normalize(u_light_directions[i]);
			attenuation = 1.0;
		} else {
			L = u_light_positions[i] - f_world_pos;
			float dist2 = dot(L, L);
			L = L * inversesqrt(max(dist2, 1e-8));
			attenuation = 1.0 / max(dist2, 1e-4);
		}

		bool is_illuminated = true;
		vec4 in_light_position = u_light_view_projs[i] * vec4(f_world_pos, 1.0);
		vec3 shadow_coord = in_light_position.xyz / in_light_position.w;
		shadow_coord = shadow_coord * 0.5 + 0.5;

		// Only lights that actually have a map are sampled. Sampling an unbound unit is
		// defined to return zero, which compares as "everything is deeper than the stored
		// depth" and would darken a light that casts no shadow at all.
		if (u_light_has_shadow[i] != 0) {
			if (shadow_coord.x < 0.0 || shadow_coord.x > 1.0 ||
			    shadow_coord.y < 0.0 || shadow_coord.y > 1.0 ||
			    shadow_coord.z > 1.0) {
				// Outside the light's box there is no depth to compare against. The map
				// uses CLAMP_TO_EDGE, so sampling here would return the border texel's
				// depth, which belongs to unrelated geometry.
			} else {
				float closest_depth = texture(u_light_shadow_maps[i], shadow_coord.xy).r;
				float slope = clamp(1.0 - dot(N, L), 0.0, 1.0);
				float shadow_bias = SHADOW_BIAS_FLOOR + SHADOW_BIAS_SLOPE * slope;
				is_illuminated = shadow_coord.z <= closest_depth + shadow_bias;
			}
		}

		// Halve the hemisphere that faces away from the light: N.L alone would
		// give a hard black rim at the terminator.
		float n_dot_l = max(dot(N, L), 0.0) * 0.5 + 0.5;

		vec3 H = normalize(L + V);
		float n_dot_h = max(dot(N, H), 0.0);

		vec3 radiance = u_light_colors[i] * u_light_intensities[i] * attenuation * float(is_illuminated);

		vec3 diffuse = base.rgb * n_dot_l;
		// Blinn-Phong specular is achromatic here and gated on the diffuse lobe, so
		// a back-facing surface cannot show a highlight.
		vec3 specular = vec3(u_specular_strength * pow(n_dot_h, u_shininess)) * n_dot_l;

		// radiance multiplies the BRDF's output; it is not added to it. Adding it makes
		// the light's own colour an extra brightness on top of a term the light does not
		// otherwise affect, so the shadow -- which only scales radiance -- ends up changing
		// the total by a constant instead of removing one light's contribution.
		lit += (diffuse + specular) * radiance;
	}

	FragColor = vec4(lit, base.a);
}






