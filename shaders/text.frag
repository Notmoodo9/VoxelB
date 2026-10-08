#version 450 core
// Text / rectangle batch: glyphs are 1-bit masks from the font atlas.

layout(binding = 0) uniform sampler2D u_atlas;

in vec2 v_local;
flat in ivec2 v_cell;
flat in uint v_ch;
flat in vec4 v_color;

out vec4 o_color;

void main() {
    if (v_ch == 0u) {
        o_color = v_color;
        return;
    }
    float mask = texelFetch(u_atlas, v_cell + ivec2(v_local), 0).r;
    if (mask < 0.5)
        discard;
    o_color = v_color;
}
