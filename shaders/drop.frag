#version 450 core
// Dropped items (milestone 18), see drop.vert: lit like the blocks (sky
// light by the time of day), in the linear HDR scene.

layout(binding = 0) uniform sampler2DArray u_blocks;
layout(binding = 5) uniform sampler2D u_icons;
layout(location = 6) uniform float u_light;

in vec2 v_uv;
flat in uint v_layer;
flat in float v_shade;
flat in int v_flat;

out vec4 o_color;

void main() {
    vec4 c;
    if (v_flat == 1)
        c = texture(u_icons, v_uv);
    else
        c = texelFetch(u_blocks, ivec3(ivec2(clamp(v_uv, 0.0, 0.9999) * 16.0), int(v_layer)), 0);
    if (c.a < 0.3) discard;
    o_color = vec4(pow(c.rgb * v_shade * u_light, vec3(2.2)), 1.0);
}
