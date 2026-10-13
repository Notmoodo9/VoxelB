#version 450 core
// Menus and HUD (milestone 17): one 64-byte record per quad in a storage
// buffer, six vertices each (vertex pulling). Kinds: 0 rounded rectangle
// (vertical gradient), 1 SDF glyph, 2 glass panel (blurred backdrop), 3 soft
// glow / shadow around a rounded rectangle, 4 image (uv into u_images), 5 item icon
// (uv into u_icons).

struct Quad {
    vec4 rect;       // x, y, w, h (pixels, top-left origin)
    vec4 uv;         // glyph / image: atlas u0, v0, u1, v1
    vec4 p;          // radius, glow size, border width, glyph weight
    uint color;      // 0xAABBGGRR (top)
    uint color2;     // bottom colour / border colour
    uint kind;
    uint pad;
};
layout(std430, binding = 0) readonly buffer Quads { Quad q[]; };

layout(location = 0) uniform vec2 u_screen;

out vec2 v_local;          // pixels from the rectangle's top-left corner
out vec2 v_uv;
flat out vec2 v_size;
flat out vec4 v_color;
flat out vec4 v_color2;
flat out vec4 v_p;
flat out uint v_kind;

const vec2 C[6] = vec2[](vec2(0, 0), vec2(1, 0), vec2(1, 1), vec2(0, 0), vec2(1, 1), vec2(0, 1));

void main() {
    Quad Q = q[gl_VertexID / 6];
    vec2 c = C[gl_VertexID % 6];
    float m = (Q.kind == 3u) ? Q.p.y : 1.0;          // room for the glow / AA
    if (Q.kind == 1u || Q.kind >= 4u) m = 0.0;
    vec2 pos = Q.rect.xy - m + c * (Q.rect.zw + 2.0 * m);
    v_local = pos - Q.rect.xy;
    v_uv = mix(Q.uv.xy, Q.uv.zw, c);
    v_size = Q.rect.zw;
    v_color = unpackUnorm4x8(Q.color);
    v_color2 = unpackUnorm4x8(Q.color2);
    v_p = Q.p;
    v_kind = Q.kind;
    gl_Position = vec4(pos.x / u_screen.x * 2.0 - 1.0, 1.0 - pos.y / u_screen.y * 2.0, 0.0, 1.0);
}
