#version 450 core
// The sky (milestone 14): an analytic atmosphere in linear HDR colour.
// Blue zenith fading to a pale horizon by day, deep blue-black by night,
// orange-pink glow on the sun's side at sunrise and sunset, the sun and
// moon disks with halos, and twinkling stars at night. sky_color() is shared
// with shaders/chunk.frag (fog colour): keep the two copies the same.

layout(location = 4) uniform vec3 u_sun_dir;   // towards the sun (unit)
layout(location = 5) uniform float u_time;     // seconds (star twinkle)

in vec2 v_uv;
in vec3 v_dir;
out vec4 o_color;

// ---- shared with chunk.frag ------------------------------------------------
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
// -----------------------------------------------------------------------------

float hash13(vec3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.zyx + 31.32);
    return fract((p.x + p.y) * p.z);
}

void main() {
    vec3 d = normalize(v_dir);
    vec3 sun = normalize(u_sun_dir);
    float day = smoothstep(-0.18, 0.12, sun.y);
    vec3 c = sky_color(d, sun);

    // sun: a bright disk, a tight halo and a wide soft glow
    float cs = dot(d, sun);
    vec3 sun_col = mix(vec3(1.0, 0.45, 0.15), vec3(1.0, 0.95, 0.85),
                       smoothstep(0.0, 0.3, sun.y));
    c += sun_col * (smoothstep(0.99955, 0.9997, cs) * 40.0
                    + pow(max(cs, 0.0), 800.0) * 4.0
                    + pow(max(cs, 0.0), 12.0) * 0.25 * day);

    // moon: opposite the sun, pale blue-white
    float cm = dot(d, -sun);
    float night = 1.0 - day;
    c += vec3(0.75, 0.82, 1.0) * (smoothstep(0.99965, 0.9998, cm) * 3.0
                                  + pow(max(cm, 0.0), 300.0) * 0.25) * night;

    // stars: sparse cells on the sky sphere, twinkling, above the horizon
    if (night > 0.01 && d.y > 0.0) {
        vec3 p = d * 220.0;
        vec3 cell = floor(p);
        float h = hash13(cell);
        if (h > 0.9965) {
            vec3 centre = cell + 0.5 + 0.3 * (vec3(hash13(cell + 1.7), hash13(cell + 4.1),
                                                   hash13(cell + 8.3)) - 0.5);
            float r = length(p - centre);
            float tw = 0.6 + 0.4 * sin(u_time * (1.0 + 3.0 * h) + h * 400.0);
            float b = smoothstep(0.35, 0.0, r) * tw * (h - 0.9965) / 0.0035;
            c += vec3(0.8, 0.85, 1.0) * b * 2.5 * night * smoothstep(0.0, 0.15, d.y);
        }
    }
    o_color = vec4(c, 1.0);
}
