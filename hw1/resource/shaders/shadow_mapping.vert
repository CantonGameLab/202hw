#version 440 core

in vec3 v_position;

uniform mat4 u_light_mvp;

void main() {
	gl_Position = u_light_mvp * vec4(v_position, 1.);
}
