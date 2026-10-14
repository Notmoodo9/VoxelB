#version 450 core
// First person: the arm and what it holds, see held.vert.

layout(binding = 0) uniform sampler2DArray u_blocks;
layout(location = 6) uniform float u_light;      // brightness where the player is

in vec2 v_uv;
flat in uint v_layer;
flat in float v_shade;
flat in int v_part;
flat in vec3 v_color;
in vec3 v_arm;

out vec4 o_color;

// the arm's look: skin with the sleeve of a plain tunic (pixel art: 4 x 12
// pixels around, a little noise per pixel)
const vec3 SKIN = vec3(0.86, 0.64, 0.50);
const vec3 SLEEVE = vec3(0.24, 0.42, 0.46);
const float SLEEVE_END = 0.42;                   // of the arm's length from the elbow

float hash(vec3 p) { return fract(sin(dot(p, vec3(12.9898, 78.233, 37.719))) * 43758.5453); }

void main() {
    vec3 c;
    if (v_part == 0) {
        vec3 px = floor(v_arm * vec3(4.0, 12.0, 4.0));
        bool sleeve = v_arm.y < SLEEVE_END;
        c = sleeve ? SLEEVE : SKIN;
        c *= 0.94 + 0.08 * hash(px);
        if (sleeve && px.y == floor(SLEEVE_END * 12.0) - 1.0) c *= 0.82;   // the cuff
    } else if (v_part == 1) {
        vec4 t = texelFetch(u_blocks, ivec3(ivec2(clamp(v_uv, 0.0, 0.9999) * 16.0), int(v_layer)), 0);
        if (t.a < 0.3) discard;
        c = t.rgb;
    } else {
        c = v_color;
    }
    o_color = vec4(c * v_shade * u_light, 1.0);
}
