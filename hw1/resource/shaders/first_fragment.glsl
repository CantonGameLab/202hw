#version 440 core

out vec4 FragColor;

uniform vec2 resolution;

void main() {
	vec2 normalize_uv = gl_FragCoord.xy / resolution;

	FragColor = vec4(normalize_uv, normalize_uv);
}
