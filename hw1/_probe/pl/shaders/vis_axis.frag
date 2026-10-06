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
float visibility_dump = -1.0;
float receiver_dump = -1.0;
float axis_dump = -1.0;
float bias_dump = -1.0;

const float			SHADOW_BIAS_FLOOR = 0.003;
const float 		SHADOW_BIAS_SLOPE = 0.060;

const float 		AMBIENT = 0.11;

const float 		PCF_RADIUS = .2;
const int			PCF_HALF_GRID = 4;

const float			POINT_PCF_RADIUS = 1.;

const float			POINT_BIAS_TEXELS = 2.0;
const float			POINT_SLOPE_CLAMP = 4.0;

// The cube's face resolution, matching the renderer's request for the point light shadow
// pass. The bias needs it to turn one texel into the angle it covers.
const float			POINT_SHADOW_RESOLUTION = 1024.0;

float pcf_visibility(sampler2D shadow_map, vec2 uv, float receiver_depth, float bias, float radius_texels) {
	vec2 texel = vec2(1.0) / vec2(textureSize(shadow_map, 0));
	vec2 base = uv + texel * 0.5;

	float sum = 0.0;
	for (int y = -PCF_HALF_GRID; y < PCF_HALF_GRID; ++y) {
		for (int x = -PCF_HALF_GRID; x < PCF_HALF_GRID; ++x) {
			vec2 offset = texel * vec2(float(x), float(y)) * radius_texels;
			sum += receiver_depth <= texture(shadow_map, base + offset).r + bias ? 1.0 : 0.0;
		}
	}
	float tap_count = float(2 * PCF_HALF_GRID) * float(2 * PCF_HALF_GRID);
	return sum / tap_count;
}

float point_depth_to_distance(float stored, float z_near, float z_far) {
	return (z_near * z_far) / (z_far - stored * (z_far - z_near));
}

float point_distance_to_depth(float dist, float z_near, float z_far) {
	return (1.0 / dist - 1.0 / z_near) / (1.0 / z_far - 1.0 / z_near);
}

vec3 point_cube_direction(vec3 to_light) {
	return -to_light;
}

float point_axis_distance(vec3 from_light) {
	vec3 a = abs(from_light);
	return max(a.x, max(a.y, a.z));
}

float point_receiver_depth(vec3 from_light, float z_near, float z_far) {
	return point_distance_to_depth(point_axis_distance(from_light), z_near, z_far);
}

float point_texel_world_size(samplerCube shadow_map, float axis_dist) {
	float face_extent = 2.0 * axis_dist;
	return face_extent / float(textureSize(shadow_map, 0).x);
}

float point_shadow_bias(samplerCube shadow_map, float axis_dist, float n_dot_l) {
	float texel_world = point_texel_world_size(shadow_map, axis_dist);
	float slope = min((1.0 - n_dot_l) / max(n_dot_l, 1e-3), POINT_SLOPE_CLAMP);
	return POINT_BIAS_TEXELS * texel_world * (0.25 + slope);
}

float point_bias_depth(float axis_dist, float z_near, float z_far, float n_dot_l) {
	float dd = max(z_far - z_near, 1e-6);
	float slope = min((1.0 - n_dot_l) / max(n_dot_l, 1e-3), POINT_SLOPE_CLAMP);
	float texel_angle = 2.0 / POINT_SHADOW_RESOLUTION;
	return POINT_BIAS_TEXELS * texel_angle * (0.25 + slope) * (dd / (z_far * z_near)) * axis_dist * axis_dist;
}

float point_pcf_visibility(samplerCube shadow_map, vec3 dir, float z_near, float z_far, float receiver_axis, float bias_depth, float radius) {
	vec3 up = abs(dir.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 tangent = normalize(cross(up, dir));
	vec3 bitangent = cross(dir, tangent);

	vec2 texel = vec2(1.0) / vec2(textureSize(shadow_map, 0));

	float receiver_depth = point_distance_to_depth(receiver_axis, z_near, z_far);

	float sum = 0.0;
	for (int y = -PCF_HALF_GRID; y < PCF_HALF_GRID; ++y) {
		for (int x = -PCF_HALF_GRID; x < PCF_HALF_GRID; ++x) {
			vec3 tap = normalize(dir + (tangent * float(x) + bitangent * float(y)) * texel.x * radius);
			float stored_depth = texture(shadow_map, tap).r;
			sum += receiver_depth <= stored_depth + bias_depth ? 1.0 : 0.0;
		}
	}
	float tap_count = float(2 * PCF_HALF_GRID) * float(2 * PCF_HALF_GRID);
	return sum / tap_count;
}


vec3 aces_tonemap(vec3 x) {
	const float a = 2.51;
	const float b = 0.03;
	const float c = 2.43;
	const float d = 0.59;
	const float e = 0.14;
	return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}


void main() {
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

		float n_dot_l = max(dot(N, L), 0.0) * 0.5 + 0.5;

		vec3 H = normalize(L + V);
		float n_dot_h = max(dot(N, H), 0.0);

		vec3 radiance = u_light_colors[i] * u_light_intensities[i] * attenuation * visibility;

		vec3 diffuse = base.rgb * n_dot_l;
		vec3 specular = vec3(u_specular_strength * pow(n_dot_h, u_shininess)) * n_dot_l;

		lit += (diffuse + specular) * radiance;
	}

	lit += base.rgb * AMBIENT;

	for (int i = 0; i < MAX_POINT_LIGHT; ++i) {
		if (i >= u_point_light_count) break;

		vec3 to_light = u_point_light_positions[i] - f_world_pos;
		float dist = length(to_light);
		vec3 L = dist > 1e-6 ? to_light / dist : vec3(0.0, 1.0, 0.0);

		float attenuation = 1.0 / max(dist * dist, 1e-4);

		float visibility = 1.0;
		if (u_point_light_has_shadow[i] != 0) {
			vec3 from_light = point_cube_direction(to_light);
			float axis = point_axis_distance(from_light);
			float bias = point_bias_depth(
				axis, u_point_light_nears[i], u_point_light_fars[i], max(dot(N, L), 0.0)
			);
			visibility = point_pcf_visibility(
				u_point_light_shadow_maps[i], from_light,
				u_point_light_nears[i], u_point_light_fars[i], axis,
				bias, POINT_PCF_RADIUS
			);
			visibility_dump = visibility;
			receiver_dump = point_distance_to_depth(axis, u_point_light_nears[i], u_point_light_fars[i]);
			axis_dump = axis;
			bias_dump = bias;
		}

		float n_dot_l = max(dot(N, L), 0.0) * 0.5 + 0.5;

		vec3 H = normalize(L + V);
		float n_dot_h = max(dot(N, H), 0.0);

		vec3 radiance = u_point_light_colors[i] * u_point_light_intensities[i] * attenuation * visibility;

		vec3 diffuse = base.rgb * n_dot_l;
		vec3 specular = vec3(u_specular_strength * pow(n_dot_h, u_shininess)) * n_dot_l;

		lit += (diffuse + specular) * radiance;
	}

	FragColor = vec4(vec3(axis_dump / 8.0), 1.0);
}
