#version 440 core

#define MAX_LIGHTS 20

in vec3 f_world_pos;
in vec3 f_normal;
in vec2 f_uv;

uniform int   u_light_count;
uniform vec3  u_light_positions[MAX_LIGHTS];
uniform vec3  u_light_colors[MAX_LIGHTS];
uniform float u_light_intensities[MAX_LIGHTS];

uniform mat4  u_camera_transform;

uniform vec4  u_base_color_factor;
uniform sampler2D u_base_color_texture;
uniform int   u_has_base_color_texture;

// Blinn-Phong exponents. These are not glTF roughness: roughness has to be mapped
// through a BRDF, which is a later step. 8..256 is the usable range for the
// classic Blinn-Phong lobe.
uniform float u_shininess;
uniform float u_specular_strength;

out vec4 FragColor;

void main() {
	// The factor is applied exactly once. Multiplying it in again after the texture
	// fetch squares it, which is invisible while the factor is (1,1,1,1) and wrong
	// the moment a material actually tints its base colour.
	vec4 base = u_base_color_factor;
	if (u_has_base_color_texture != 0) {
		base *= texture(u_base_color_texture, f_uv);
	}
	if (base.a < 0.01) {
		discard;
	}

	vec3 N = normalize(f_normal);
	vec3 V = normalize(u_camera_transform[3].xyz - f_world_pos);

	vec3 lit = vec3(0.0);
	for (int i = 0; i < MAX_LIGHTS; ++i) {
		if(i >= u_light_count) {
			break;
		}

		vec3 L = u_light_positions[i] - f_world_pos;
		float dist2 = dot(L, L);
		L = L * inversesqrt(dist2);

		float attenuation = 1.0 / max(dist2, 1e-4);
		// Halve the hemisphere that faces away from the light: N.L alone would
		// give a hard black rim at the terminator.
		float n_dot_l = max(dot(N, L), 0.0) * 0.5 + 0.5;

		vec3 H = normalize(L + V);
		float n_dot_h = max(dot(N, H), 0.0);

		vec3 radiance = u_light_colors[i] * u_light_intensities[i] * attenuation;

		vec3 diffuse = base.rgb * n_dot_l;
		// Blinn-Phong specular is achromatic here and gated on the diffuse lobe, so
		// a back-facing surface cannot show a highlight.
		vec3 specular = vec3(u_specular_strength * pow(n_dot_h, u_shininess)) * n_dot_l;

		lit += (diffuse + specular) * radiance;
	}

	FragColor = vec4(lit, base.a);
}
