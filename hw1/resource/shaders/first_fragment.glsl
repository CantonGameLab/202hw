#version 440 core

out vec4 FragColor;

void main() {
	FragColor = vec4(gl_FragCoord.xyz, 1.0);
}
