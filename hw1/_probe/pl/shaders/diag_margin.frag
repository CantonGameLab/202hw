#version 440 core

// Draws how much room the shadow comparison has: the stored depth minus the receiver's
// depth, in depth units, centred on zero.
//
// Zero means the two sides are exactly equal -- the point is its own occluder, which is
// what an unoccluded surface looks like. Positive means the stored value is larger, so the
// point is lit with that much margin. Negative means something stands in front of it. The
// picture therefore shows both the shadow's shape and how much slack the comparison has
// against rounding, and a range is reported alongside it so the numbers are visible rather
// than inferred from the shading.

in vec2 f_uv;
out vec4 FragColor;

uniform samplerCube u_cube;
uniform vec3 u_light;
uniform float u_near;
uniform float u_far;
uniform int u_cells;
uniform float u_scale;
uniform float u_bias;
uniform int u_mode;

float point_depth_to_distance(float stored) {
	return (u_near * u_far) / (u_far - stored * (u_far - u_near));
}

float distance_to_depth(float dist, float z_near, float z_far) {
	return (1.0 / dist - 1.0 / z_near) / (1.0 / z_far - 1.0 / z_near);
}

void main() {
	int cell = clamp(int(gl_FragCoord.x) * u_cells / 1920, 0, u_cells - 1);
	int row = clamp(int(gl_FragCoord.y) * u_cells / 1080, 0, u_cells - 1);

	float gx = -1.40 + 2.80 * (float(cell) + 0.5) / float(u_cells);
	float gz = -1.40 + 2.80 * (float(row) + 0.5) / float(u_cells);
	vec3 world = vec3(gx, 0.0, gz);

	if (u_mode == 2) {
		// The point this cell stands for, so the reading of the picture can be checked
		// against the numbers that produced it instead of assumed.
		FragColor = vec4((gx + 1.5) / 3.0, (gz + 1.5) / 3.0, 0.0, 1.0);
		return;
	}

	vec3 to_light = u_light - world;
	float dist = length(to_light);
	vec3 from_light = -to_light;
	float axis_dist = dist * max(abs(from_light.x), max(abs(from_light.y), abs(from_light.z)));

	float stored = texture(u_cube, from_light).r;
	float receiver_depth = distance_to_depth(axis_dist, u_near, u_far);

	// What the shader's own line computes, term by term. The depth form is what the code
	// actually evaluates; the distance form is the same comparison rewritten, and having
	// both says which of the two is the tight one.
	float margin = (u_mode == 0) ? (stored - receiver_depth)
	                             : (point_depth_to_distance(stored) - axis_dist);

	FragColor = vec4(vec3(clamp(margin * u_scale + 0.5, 0.0, 1.0)), 1.0);
}
