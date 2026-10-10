#version 450 core
// World sections, Milestone 7 shading: block textures from the texture
// array (animated frames, optional glow layer), simple directional face
// shading and distance fog into the sky colour. Lighting arrives in M13.
// u_pass: 0 opaque, 1 cutout (alpha test), 2 translucent (blended).

layout(binding = 0) uniform sampler2DArray u_blocks;
layout(binding = 3) uniform sampler2DArray u_tint;   // biome colours (layer 0 grass, 1 foliage, 2 water)
layout(location = 5) uniform int u_pass;

in vec3 v_rel;
in vec2 v_tuv;
flat in uint v_tint;
in vec2 v_uv;
flat in uint v_face;
flat in uvec2 v_layers;
flat in float v_mix;
flat in uint v_glow;

out vec4 o_color;

const vec3 SKY = vec3(0.33, 0.62, 0.98);
const vec3 LUMA = vec3(0.30, 0.59, 0.11);
const vec3 WATER_REF = vec3(0.051, 0.345, 0.812);   // water_reference (0D58CF)
const float FACE_LIGHT[8] = float[](0.80, 0.80, 0.55, 1.0, 0.68, 0.68, 0.86, 0.86);

void main() {
    vec4 c = texture(u_blocks, vec3(v_uv, float(v_layers.x)));
    if (v_mix > 0.0)
        c = mix(c, texture(u_blocks, vec3(v_uv, float(v_layers.y))), v_mix);

    if (u_pass == 1) {
        // alpha test that keeps its coverage in the smaller mip levels, so
        // distant leaves don't thin out
        float lod = textureQueryLod(u_blocks, v_uv).x;
        float a = c.a * (1.0 + max(lod, 0.0) * 0.3);
        if (a < 0.5) discard;
    }

    if (v_tint == 3u) {
        // water: recolour to the biome's water colour, keeping the texture's
        // brightness (ripples and sparkles stay light instead of turning
        // yellow under a strong red factor)
        vec3 f = texture(u_tint, vec3(v_tuv, 2.0)).rgb * 3.984375;
        float l = dot(c.rgb, LUMA) / dot(WATER_REF, LUMA);
        c.rgb = WATER_REF * f * l;
    } else if (v_tint != 0u)   // biome colour as a factor (64 = 1.0, so up to 4x)
        c.rgb *= texture(u_tint, vec3(v_tuv, float(v_tint - 1u))).rgb * 3.984375;
    vec3 color = c.rgb * FACE_LIGHT[v_face];
    if (v_glow != 0u) {
        vec4 g = texture(u_blocks, vec3(v_uv, float(v_glow - 1u)));
        color = mix(color, g.rgb * 1.15, g.a);
    }

    float dist = length(v_rel);
    float fog = 1.0 - exp(-dist * 0.0013);   // light: mountain vistas (M14: real fog)
    float alpha = (u_pass == 2) ? c.a : 1.0;
    o_color = vec4(mix(color, SKY, clamp(fog, 0.0, 1.0)), alpha);
}
