#version 450 core
// World sections, Milestone 7 shading: block textures from the texture
// array (animated frames, optional glow layer), simple directional face
// shading and distance fog into the sky colour. Lighting arrives in M13.
// u_pass: 0 opaque, 1 cutout (alpha test), 2 translucent (blended).
// Milestone 12: every LOD level (0 = full-detail sections) keeps to its ring
// around the camera, u_lod_r[level - 1] .. u_lod_r[level]; neighbouring
// levels cross-fade over a band inside each boundary with a screen-door
// dither (complementary thresholds, so a pixel shows exactly one of them).

layout(binding = 0) uniform sampler2DArray u_blocks;
layout(binding = 3) uniform sampler2DArray u_tint;   // biome colours (layer 0 grass, 1 foliage, 2 water)
layout(binding = 4) uniform sampler2DArray u_lod_tint;  // the LOD tiles' colours
layout(location = 5) uniform int u_pass;
layout(location = 6) uniform int u_lod_levels;     // 0: no LOD
layout(location = 7) uniform vec4 u_lod_ra;        // ring radii r0..r3 (blocks, xz)
layout(location = 8) uniform vec4 u_lod_rb;        //   r4, r5
layout(location = 9) uniform float u_fog;          // fog density

in vec3 v_rel;
in vec2 v_tuv;
flat in uint v_tint;
in vec2 v_uv;
flat in uint v_face;
flat in uvec2 v_layers;
flat in float v_mix;
flat in uint v_glow;
flat in uint v_level;

out vec4 o_color;

const vec3 SKY = vec3(0.33, 0.62, 0.98);
const vec3 LUMA = vec3(0.30, 0.59, 0.11);
const vec3 WATER_REF = vec3(0.051, 0.345, 0.812);   // water_reference (0D58CF)
const float FACE_LIGHT[8] = float[](0.80, 0.80, 0.55, 1.0, 0.68, 0.68, 0.86, 0.86);
const float FADE = 0.08;   // cross-fade band: this share of the boundary's radius

// interleaved gradient noise: a stable per-pixel threshold in [0, 1)
float dither() {
    return fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
}

// ring radius i (constant branches: no indexed uniform arrays)
float ring(int i) {
    if (i <= 0) return u_lod_ra.x;
    if (i == 1) return u_lod_ra.y;
    if (i == 2) return u_lod_ra.z;
    if (i == 3) return u_lod_ra.w;
    if (i == 4) return u_lod_rb.x;
    return u_lod_rb.y;
}

vec3 tint(float layer) {
    return (v_level > 0u ? texture(u_lod_tint, vec3(v_tuv, layer))
                         : texture(u_tint, vec3(v_tuv, layer))).rgb * 3.984375;
}

void main() {
    // (a radius that never arrived, 0, clips nothing)
    if (u_lod_levels > 0 && u_lod_ra.x > 0.0) {
        int lv = min(int(v_level), u_lod_levels);
        float d = length(v_rel.xz);
        float t = dither();
        float ro = ring(lv);
        if (lv < u_lod_levels) {             // fade out towards the next level
            float w = ro * FADE;
            if (t < clamp((d - (ro - w)) / w, 0.0, 1.0)) discard;
        } else if (d >= ro) discard;
        if (lv > 0) {                        // fade in over the previous level's band
            float ri = ring(lv - 1), w = ri * FADE;
            if (t >= clamp((d - (ri - w)) / w, 0.0, 1.0)) discard;
        }
    }
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
        vec3 f = tint(2.0);
        float l = dot(c.rgb, LUMA) / dot(WATER_REF, LUMA);
        c.rgb = WATER_REF * f * l;
    } else if (v_tint != 0u)   // biome colour as a factor (64 = 1.0, so up to 4x)
        c.rgb *= tint(float(v_tint - 1u));
    vec3 color = c.rgb * FACE_LIGHT[v_face];
    if (v_glow != 0u) {
        vec4 g = texture(u_blocks, vec3(v_uv, float(v_glow - 1u)));
        color = mix(color, g.rgb * 1.15, g.a);
    }

    float dist = length(v_rel);
    float fog = 1.0 - exp(-dist * u_fog);    // light: mountain vistas (M14: real fog)
    float alpha = (u_pass == 2) ? c.a : 1.0;
    o_color = vec4(mix(color, SKY, clamp(fog, 0.0, 1.0)), alpha);
}
