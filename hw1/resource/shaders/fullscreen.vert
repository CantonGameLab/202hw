#version 440 core

out vec2 f_uv;

// No vertex buffer and no attributes: the three vertices of a triangle that
// covers the viewport are derived from the vertex index. Positions outside
// [-1,1] are clipped away for free, which is why the triangle is oversized.
void main() {
    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    f_uv = p;
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
