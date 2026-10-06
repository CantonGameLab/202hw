#version 440 core

in vec2 f_uv;
out vec4 frag_color;

uniform sampler2D u_screen_texture;

// The multisampled attachment is already resolved into this texture, so a plain
// texel fetch is the whole job. No tone mapping and no sRGB conversion: the
// pipeline has neither anywhere else, and adding one here would make this pass
// disagree with the shading pass.
void main() {
    frag_color = vec4(texture(u_screen_texture, f_uv).rgb, 1.0);
}
