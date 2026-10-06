#version 440 core

// Measures what a cube lookup returns, against two candidate quantities.
//
// The shader under test compares a stored depth against a receiver depth, so the question that
// decides how much arithmetic is needed is what the stored value actually is: the fragment's
// straight-line distance to the light, or its distance along the axis of the face the lookup
// landed on. This draws both, and their difference, on a grid of floor points.

in vec2 f_uv;
out vec4 FragColor;

uniform samplerCube u_cube;
uniform vec3 u_light;
uniform float u_near;
uniform float u_far;
uniform int u_cells;
uniform int u_show;

float depth_to_distance(float stored, float z_near, float z_far) {
	return (z_near * z_far) / (z_far - stored * (z_far - z_near));
}

void main() {
	int cells = u_cells;
	int cell = clamp(int(gl_FragCoord.x) * cells / 1920, 0, cells - 1);
	int row = clamp(int(gl_FragCoord.y) * cells / 1080, 0, cells - 1);

	float gx = -1.40 + 2.80 * (float(cell) + 0.5) / float(cells);
	float gz = -1.40 + 2.80 * (float(row) + 0.5) / float(cells);
	vec3 world = vec3(gx, 0.0, gz);

	vec3 to_light = u_light - world;
	vec3 from_light = -to_light;

	float euclid = length(to_light);
	float axis = max(abs(from_light.x), max(abs(from_light.y), abs(from_light.z)));

	float stored = texture(u_cube, from_light).r;
	float stored_as_distance = depth_to_distance(stored, u_near, u_far);

	// 0 stored, 1 euclid, 2 axis, 3 the two ratios that answer the question
	float out_v = 0.0;
	if (u_show == 0) {
		out_v = clamp(stored_as_distance / 3.0, 0.0, 1.0);
	} else if (u_show == 1) {
		out_v = clamp(euclid / 3.0, 0.0, 1.0);
	} else if (u_show == 2) {
		out_v = clamp(axis / 3.0, 0.0, 1.0);
	} else if (u_show == 3) {
		out_v = clamp(stored_as_distance / max(axis, 1e-6) * 0.5, 0.0, 1.0);
	} else {
		out_v = clamp(stored_as_distance / max(euclid, 1e-6) * 0.5, 0.0, 1.0);
	}
	FragColor = vec4(vec3(out_v), 1.0);
}

