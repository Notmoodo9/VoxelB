#version 450 core
// Text / rectangle batch: one 32-byte record per glyph in an SSBO, six
// vertices per record (vertex pulling).

struct Glyph {
    vec4 rect;      // x, y, w, h in pixels (top-left origin)
    uint ch;        // character code, 0 = solid rectangle
    uint color;     // 0xAABBGGRR
    uint pad0;
    uint pad1;
};
layout(std430, binding = 0) readonly buffer Glyphs { Glyph glyphs[]; };

layout(location = 0) uniform vec2 u_screen;   // framebuffer size in pixels
layout(location = 1) uniform vec4 u_font;     // cell w, cell h, atlas columns, first char

out vec2 v_local;           // font-pixel position inside the cell
flat out ivec2 v_cell;      // cell origin in the atlas
flat out uint v_ch;
flat out vec4 v_color;

const vec2 CORNERS[6] = vec2[](vec2(0, 0), vec2(1, 0), vec2(1, 1),
                               vec2(0, 0), vec2(1, 1), vec2(0, 1));

void main() {
    Glyph g = glyphs[gl_VertexID / 6];
    vec2 c = CORNERS[gl_VertexID % 6];
    vec2 p = g.rect.xy + c * g.rect.zw;
    gl_Position = vec4(p.x / u_screen.x * 2.0 - 1.0, 1.0 - p.y / u_screen.y * 2.0, 0.0, 1.0);
    v_local = c * u_font.xy;
    uint idx = g.ch - uint(u_font.w);
    uint cols = uint(u_font.z);
    v_cell = ivec2(int(idx % cols) * int(u_font.x), int(idx / cols) * int(u_font.y));
    v_ch = g.ch;
    v_color = unpackUnorm4x8(g.color);
}
