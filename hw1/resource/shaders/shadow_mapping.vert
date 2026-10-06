#version 440 core

// The location is stated rather than left to the linker. The vertex array binds position at
// index 0, and without a qualifier the linker is free to assign this input any index it
// likes; if it picks another one, the shader reads whichever attribute lives there and
// rasterizes a different object than the one being drawn, with no error anywhere.
layout(location = 0) in vec3 v_position;

uniform mat4 u_light_mvp;

void main() {
	gl_Position = u_light_mvp * vec4(v_position, 1.);
}
