#version 440 core

// A top-down map of the floor: for every world point on the floor plane, this runs the
// project's own point-light shadow comparison and writes the result. Green means the point
// can see the light, red means the cube says something stands in the way, and near-black
// means the point is not covered by the cube at all (the light's frustum ends before it).
//
// The camera plays no part, so a shadow that the camera merely cannot see still shows up
// here, and a shadow that is not there cannot be blamed on the viewing angle.

in vec2 f_uv;
out vec4 FragColor;

uniform samplerCube u_cube;
uniform vec3 u_light;
uniform float u_near;
uniform float u_far;
uniform int u_cells;
uniform int u_show;
uniform float u_bias_check;

const float SPAN = 3.0;   // the map covers the floor from -1.5 to +1.5 on both axes

float point_distance_to_depth(float dist, float z_near, float z_far) {
	return (1.0 / dist - 1.0 / z_near) / (1.0 / z_far - 1.0 / z_near);
}

float axis_of(vec3 v) {
	vec3 a = abs(v);
	return max(a.x, max(a.y, a.z));
}

float bias_for(float axis_dist, float z_near, float z_far) {
	float dd = max(z_far - z_near, 1e-6);
	float slope = min(1.0 / max(1e-3, 1.0), 4.0);
	float texel_angle = 2.0 / 1024.0;
	return 2.0 * texel_angle * (0.25 + slope) * (dd / (z_far * z_near)) * axis_dist * axis_dist;
}

void main() {
	float wx = -SPAN * 0.5 + SPAN * gl_FragCoord.x / 1920.0;
	float wz = -SPAN * 0.5 + SPAN * gl_FragCoord.y / 1080.0;
	vec3 world = vec3(wx, 0.0, wz);

	vec3 from_light = world - u_light;
	float axis = axis_of(from_light);
	float stored = texture(u_cube, from_light).r;
	float receiver = point_distance_to_depth(axis, u_near, u_far);
	float bias = bias_for(axis, u_near, u_far);

	// What the cube would hold for an empty scene along this direction: the floor itself.
	float empty = point_distance_to_depth(axis, u_near, u_far);

	vec3 c;
	if (stored >= 0.999999) {
		// The far plane. Nothing was drawn along this direction at all, which for a floor
		// point means the direction left the cube's frustum before it reached the floor.
		c = vec3(0.05, 0.05, 0.9);
	} else {
		bool vis = receiver <= stored + bias;
		c = vis ? vec3(0.1, 0.8, 0.2) : vec3(0.95, 0.15, 0.1);
	}

	// The light's own position and the map's axes, drawn on top so the picture says which
	// way is which.
	float lx = (u_light.x + SPAN * 0.5) / SPAN * 1920.0;
	float lz = (u_light.z + SPAN * 0.5) / SPAN * 1080.0;
	if (abs(gl_FragCoord.x - lx) < 4.0 && abs(gl_FragCoord.y - lz) < 4.0) c = vec3(1.0, 1.0, 1.0);
	if (abs(gl_FragCoord.x - lx) < 26.0 && abs(gl_FragCoord.y - lz) < 1.5) c = vec3(1.0, 1.0, 0.0);
	if (abs(gl_FragCoord.y - lz) < 26.0 && abs(gl_FragCoord.x - lx) < 1.5) c = vec3(1.0, 1.0, 0.0);

	FragColor = vec4(c, 1.0);
}
