#version 440 core

in float f_axis_dist;
in float f_euclid_dist;
in float f_clip_depth;

uniform int u_show;
uniform float u_near;
uniform float u_far;
uniform float u_scale;

out vec4 FragColor;

// The depth a perspective projection writes for a fragment whose view-space z is z_view:
// (f+n)/(f-n)/2 + 1/2 + (f*n)/(f-n)/z_view, which is the value a depth buffer holds and the
// value the shadow test compares against.
float z_to_depth(float z_view) {
	return ((u_far + u_near) / (u_far - u_near)) * 0.5 + 0.5
		+ ((u_far * u_near) / (u_far - u_near)) / z_view;
}

void main() {
	float v = 0.0;
	if (u_show == 0) {
		v = f_axis_dist * u_scale;
	} else if (u_show == 1) {
		v = f_euclid_dist * u_scale;
	} else if (u_show == 2) {
		v = z_to_depth(f_clip_depth);
	} else {
		v = f_clip_depth * u_scale;
	}
	FragColor = vec4(vec3(v), 1.0);
}
