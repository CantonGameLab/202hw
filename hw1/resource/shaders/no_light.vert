#version 440 core

layout(location = 0) in vec3 v_position;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec4 v_tangent;
layout(location = 3) in vec2 uv_0;
layout(location = 4) in vec2 uv_1;

uniform mat4 m_proj;
uniform mat4 m_view;
uniform mat4 m_model;
// inverse(transpose(mat3(m_model))), computed on the CPU: a non-uniform scale
// would otherwise tilt the normals, and the matrix is constant per draw call.
uniform mat3 m_normal;

// Lighting happens in world space, so the interpolators carry world-space values.
out vec3 f_world_pos;
out vec3 f_normal;
out vec2 f_uv;

void main() {
	vec4 world = m_model * vec4(v_position, 1.0);
	f_world_pos = world.xyz;
	f_normal = m_normal * v_normal;
	f_uv = uv_0;
	gl_Position = m_proj * m_view * world;
}
