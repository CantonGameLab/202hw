#version 440 core

// A copy of the project's no_light.frag with exactly one thing changed: the shaded colour
// is the visibility the cube filter returned for the point light rather than the light it
// modulates. The cube is sampled through the same call with the same arguments, so what
// this writes out is that call's own answer and nothing else.

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

const int			PCF_HALF_GRID = 4;

// Which light's visibility to write out. A negative value means "the nearest light that
// has an intensity", so the choice follows the scene instead of a hard-coded slot.
uniform int			u_probe_light;
uniform float		u_probe_bias;
// 0: the project's comparison, which puts the fragment's straight-line distance against a
//    depth the cube was rendered with
// 1: the same comparison with the fragment's distance measured the way the cube measures it
uniform int			u_probe_axis;

float point_depth_to_distance(float stored, float z_near, float z_far) {
	return (z_near * z_far) / (z_far - stored * (z_far - z_near));
}

float point_pcf_visibility(samplerCube shadow_map, vec3 dir, float z_near, float z_far, float receiver_dist, float bias, float radius) {
	vec3 up = abs(dir.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 tangent = normalize(cross(up, dir));
	vec3 bitangent = cross(dir, tangent);

	vec2 texel = vec2(1.0) / vec2(textureSize(shadow_map, 0));

	float receiver_depth = z_far / (z_far - receiver_dist * (z_far - z_near)) * (1.0 - z_near / receiver_dist);

	float sum = 0.0;
	for (int y = -PCF_HALF_GRID; y < PCF_HALF_GRID; ++y) {
		for (int x = -PCF_HALF_GRID; x < PCF_HALF_GRID; ++x) {
			vec3 tap = normalize(dir + (tangent * float(x) + bitangent * float(y)) * texel.x * radius);
			float stored_depth = texture(shadow_map, tap).r;
			sum += receiver_depth <= stored_depth + bias ? 1.0 : 0.0;
		}
	}
	float tap_count = float(2 * PCF_HALF_GRID) * float(2 * PCF_HALF_GRID);
	return sum / tap_count;
}

void main() {
	int chosen = -1;
	if (u_probe_light >= 0) {
		chosen = u_probe_light;
	} else {
		for (int i = 0; i < MAX_POINT_LIGHT; ++i) {
			if (i >= u_point_light_count) break;
			if (u_point_light_intensities[i] > 0.0) chosen = i;
		}
	}

	if (chosen < 0 || chosen >= u_point_light_count) {
		FragColor = vec4(0.5, 0.0, 0.5, 1.0);
		return;
	}

	vec3 to_light = u_point_light_positions[chosen] - f_world_pos;
	float dist = length(to_light);

	// The direction from the light towards this fragment. The cube is indexed by this, and
	// to_light points the other way; the two differ by a sign and by everything downstream
	// of it.
	vec3 from_light = -to_light;

	// The distance the cube measures along this direction. A cube face is projected with a
	// perspective frustum whose view axis is that face's normal, so the depth a texel holds
	// is the fragment's distance along the largest of its three components -- not its
	// straight-line distance. Measured on this scene: the floor lies 0.8 m below the light
	// along every -Y direction, and the cube holds exactly that for all of them, while the
	// straight-line distance to those points ranges from 0.8 m to 1.2 m.
	float axis_dist = dist * max(abs(from_light.x), max(abs(from_light.y), abs(from_light.z)));
	float receiver = (u_probe_axis == 0) ? dist : axis_dist;

	float vis = point_pcf_visibility(
		u_point_light_shadow_maps[chosen], to_light,
		u_point_light_nears[chosen], u_point_light_fars[chosen],
		receiver, u_probe_bias, 1.0
	);

	FragColor = vec4(vec3(vis), 1.0);
}
