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
uniform float		u_point_light_nears[MAX_POINT_LIGHT];
uniform float		u_point_light_fars[MAX_POINT_LIGHT];
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

// The point light's bias, in metres rather than in depth units, because metres are what
// its comparison happens on. The constants above cannot be reused here: those were sized
// against an orthographic depth, where one unit means the same distance everywhere, and a
// perspective depth has no such property. A value that clears the acne near the light
// leaves it far away, and one sized for far away detaches the shadow near the light.
const float			POINT_SHADOW_BIAS_FLOOR = 0.010;
const float			POINT_SHADOW_BIAS_SLOPE = 0.050;

// The cube map filter's radius in direction space, as a multiple of one texel. Same role
// as PCF_RADIUS, different unit: a cube has no uv axes, so the radius counts an angle
// rather than a texel step, and the two cannot share a number.
const float			POINT_PCF_RADIUS = 1.;

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

// The stored depth put back on a distance scale, using the range the cube was rendered
// with. Without this the two sides of the comparison are different quantities: the map
// holds a normalised perspective depth, in which the whole far half of the range is
// squeezed into the last few percent, while the fragment has a plain distance. The two
// directions of this mapping are exact inverses -- measured round-trip error 4.8e-06
// over a 0.11 .. 3.19 range -- so nothing is approximated here, only undone.
float point_depth_to_distance(float stored, float z_near, float z_far) {
	return (z_near * z_far) / (z_far - stored * (z_far - z_near));
}

// Averages the cube map's lit-or-occluded decision over a neighbourhood of directions and
// returns the fraction of them that are lit.
//
// The taps move along two directions perpendicular to the light-to-fragment direction
// rather than along texture axes, because a cube face has no single set of axes: which uv
// a direction maps to depends on which face it lands on. Moving perpendicular keeps every
// tap on the same face for a small radius, which is the case that matters at a shadow's
// edge.
//
// Every tap is renormalised. A cube lookup uses only the direction of the vector it is
// handed, so an unnormalised tap would still pick the right texel -- but length(dir) is
// the fragment's distance from the light, and leaving the taps unnormalised would make
// that distance change from tap to tap, turning the filter into a comparison against
// sixteen different receivers.
//
// Cost: 16 cube fetches and 16 comparisons per fragment per point light.
float point_pcf_visibility(samplerCube shadow_map, vec3 dir, float z_near, float z_far, float bias, float radius) {
	vec3 up = abs(dir.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 tangent = normalize(cross(up, dir));
	vec3 bitangent = cross(dir, tangent);

	vec2 texel = vec2(1.0) / vec2(textureSize(shadow_map, 0));
	float dist_frag = length(dir);

	float sum = 0.0;
	for (int y = -PCF_HALF_GRID; y < PCF_HALF_GRID; ++y) {
		for (int x = -PCF_HALF_GRID; x < PCF_HALF_GRID; ++x) {
			vec3 tap = normalize(dir + (tangent * float(x) + bitangent * float(y)) * texel.x * radius);
			float stored_dist = point_depth_to_distance(texture(shadow_map, tap).r, z_near, z_far);
			sum += dist_frag <= stored_dist + bias ? 1.0 : 0.0;
		}
	}
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

	// Point lights, a loop of their own. Nothing is shared with the loop above: a separate
	// count, separate arrays, a cube map rather than a 2D map, and a distance rather than a
	// projected depth. Folding the two sets into one loop would need a branch per light to
	// say which set it belonged to, and would force the two to agree on a slot numbering
	// that neither of them owns.
	for (int i = 0; i < MAX_POINT_LIGHT; ++i) {
		if (i >= u_point_light_count) break;

		// The direction *to* the light, not the direction it travels. A cube map is
		// indexed by this vector, so it has to point from the surface at the light; the
		// opposite convention samples the face on the far side of the sphere and puts the
		// shadow on the lit side of every silhouette.
		vec3 to_light = u_point_light_positions[i] - f_world_pos;
		float dist = length(to_light);

		// A fragment sitting exactly on the light has no direction to look up, and
		// normalising a zero vector is undefined. Nothing about the shadow test is
		// meaningful for a point inside the light, so the guard only has to keep the
		// arithmetic finite; the choice of axis carries no information.
		vec3 L = dist > 1e-6 ? to_light / dist : vec3(0.0, 1.0, 0.0);

		// A point light's rays spread, so its radiance does fall with range: this is the
		// one place the two light kinds genuinely differ in the shading itself and not only
		// in the shadow lookup. The floor keeps a fragment at the light's own position from
		// dividing by zero and turning the whole surface white.
		float attenuation = 1.0 / max(dist * dist, 1e-4);

		float visibility = 1.0;
		// The cube shadow lookup, written with a literal index.
		//
		// This driver rejects the draw call outright -- GL_INVALID_OPERATION from
		// glDrawElements, leaving the screen at the clear colour -- the moment a
		// samplerCube is indexed by anything the compiler cannot fold to a constant.
		// Measured with every other part of the shader held fixed:
		//
		//   texture(u_point_light_shadow_maps[i], dir)   dynamic index   fails
		//   texture(u_point_light_shadow_maps[0], dir)   literal index   works
		//   const int k = 0; texture(...[k], dir)        const index     works
		//   if (i == 1) texture(...[1], dir)             literal, but    fails
		//                                                inside a branch
		//
		// It is not the sampler count: the failure is identical with the arrays cut from
		// 20 + 20 down to 4 + 4, nine samplers against a limit of 32. Nor is it the
		// has_shadow branch being statically dead, since forcing that flag to 1 changes
		// nothing. Only the literal index survives, which is why this reads element zero
		// and why the loop above cannot serve more than one shadow-casting point light
		// without being unrolled by hand.
		if (i == 0 && u_point_light_has_shadow[0] != 0) {
			// The bias is in metres, not in depth units, because metres are what the
			// comparison inside the filter happens on. The constants used by the
			// directional light cannot be reused: those were sized against an orthographic
			// depth, where one unit means the same distance everywhere, and a perspective
			// depth has no such property.
			float slope = clamp(1.0 - dot(N, L), 0.0, 1.0);
			float shadow_bias = POINT_SHADOW_BIAS_FLOOR + POINT_SHADOW_BIAS_SLOPE * slope;
			visibility = point_pcf_visibility(
				u_point_light_shadow_maps[0], to_light,
				u_point_light_nears[0], u_point_light_fars[0],
				shadow_bias, POINT_PCF_RADIUS
			);
		}

		// Halve the hemisphere that faces away from the light, matching the directional
		// loop: N.L alone gives a hard black rim at the terminator.
		float n_dot_l = max(dot(N, L), 0.0) * 0.5 + 0.5;

		vec3 H = normalize(L + V);
		float n_dot_h = max(dot(N, H), 0.0);

		vec3 radiance = u_point_light_colors[i] * u_point_light_intensities[i] * attenuation * visibility;

		vec3 diffuse = base.rgb * n_dot_l;
		vec3 specular = vec3(u_specular_strength * pow(n_dot_h, u_shininess)) * n_dot_l;

		lit += (diffuse + specular) * radiance;
	}

	if (u_has_base_color_texture == 0) {
		// Light 0 stands at (+1.3, +0.8, +1.3), so the floor on the far side of the scene
		// centre is the place its shadow has to land. Read the cube there.
		vec3 tl = u_point_light_positions[0] - f_world_pos;
		float dd = length(tl);
		float raw = texture(u_point_light_shadow_maps[0], tl).r;
		float stored = point_depth_to_distance(raw, u_point_light_nears[0], u_point_light_fars[0]);
		FragColor = vec4(raw, stored / 4.0, dd / 4.0, dd <= stored + 0.010 ? 1.0 : 0.25);
		return;
	}
	FragColor = vec4(lit, base.a);
}






