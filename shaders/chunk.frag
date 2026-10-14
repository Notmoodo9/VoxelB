#version 450 core
// World sections: block textures from the texture array (animated frames,
// optional glow layer), directional face shading, fog into the sky colour.
// Milestone 14: output is linear HDR (the post pass tonemaps it); lighting
// is worked out in the textures' own (sRGB) space as before, then the
// result is converted to linear; glow layers shine above 1.0 (bloom); the
// sky light follows the sun and moon; distance + height fog take the sky's
// colour in the view direction. Milestone 15: water surfaces (translucent
// pass) are shaded from copies of the opaque scene: refraction, depth-based
// absorption and scattering, screen-space reflections with a sky fallback,
// Fresnel, sun glints and shore foam. Milestone 13: smooth light (each quad's 4 corner lights mixed
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
layout(location = 17) uniform int u_shadows;       // cascades in use (0: off)
layout(location = 18) uniform vec3 u_cam_mod;      // camera position mod 4096
layout(location = 19) uniform int u_water;         // 1 refraction & co., 2 + reflections
layout(location = 0) uniform mat4 u_viewproj;      // (shared with chunk.vert)
layout(location = 4) uniform float u_time;         // (shared with chunk.vert)
layout(binding = 8) uniform sampler2D u_refr_color;  // the opaque scene (HDR)
layout(binding = 9) uniform sampler2D u_refr_depth;  // its depth (reverse-Z)
layout(binding = 7) uniform sampler2DArrayShadow u_shadow_map;
// milestone 14 part 2: shadow cascades (shaders/shadow_setup.comp)
struct ShadowData { mat4 m[4]; vec4 splits; vec4 light; vec4 texel; vec4 origin[4]; };
layout(std430, binding = 7) readonly buffer Shadow { ShadowData sd; };

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

const float SKY_FILL = 0.48;         // sky light that reaches shadowed / sun-averted faces
const vec3 FACE_NORMAL[6] = vec3[](vec3(-1, 0, 0), vec3(1, 0, 0), vec3(0, -1, 0),
                                   vec3(0, 1, 0), vec3(0, 0, -1), vec3(0, 0, 1));
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

// the light reaching camera-relative point v_rel + n offset in cascade c
float cascade_lit(int c, vec3 n) {
    float ts = sd.texel[c];
    // into the camera-relative space the cascade was drawn in (it may be a
    // frame old), wrapping the mod-4096 difference
    vec3 delta = u_cam_mod - sd.origin[c].xyz;
    delta -= 4096.0 * round(delta / 4096.0);
    vec3 p = v_rel + delta + n * ts * 1.5;
    vec4 s = sd.m[c] * vec4(p, 1.0);
    vec2 uv = s.xy * 0.5 + 0.5;
    float ref = s.z + ts * 0.25 / 640.0;          // small constant bias (depth units)
    vec2 o = vec2(0.5) / vec2(textureSize(u_shadow_map, 0).xy);
    return 0.25 * (texture(u_shadow_map, vec4(uv + vec2(-o.x, -o.y), float(c), ref))
                 + texture(u_shadow_map, vec4(uv + vec2( o.x, -o.y), float(c), ref))
                 + texture(u_shadow_map, vec4(uv + vec2(-o.x,  o.y), float(c), ref))
                 + texture(u_shadow_map, vec4(uv + vec2( o.x,  o.y), float(c), ref)));
}

// direct light (sun or moon) reaching this point, 0..1: the cascade by
// distance (blended into the next one over the last fifth of its range, so
// no sharp seam slides along the ground as the camera moves), a normal
// offset against acne, 4 hardware-filtered taps (PCF)
float shadow_at(vec3 n, float dist) {
    if (u_shadows <= 0) return 1.0;
    int c = 0;
    while (c < u_shadows - 1 && dist > sd.splits[c]) ++c;
    float last = sd.splits[u_shadows - 1];
    if (dist > last) return 1.0;
    float lit = cascade_lit(c, n);
    if (c < u_shadows - 1) {
        float lo = c > 0 ? sd.splits[c - 1] : 0.0;
        float edge = sd.splits[c];
        float k = smoothstep(edge - 0.2 * (edge - lo), edge, dist);
        if (k > 0.0) lit = mix(lit, cascade_lit(c + 1, n), k);
    }
    // fade out over the last tenth of the shadow distance
    return mix(lit, 1.0, smoothstep(last * 0.9, last, dist));
}

// colour of the sky's light on surfaces (in the textures' space): white sun
// by day, warm near the horizon, dim blue moonlight at night
vec3 sky_light(vec3 sun) {
    float day = smoothstep(-0.12, 0.15, sun.y);
    vec3 sunc = mix(vec3(1.0, 0.62, 0.42), vec3(1.0, 0.98, 0.94), smoothstep(0.0, 0.4, sun.y));
    return mix(vec3(0.16, 0.19, 0.30), sunc, day);
}

// ---- water (milestone 15) ---------------------------------------------------
const float NEAR = 0.05;                 // camera near plane (camera.asm)

// slope of the water surface: a few moving swells and ripples
vec2 wave_slope(vec2 p, float t) {
    vec2 g = vec2(0.0);
    const vec4 W[4] = vec4[](vec4(0.82, 0.57, 0.23, 0.060), vec4(-0.45, 0.89, 0.37, 0.040),
                             vec4(0.97, -0.24, 0.71, 0.022), vec4(-0.68, -0.73, 1.13, 0.014));
    const float SPEED[4] = float[](1.1, 1.4, 2.1, 2.7);
    for (int i = 0; i < 4; ++i) {
        float ph = dot(W[i].xy, p) * W[i].z + t * SPEED[i];
        g += W[i].xy * (W[i].z * W[i].w * cos(ph));
    }
    return g;
}

// screen-space reflection: march the reflected ray against the opaque
// scene's depth; a = how much of it was found on screen
vec4 ssr(vec3 o, vec3 r) {
    float step = 0.6;
    vec3 p = o + r * 0.3;
    for (int i = 0; i < 28; ++i) {
        p += r * step;
        step *= 1.25;
        vec4 c = u_viewproj * vec4(p, 1.0);
        if (c.w <= NEAR) break;
        vec3 ndc = c.xyz / c.w;
        vec2 uv = ndc.xy * 0.5 + 0.5;
        if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) break;
        float zs = textureLod(u_refr_depth, uv, 0.0).r;
        if (zs > ndc.z) {                       // the scene is in front of the ray
            float behind = NEAR / ndc.z - NEAR / max(zs, 1e-7);
            if (behind < step * 1.5 + 0.5) {
                vec2 e = smoothstep(vec2(0.0), vec2(0.08), uv) * smoothstep(vec2(1.0), vec2(0.92), uv);
                return vec4(textureLod(u_refr_color, uv, 0.0).rgb, e.x * e.y);
            }
            break;
        }
    }
    return vec4(0.0);
}

// the water surface's colour (linear HDR). wcol: the biome's water colour
// (linear); light: the surface's light (perceptual, as for blocks); sky:
// how much open sky it sees (0..1); direct: sun/moon reaching it
vec3 water_color(vec3 wcol, vec3 light, float sky, float direct) {
    vec2 res = vec2(textureSize(u_refr_color, 0));
    vec2 suv = gl_FragCoord.xy / res;
    vec2 wp = v_tuv * (v_level > 0u ? 16384.0 : 4096.0);   // world x, z (mod 65536)
    vec2 g = wave_slope(wp, u_time);
    vec3 n = normalize(vec3(-g.x, 1.0, -g.y));
    if (!gl_FrontFacing) n = -n;                // seen from below
    vec3 v = normalize(-v_rel);
    float dist = length(v_rel);

    // how much water the view ray crosses (to the opaque scene behind)
    float zs = textureLod(u_refr_depth, suv, 0.0).r;
    float vz_w = NEAR / gl_FragCoord.z;
    float vz_f = zs > 0.0 ? NEAR / zs : 1e5;
    float thick = max(vz_f - vz_w, 0.0) * dist / vz_w;

    // refraction: the scene behind, bent by the waves (not where that
    // would pick up something in front of the water)
    vec2 ruv = suv + n.xz * 0.035 * clamp(thick * 0.25, 0.0, 1.0) / max(dist * 0.05, 1.0);
    if (textureLod(u_refr_depth, ruv, 0.0).r > gl_FragCoord.z) ruv = suv;
    vec3 behind = textureLod(u_refr_color, ruv, 0.0).rgb;
    vec3 lin = pow(light, vec3(2.2));
    vec3 absorb = exp(-thick * vec3(0.40, 0.11, 0.07));
    vec3 scatter = wcol * lin * 0.55;
    vec3 under = behind * absorb + scatter * (1.0 - exp(-thick * 0.20));

    // reflection: the scene on screen, else the sky (dimmed where the
    // surface sees little sky)
    vec3 r = reflect(-v, n);
    vec3 skyr = sky_color(r, normalize(u_sun_dir)) * smoothstep(0.0, 1.0, sky);
    vec3 refl = skyr;
    if ((u_water & 2) != 0 && gl_FrontFacing) {
        vec4 h = ssr(v_rel, r);
        refl = mix(skyr, h.rgb, h.a);
    }
    float fres = 0.02 + 0.98 * pow(1.0 - max(dot(n, v), 0.0), 5.0);
    if (!gl_FrontFacing) fres = 0.0;            // (from below: mostly see through)
    vec3 col = mix(under, refl, fres);

    // sun / moon glint
    vec3 hv = normalize(v + sd.light.xyz);
    float spec = pow(max(dot(n, hv), 0.0), 400.0) * 8.0 * direct * sd.light.w;
    col += spec * sky_light(u_sun_dir);

    // foam where the water is shallow at the shore
    float fn = fract(sin(dot(floor(wp * 2.0), vec2(12.9898, 78.233))) * 43758.5453);
    float edge = 1.0 - smoothstep(0.0, 0.7, thick);
    float foam = edge * smoothstep(0.35, 0.9, fn + 0.25 * sin(u_time * 2.0 + wp.x * 0.7 + wp.y * 0.5));
    col = mix(col, vec3(0.95) * lin, clamp(foam, 0.0, 0.85));
    return col;
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
    // direct sun/moon: facing it and not in shadow; the rest of the sky
    // light still reaches shadowed and averted faces
    float direct = 1.0;
    if (v_level == 0u) {
        float dist = length(v_rel);
        vec3 lightd = sd.light.xyz;
        float facing = 1.0;
        vec3 n = vec3(0.0, 1.0, 0.0);
        if (v_face < 6u) {
            n = FACE_NORMAL[v_face];
            facing = smoothstep(0.0, 0.12, dot(n, lightd));
        }
        direct = mix(1.0, facing * shadow_at(n, dist), sd.light.w);
    }
    float sky_part = mix(SKY_FILL, 1.0, direct);
    vec3 lit = max(curve(vec3(l.a)) * sky_light(u_sun_dir) * u_daylight * sky_part, curve(block));
    float alpha = (u_pass == 2) ? c.a : 1.0;
    if (v_tint == 3u && u_pass == 2 && u_water != 0) {
        // water: its own shading, opaque over the copied scene
        vec3 wcol = pow(WATER_REF * tint(2.0), vec3(2.2));
        color = water_color(wcol, AMBIENT + (1.0 - AMBIENT) * lit, l.a, direct);
        alpha = 1.0;
    } else {
        if (u_pass == 2 && !gl_FrontFacing) discard;  // (only water is two-sided)
        color *= (AMBIENT + (1.0 - AMBIENT) * lit) * ao;
        color = pow(max(color, vec3(0.0)), vec3(2.2));    // to linear
    }
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
    o_color = vec4(mix(color, fog_col, clamp(fog, 0.0, 1.0)), alpha);
}
