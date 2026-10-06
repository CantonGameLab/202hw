#version 440 core

in vec2 f_uv;
out vec4 FragColor;

uniform samplerCube u_cube;
uniform vec3 u_dir;

void main() {
	vec3 dir = length(u_dir) > 0.0 ? u_dir : normalize(vec3(f_uv * 2.0 - 1.0, -1.0));
	float d = texture(u_cube, dir).r;
	FragColor = vec4(vec3(d), 1.0);
}
