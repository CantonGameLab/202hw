#version 440 core

// Dumps one face of the point light's shadow cube as the depth it actually holds, together
// with the depth an unobstructed floor point along the same direction would have to produce.
// Blue means the face holds the far plane: nothing was rasterised along those directions.

in vec2 f_uv;
out vec4 FragColor;

uniform samplerCube u_cube;
uniform vec3 u_light;
uniform float u_near;
uniform float u_far;
uniform int u_cells;
uniform int u_show;      // 0 = -Y face, 1 = +Y face, 2 = +Z face
uniform float u_bias_check;

float point_distance_to_depth(float dist, float z_near, float z_far) {
	return (1.0 / dist - 1.0 / z_near) / (1.0 / z_far - 1.0 / z_near);
}

void main() {
	float u = (gl_FragCoord.x / 1920.0) * 2.0 - 1.0;
	float v = (gl_FragCoord.y / 1080.0) * 2.0 - 1.0;

	vec3 dir;
	if (u_show == 0)      dir = normalize(vec3( u, -1.0, -v));
	else if (u_show == 1) dir = normalize(vec3( u,  1.0,  v));
	else                  dir = normalize(vec3( u, -v,  1.0));

	float stored = texture(u_cube, dir).r;

	// Where does this direction meet the floor, and what is the light's axis distance there?
	float t = (dir.y < 0.0) ? (u_light.y / -dir.y) : -1.0;
	float floor_axis = -1.0;
	float floor_stored = -1.0;
	if (t > 0.0) {
		vec3 p = u_light + dir * t;
		if (abs(p.x) <= 1.5 && abs(p.z) <= 1.5) {
			vec3 a = abs(dir);
			float ax = max(a.x, max(a.y, a.z));
			floor_axis = t * ax;
			floor_stored = point_distance_to_depth(floor_axis, u_near, u_far);
		}
	}

	// The picture: red is the stored depth, green marks the depth the empty floor would need.
	// Where green sits above red, the floor under this direction is in shadow.
	vec3 c = vec3(0.0);
	c.r = clamp(stored, 0.0, 1.0);
	if (floor_stored >= 0.0) {
		c.g = clamp(floor_stored, 0.0, 1.0);
		c.b = (floor_stored > stored) ? 0.85 : 0.0;
	}
	if (stored > 0.99999) c = vec3(0.1, 0.1, 0.6);

	FragColor = vec4(c, 1.0);
}
