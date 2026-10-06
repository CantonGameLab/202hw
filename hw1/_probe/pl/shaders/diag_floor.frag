#version 440 core

// For a set of world points on the floor, this computes what the shadow comparison on each
// side of the `<=` actually is, and samples the cube along the very direction it compares
// against. Nothing here depends on a convention being assumed correctly: the direction is
// passed through the same `texture()` call the real shader uses, so the face it lands on is
// the sampler's choice.

in vec2 f_uv;
out vec4 FragColor;

uniform samplerCube u_cube;
uniform vec3 u_light;
uniform float u_near;
uniform float u_far;
uniform int u_cells;
uniform int u_show;
uniform float u_bias_check;

float point_depth_to_distance(float stored, float z_near, float z_far) {
	return (z_near * z_far) / (z_far - stored * (z_far - z_near));
}

void main() {
	int cells = u_cells;
	int cell = int(gl_FragCoord.x) * cells / 1920;
	int row = int(gl_FragCoord.y) * cells / 1080;
	cell = clamp(cell, 0, cells - 1);
	row = clamp(row, 0, cells - 1);

	// A grid on the floor, in the light's own half of it.
	float gx = -1.40 + 2.80 * (float(cell) + 0.5) / float(u_cells);
	float gz = -1.40 + 2.80 * (float(row) + 0.5) / float(u_cells);
	vec3 world = vec3(gx, 0.0, gz);

	vec3 to_light = u_light - world;
	float dist = length(to_light);
	vec3 unit = to_light / dist;
	float axis_comp = max(abs(unit.x), max(abs(unit.y), abs(unit.z)));
	float axis_dist = dist * axis_comp;

	// The cube is indexed by the direction from the light towards the point, which is
	// to_light negated. Sampling along to_light asks about the opposite hemisphere, where
	// nothing on this floor lies, and the empty result says so.
	float stored = texture(u_cube, -to_light).r;
	float stored_axis = point_depth_to_distance(stored, u_near, u_far);

	// The ray the fragment's own direction describes, solved on paper: it meets the floor
	// at t = 1, because both ends of it are on the floor and its direction is the one from
	// the fragment to the light. So the depth the cube must hold along this direction is
	// the axis distance of the fragment itself, unless something stands in the way.
	float ratio = stored_axis / max(axis_dist, 1e-6);

	float out_v = 0.0;
	if (u_show == 0) {
		out_v = clamp(ratio, 0.0, 2.0) * 0.5;         // 1.0 means the cube holds this point
	} else if (u_show == 1) {
		out_v = clamp(stored_axis / 4.0, 0.0, 1.0);   // the stored value, as a distance
	} else if (u_show == 2) {
		out_v = clamp(axis_dist / 4.0, 0.0, 1.0);     // the fragment's axis distance
	} else if (u_show == 3) {
		out_v = clamp(dist / 4.0, 0.0, 1.0);          // the fragment's straight-line distance
	} else {
		out_v = u_bias_check;                         // whatever the caller put here
	}
	FragColor = vec4(vec3(out_v), 1.0);
}
