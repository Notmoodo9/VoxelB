#version 450 core
// Cracks (milestone 18): dark jagged lines on a 16 x 16 pixel grid that
// spread as mining goes on: the iso-lines of a smooth value noise, thicker
// with progress in ten stages like Minecraft's; the last (fully cracked)
// shows over the last tenth, just before the block breaks.

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

// how far pixel centre px is from the crack lines (smaller: on a crack)
float ridge(vec2 px) {
    float n = value_noise(px * 4.0) * 0.65 + value_noise(px * 9.0) * 0.35;
    return min(min(abs(n - 0.5), abs(n - 0.35)), abs(n - 0.65));
}

void main() {
    vec2 px = (floor(clamp(v_uv, 0.0, 0.9999) * 16.0) + 0.5) / 16.0;   // pixel centres
    // ten stages like Minecraft's: the pixels near three iso-lines of the
    // noise crack, more of them each stage (about 4% at the first, 40% at
    // the last, which shows over the last tenth before the block breaks);
    // the lines are judged at pixel centres, so they are whole pixels. A
    // crack pixel is nearly black; the pixel below-right of one gets a faint
    // light edge, so the cracks read as grooves on dark blocks too
    float stage = min(floor(u_progress * 10.0), 9.0) / 9.0;
    float w = 0.003 + 0.028 * stage;
    if (ridge(px) < w) {
        o_color = vec4(0.02, 0.015, 0.01, 0.85);
    } else if (ridge(px + vec2(-1.0, 1.0) / 16.0) < w) {
        o_color = vec4(1.0, 0.97, 0.9, 0.22);
    } else {
        discard;
    }
}
