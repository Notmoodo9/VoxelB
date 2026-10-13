#version 450 core
// Cracks (milestone 18): dark jagged lines on a 16 x 16 pixel grid that
// spread as mining goes on: the iso-lines of a smooth value noise, thicker
// with progress.

layout(location = 2) uniform float u_progress;  // 0..1

in vec2 v_uv;
flat in uint v_face;

out vec4 o_color;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7)) + float(v_face) * 17.3) * 43758.5453);
}

float value_noise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x),
               mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

void main() {
    vec2 px = (floor(clamp(v_uv, 0.0, 0.9999) * 16.0) + 0.5) / 16.0;   // pixel centres
    float n = value_noise(px * 4.0) * 0.65 + value_noise(px * 9.0) * 0.35;
    float width = 0.012 + 0.045 * u_progress;
    float crack = 1.0 - smoothstep(width * 0.6, width, abs(n - 0.5));
    // more lines as it goes: a second set of iso-lines appears halfway
    if (u_progress > 0.45)
        crack = max(crack, 1.0 - smoothstep(width * 0.4, width * 0.8, abs(n - 0.3)));
    if (crack < 0.5) discard;
    o_color = vec4(0.0, 0.0, 0.0, 0.62);
}
