#version 450 core
// World sections: block textures from the texture array (animated frames,
// optional glow layer), directional face shading, fog into the sky colour.
// Milestone 14: output is linear HDR (the post pass tonemaps it); lighting
// is worked out in the textures' own (sRGB) space as before, then the
// result is converted to linear; glow layers shine above 1.0 (bloom); the
// sky light follows the sun and moon; distance + height fog take the sky's
// colour in the view direction. Milestone 13: smooth light (each quad's 4 corner lights mixed
// bilinearly), ambient occlusion, sky light x daylight, RGB block light and
// the held light.
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
layout(location = 10) uniform vec4 u_held;         // held light: rgb levels 0..15, w = on
layout(location = 11) uniform int u_light_flags;   // 1 smooth light, 2 ambient occlusion
layout(location = 12) uniform float u_daylight;    // sky light multiplier (--daylight)
layout(location = 13) uniform float u_cam_y;       // camera height (height fog)
layout(location = 14) uniform vec3 u_sun_dir;      // towards the sun (unit)
layout(location = 15) uniform float u_fog_base;    // height fog: thickest at and below this y

in vec3 v_rel;
in vec2 v_tuv;
flat in uint v_tint;
in vec2 v_uv;
flat in uint v_face;
flat in uvec2 v_layers;
flat in float v_mix;
flat in uint v_glow;
flat in uint v_level;
flat in uvec2 v_light;
flat in uint v_ao;
in vec2 v_cuv;

out vec4 o_color;

const float GLOW = 2.5;              // emissive layers: brightness (HDR, blooms)
const float HFOG_DENSITY = 0.0012;   // height fog per block at the base
const float HFOG_FALLOFF = 30.0;     // blocks for the height fog to thin by e

// ---- shared with sky.frag (keep the two copies the same) --------------------
vec3 sky_color(vec3 d, vec3 sun) {
    float e = sun.y;
    float day = smoothstep(-0.18, 0.12, e);
    float up = clamp(d.y, 0.0, 1.0);
    float hz = pow(1.0 - up, 4.0);                    // 1 at the horizon
    vec3 zen = mix(vec3(0.003, 0.005, 0.016), vec3(0.08, 0.27, 0.86), day);
    vec3 hor = mix(vec3(0.010, 0.015, 0.035), vec3(0.42, 0.62, 0.95), day);
    vec3 c = mix(zen, hor, hz);
    // sunrise and sunset: warm glow low on the sun's side, pink opposite
    float low = 1.0 - smoothstep(0.0, 0.35, abs(e + 0.04));
    vec2 sh = normalize(sun.xz + vec2(1e-5));
    vec2 dh = normalize(d.xz + vec2(1e-5));
    float side = dot(sh, dh) * 0.5 + 0.5;
    c += low * hz * (vec3(1.25, 0.42, 0.10) * pow(side, 3.0)
                     + vec3(0.22, 0.10, 0.20) * (1.0 - side));
    // below the horizon: the haze darkens a little
    c *= 1.0 - 0.35 * smoothstep(0.0, -0.4, d.y);
    return c;
}
// ------------------------------------------------------------------------------

// colour of the sky's light on surfaces (in the textures' space): white sun
// by day, warm near the horizon, dim blue moonlight at night
vec3 sky_light(vec3 sun) {
    float day = smoothstep(-0.12, 0.15, sun.y);
    vec3 sunc = mix(vec3(1.0, 0.62, 0.42), vec3(1.0, 0.98, 0.94), smoothstep(0.0, 0.4, sun.y));
    return mix(vec3(0.16, 0.19, 0.30), sunc, day);
}
const vec3 LUMA = vec3(0.30, 0.59, 0.11);
const vec3 WATER_REF = vec3(0.051, 0.345, 0.812);   // water_reference (0D58CF)
const float FACE_LIGHT[8] = float[](0.80, 0.80, 0.55, 1.0, 0.68, 0.68, 0.86, 0.86);
const float FADE = 0.08;   // cross-fade band: this share of the boundary's radius
const float AMBIENT = 0.03;  // light in total darkness
const float AO_MIN = 0.45;   // a corner closed on all three sides

vec4 corner(uint w) {
    return vec4(float(w & 15u), float((w >> 4) & 15u), float((w >> 8) & 15u),
                float((w >> 12) & 15u)) / 15.0;
}

// light level 0..1 -> brightness (gentle at the top, dark at the bottom)
vec3 curve(vec3 l) { return pow(l, vec3(1.6)); }

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

    // light: the 4 corners, mixed across the quad (flat: their mean)
    vec2 f = (u_light_flags & 1) != 0 ? clamp(v_cuv, 0.0, 1.0) : vec2(0.5);
    vec4 l = mix(mix(corner(v_light.x & 0xFFFFu), corner(v_light.x >> 16), f.x),
                 mix(corner(v_light.y >> 16), corner(v_light.y & 0xFFFFu), f.x), f.y);
    float ao = 1.0;
    if ((u_light_flags & 2) != 0) {
        vec4 a = vec4(float(v_ao & 3u), float((v_ao >> 2) & 3u),
                      float((v_ao >> 4) & 3u), float((v_ao >> 6) & 3u)) / 3.0;
        ao = mix(AO_MIN, 1.0, mix(mix(a.x, a.y, f.x), mix(a.w, a.z, f.x), f.y));
    }
    vec3 block = l.rgb;
    if (u_held.w > 0.0)                  // a light in the player's hand
        block = max(block, max(u_held.rgb - length(v_rel), 0.0) / 15.0);
    vec3 lit = max(curve(vec3(l.a)) * sky_light(u_sun_dir) * u_daylight, curve(block));
    color *= (AMBIENT + (1.0 - AMBIENT) * lit) * ao;
    color = pow(max(color, vec3(0.0)), vec3(2.2));    // to linear
    if (v_glow != 0u) {
        vec4 g = texture(u_blocks, vec3(v_uv, float(v_glow - 1u)));
        color = mix(color, pow(g.rgb, vec3(2.2)) * GLOW, g.a);
    }

    // fog: distance fog plus height fog (thicker low down), towards the sky
    float dist = length(v_rel);
    float fog_d = dist * u_fog;
    if ((u_light_flags & 4) != 0) {
        // height fog integrated along the ray: density * exp(-(y - base) / H)
        float y0 = (u_cam_y - u_fog_base) / HFOG_FALLOFF;
        float dy = v_rel.y / HFOG_FALLOFF;
        float k = abs(dy) > 1e-3 ? (1.0 - exp(-dy)) / dy : 1.0;
        fog_d += HFOG_DENSITY * dist * exp(-max(y0, 0.0)) * k;   // (no thicker below)
    }
    float fog = 1.0 - exp(-fog_d);
    // (near surfaces without sky light, i.e. caves: the fog is dark too)
    float sky_seen = max(l.a, smoothstep(48.0, 160.0, dist));
    vec3 fog_col = sky_color(normalize(v_rel), normalize(u_sun_dir))
                 * min(u_daylight * 1.5, 1.0) * sky_seen;
    float alpha = (u_pass == 2) ? c.a : 1.0;
    o_color = vec4(mix(color, fog_col, clamp(fog, 0.0, 1.0)), alpha);
}
