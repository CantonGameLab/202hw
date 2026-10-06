#version 440 core

// Renders one light's six cube faces from a single node and hands the depth back as a
// colour in its own framebuffer, so the numbers can be read.
//
// The shadow pass writes depth only, and depth from a shadow pass is read back as a depth
// value whose scale depends on the projection in use. Drawing the same geometry in the same
// projections and writing distance-to-the-light straight into a colour target removes that
// dependence: what comes out is metres.

layout(location = 0) in vec3 v_position;

uniform mat4 u_light_mvp;
uniform vec3 u_light_pos;

out float f_axis_dist;
out float f_euclid_dist;
out float f_clip_depth;

void main() {
	vec4 world = vec4(v_position, 1.0);
	vec3 d = world.xyz - u_light_pos;
	f_euclid_dist = length(d);
	f_axis_dist = max(abs(d.x), max(abs(d.y), abs(d.z)));
	gl_Position = u_light_mvp * world;
	f_clip_depth = gl_Position.w;
}
