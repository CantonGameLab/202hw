#version 440 core

#define MAX_DIRECTION_LIGHT 20
#define MAX_POINT_LIGHT 20

in vec3 f_world_pos;
in vec3 f_normal;
in vec2 f_uv;

uniform int			u_light_count;
uniform vec3  		u_light_positions[MAX_DIRECTION_LIGHT];
uniform vec3  		u_light_colors[MAX_DIRECTION_LIGHT];
uniform float 		u_light_intensities[MAX_DIRECTION_LIGHT];
uniform vec3  		u_light_directions[MAX_DIRECTION_LIGHT];
uniform sampler2D	u_light_shadow_maps[MAX_DIRECTION_LIGHT];
uniform mat4      	u_light_view_projs[MAX_DIRECTION_LIGHT];
uniform int       	u_light_has_shadow[MAX_DIRECTION_LIGHT];

uniform int			u_point_light_count;
uniform vec3  		u_point_light_positions[MAX_POINT_LIGHT];
uniform vec3  		u_point_light_colors[MAX_POINT_LIGHT];
uniform float		u_point_light_intensities[MAX_POINT_LIGHT];
uniform samplerCube u_point_light_shadow_maps[MAX_POINT_LIGHT];
uniform mat4		u_point_light_view_projs[MAX_POINT_LIGHT];
uniform int			u_point_light_has_shadow[MAX_POINT_LIGHT];
uniform mat4		u_camera_transform;

uniform vec4		u_base_color_factor;
uniform sampler2D	u_base_color_texture;
uniform int			u_has_base_color_texture;

uniform float		u_shininess;
uniform float		u_specular_strength;

out vec4			FragColor;

const float			SHADOW_BIAS_FLOOR = 0.003;
const float 		SHADOW_BIAS_SLOPE = 0.060;

const float 		AMBIENT = 0.11;

const float 		PCF_RADIUS = 1.;
const int			PCF_HALF_GRID = 4;

float pcf_visibility(sampler2D shadow_map, vec2 uv, float receiver_depth, float bias, float radius_texels) {
	vec2 texel = vec2(1.0) / vec2(textureSize(shadow_map, 0));

	// The half-texel shift puts every tap between four texels rather than on one, so the
	// bilinear filter returns their average. Sampling exactly on a texel centre returns that one
	// texel, which would make the filter a set of isolated points with hard steps between them.
	vec2 base = uv + texel * 0.5;

	float sum = 0.0;
	for (int y = -PCF_HALF_GRID; y < PCF_HALF_GRID; ++y) {
		for (int x = -PCF_HALF_GRID; x < PCF_HALF_GRID; ++x) {
			vec2 offset = texel * vec2(float(x), float(y)) * radius_texels;
			sum += receiver_depth <= texture(shadow_map, base + offset).r + bias ? 1.0 : 0.0;
		}
	}
	// The divisor is the number of taps, so this is a plain mean. It reads as 2 * half_grid
	// squared rather than as 4 * 4 so that changing the grid cannot leave it behind.
	float tap_count = float(2 * PCF_HALF_GRID) * float(2 * PCF_HALF_GRID);
	return sum / tap_count;
}


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
	for (int i = 0; i < MAX_DIRECTION_LIGHT; ++i) {
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

		// The fraction of the light source the surface sees, not a yes or no. A single texel
		// answers the question for one point of the light, and a shadow's edge is exactly where
		// the answer changes, so a single lookup draws that edge on the texel grid.
		float visibility = 1.0;
		vec4 in_light_position = u_light_view_projs[i] * vec4(f_world_pos, 1.0);
		vec3 shadow_coord = in_light_position.xyz / in_light_position.w;
		shadow_coord = shadow_coord * 0.5 + 0.5;

		if (u_light_has_shadow[i] != 0) {
			float slope = clamp(1.0 - dot(N, L), 0.0, 1.0);
			float shadow_bias = SHADOW_BIAS_FLOOR + SHADOW_BIAS_SLOPE * slope;
			visibility = pcf_visibility(
				u_light_shadow_maps[i], shadow_coord.xy, shadow_coord.z,
				shadow_bias, PCF_RADIUS
			);
		}

		// Halve the hemisphere that faces away from the light: N.L alone would
		// give a hard black rim at the terminator.
		float n_dot_l = max(dot(N, L), 0.0) * 0.5 + 0.5;

		vec3 H = normalize(L + V);
		float n_dot_h = max(dot(N, H), 0.0);

		vec3 radiance = u_light_colors[i] * u_light_intensities[i] * attenuation * visibility;

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

	// Added once, outside the loop, and it tints with the material rather than with any light.
	lit += base.rgb * AMBIENT;

	FragColor = vec4(lit, base.a);
}






