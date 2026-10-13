#version 450 core
// Animals (milestone 19), see mob.vert: the skin, shaded like the world's
// blocks (shaders/chunk.frag; the helpers below are copies of its own):
// direct sun or moon light by the face's normal and the shadow cascades, the
// sky's light by how open the sky is above the animal (src/client/
// ents_view.asm), the held light, then the same distance and height fog.
// A hurt animal flashes red.

layout(binding = 11) uniform sampler2DArray u_skins;
layout(binding = 7) uniform sampler2DArrayShadow u_shadow_map;
layout(location = 9) uniform float u_fog;          // fog density
layout(location = 10) uniform vec4 u_held;         // held light: rgb levels 0..15, w = on
layout(location = 11) uniform int u_light_flags;   // 4: height fog
layout(location = 12) uniform float u_daylight;
layout(location = 13) uniform float u_cam_y;
layout(location = 14) uniform vec3 u_sun_dir;
layout(location = 15) uniform float u_fog_base;
layout(location = 17) uniform int u_shadows;
layout(location = 18) uniform vec3 u_cam_mod;
struct ShadowData { mat4 m[4]; vec4 splits; vec4 light; vec4 texel; vec4 origin[4]; };
layout(std430, binding = 7) readonly buffer Shadow { ShadowData sd; };

in vec3 v_rel;
in vec2 v_uv;
in vec3 v_n;
flat in float v_layer;
flat in vec2 v_light;

out vec4 o_color;

const float SKY_FILL = 0.48;
const float AMBIENT = 0.03;
const float HFOG_DENSITY = 0.0012;
const float HFOG_FALLOFF = 30.0;

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

float shadow_at(vec3 n, float dist) {
    if (u_shadows <= 0) return 1.0;
    int c = 0;
    while (c < u_shadows - 1 && dist > sd.splits[c]) ++c;
    float last = sd.splits[u_shadows - 1];
    if (dist > last) return 1.0;
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
    float lit = 0.25 * (texture(u_shadow_map, vec4(uv + vec2(-o.x, -o.y), float(c), ref))
                      + texture(u_shadow_map, vec4(uv + vec2( o.x, -o.y), float(c), ref))
                      + texture(u_shadow_map, vec4(uv + vec2(-o.x,  o.y), float(c), ref))
                      + texture(u_shadow_map, vec4(uv + vec2( o.x,  o.y), float(c), ref)));
    // fade out over the last tenth of the shadow distance
    return mix(lit, 1.0, smoothstep(last * 0.9, last, dist));
}


vec3 sky_light(vec3 sun) {
    float day = smoothstep(-0.12, 0.15, sun.y);
    vec3 sunc = mix(vec3(1.0, 0.62, 0.42), vec3(1.0, 0.98, 0.94), smoothstep(0.0, 0.4, sun.y));
    return mix(vec3(0.16, 0.19, 0.30), sunc, day);
}


vec3 curve(vec3 l) { return pow(l, vec3(1.6)); }

void main() {
    vec4 c = texture(u_skins, vec3(v_uv, v_layer));
    if (c.a < 0.5) discard;
    vec3 n = normalize(v_n);
    // faces: up bright, down dark, sides between (as the blocks' face light)
    float face = n.y >= 0.0 ? mix(0.78, 1.0, n.y) : mix(0.78, 0.55, -n.y);
    float dist = length(v_rel);
    float facing = smoothstep(0.0, 0.12, dot(n, sd.light.xyz));
    float direct = mix(1.0, facing * shadow_at(n, dist), sd.light.w);
    float sky_part = mix(SKY_FILL, 1.0, direct);
    vec3 block = vec3(0.0);
    if (u_held.w > 0.0)
        block = max(u_held.rgb - dist, 0.0) / 15.0;
    vec3 lit = max(curve(vec3(v_light.x)) * sky_light(u_sun_dir) * u_daylight * sky_part, curve(block));
    vec3 color = c.rgb * face * (AMBIENT + (1.0 - AMBIENT) * lit);
    color = mix(color, vec3(0.95, 0.12, 0.08) * max(max(lit.r, lit.g), 0.35), v_light.y * 0.6);
    color = pow(max(color, vec3(0.0)), vec3(2.2));

    float fog_d = dist * u_fog;
    if ((u_light_flags & 4) != 0) {
        float y0 = (u_cam_y - u_fog_base) / HFOG_FALLOFF;
        float dy = v_rel.y / HFOG_FALLOFF;
        float k = abs(dy) > 1e-3 ? (1.0 - exp(-dy)) / dy : 1.0;
        fog_d += HFOG_DENSITY * dist * exp(-max(y0, 0.0)) * k;
    }
    float fog = 1.0 - exp(-fog_d);
    float sky_seen = max(v_light.x, smoothstep(48.0, 160.0, dist));
    vec3 fog_col = sky_color(normalize(v_rel), normalize(u_sun_dir))
                 * min(u_daylight * 1.5, 1.0) * sky_seen;
    o_color = vec4(mix(color, fog_col, clamp(fog, 0.0, 1.0)), 1.0);
}
