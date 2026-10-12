#version 450 core
// Post-processing (milestone 14): the HDR scene plus bloom, exposure, ACES
// tonemapping, a vibrance/saturation grade and the sRGB gamma curve, into
// the window.

layout(binding = 0) uniform sampler2D u_scene;   // HDR, linear
layout(binding = 1) uniform sampler2D u_bloom;   // half size, blurred highlights
layout(location = 1) uniform int u_flags;        // 1 bloom
layout(location = 2) uniform float u_exposure;

in vec2 v_uv;
out vec4 o_color;

const float BLOOM = 0.07;      // share of the blurred highlights added
const float SATURATION = 1.12;
const float VIBRANCE = 0.25;   // extra saturation for dull colours

vec3 aces(vec3 x) {            // Narkowicz's fit of the ACES curve
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

void main() {
    vec3 c = texelFetch(u_scene, ivec2(gl_FragCoord.xy), 0).rgb;
    if ((u_flags & 1) != 0)
        c += texture(u_bloom, v_uv).rgb * BLOOM;
    c = aces(c * u_exposure);
    // grade: saturation, plus vibrance that lifts the less saturated colours
    float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
    float sat = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
    c = mix(vec3(l), c, SATURATION + VIBRANCE * (1.0 - sat));
    c = clamp(c, 0.0, 1.0);
    o_color = vec4(pow(c, vec3(1.0 / 2.2)), 1.0);
}
