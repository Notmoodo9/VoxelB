#version 450 core
// Item icons (milestone 18), see icon.vert. Pixel-art textures: level 0,
// nearest. Biome-tinted textures are already painted in their reference
// colours; water gets the reference water colour.

layout(binding = 0) uniform sampler2DArray u_blocks;

in vec2 v_uv;
flat in uint v_layer;
flat in float v_shade;
flat in uint v_tint;

out vec4 o_color;

const vec3 WATER_REF = vec3(0.051, 0.345, 0.812);
const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

void main() {
    vec2 uv = clamp(v_uv, 0.0, 0.9999);
    vec4 c = texelFetch(u_blocks, ivec3(ivec2(uv * 16.0), int(v_layer)), 0);
    if (c.a < 0.1) discard;
    if (v_tint == 3u) {
        c.rgb = WATER_REF * (dot(c.rgb, LUMA) / dot(WATER_REF, LUMA));
        c.a = max(c.a, 0.8);
    }
    o_color = vec4(c.rgb * v_shade, c.a);
}
