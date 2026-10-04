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

// A stand-in for the light that arrives without coming from any of the sources in the scene:
// light bounced off the floor and the surroundings. Blinn-Phong has no notion of it, and with
// a single directional light every shadowed fragment otherwise evaluates to exactly zero,
// which reads as a hole rather than as shade.
//
// It multiplies the material's own base colour rather than any light's colour, so it does not
// change hue when a light does, and it is added once for the whole surface rather than once
// per light, so adding a second light does not brighten the shadows twice.
//
// A constant because this whole model is on its way out; the replacement carries indirect
// light as an actual term and this line goes with it.
const float AMBIENT = 0.11;

// How far the shadow lookup spreads, as a multiple of the sampling grid's own spacing. A single
// texel's decision is a hard yes or no, so the edge of a shadow lands exactly on the texel grid
// and shows a stair of whole texels; averaging a neighbourhood turns that stair into a ramp.
// The width is in the map's own units rather than the world's, so it tracks the map's
// resolution: halving the map doubles this filter's width in metres and softens the edge with it.
const float PCF_RADIUS = 1.;
const int PCF_HALF_GRID = 4;

// Averages the lit-or-occluded decision over a neighbourhood of shadow texels and returns the
// fraction of them that are lit, which is the fraction of the light source the surface sees.
//
// The receiver's own depth is held constant across every tap: what is filtered is the
// comparison, not the depth it is compared against. Filtering the depth instead averages across
// a silhouette, which pulls the result towards the middle of the depth range and shows up as a
// dark halo on the lit side of the edge rather than as a soft edge.
//
// The taps are a 4 x 4 grid one texel apart, so they tile a 4 x 4 block of the map. The spacing
// is one texel and not the radius: a tap samples a point, so taps spread any further apart stop
// being a neighbourhood and become four unrelated lookups, which shows up as four offset copies
// of the shadow with nothing between them. radius_texels scales the whole grid instead, moving
// the taps off the map's texel centres without changing how far apart they are from each other.
//
// Cost: 16 texture fetches and 16 comparisons per light, against 1 of each for a single lookup.
// GPU relationship: the offsets are multiples of the map's texel size, so the filter is
// expressed entirely in the map's own coordinates and needs no knowledge of world scale.
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






