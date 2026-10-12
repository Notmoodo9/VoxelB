#version 450 core
// Post-processing (milestone 14): the HDR scene plus clouds and bloom,
// exposure, ACES tonemapping, a vibrance/saturation grade and the sRGB gamma
// curve, into the window.
// Clouds (part 2): a layer between u_cloud.y and u_cloud.y + u_cloud.z,
// marched in a few steps along each pixel's ray up to the scene depth (so
// terrain hides clouds behind it and clouds hide terrain below them), with
// one sample towards the sun per step for darker undersides; drifting with
// the wind, coloured by the time of day, fading with distance.

layout(binding = 0) uniform sampler2D u_scene;   // HDR, linear
layout(binding = 1) uniform sampler2D u_bloom;   // half size, blurred highlights
layout(binding = 2) uniform sampler2D u_depth;   // scene depth (reverse-Z, infinite far)
layout(location = 0) uniform mat4 u_viewproj;    // camera rotation + projection
layout(location = 1) uniform int u_flags;        // 1 bloom, 2 clouds
layout(location = 2) uniform float u_exposure;
layout(location = 3) uniform vec3 u_sun;         // towards the sun
layout(location = 4) uniform float u_time;       // seconds (wind)
layout(location = 5) uniform vec3 u_cam;         // camera world position
layout(location = 6) uniform vec4 u_cloud;       // cover 0..1, base y, thickness, -

in vec2 v_uv;
in vec3 v_dir;
out vec4 o_color;

const float BLOOM = 0.07;      // share of the blurred highlights added
const float SATURATION = 1.12;
const float VIBRANCE = 0.25;   // extra saturation for dull colours

float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}
float vnoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash12(i), hash12(i + vec2(1, 0)), u.x),
               mix(hash12(i + vec2(0, 1)), hash12(i + vec2(1, 1)), u.x), u.y);
}
float fbm(vec2 p) {
    float a = 0.5, s = 0.0;
    for (int i = 0; i < 3; ++i) { s += a * vnoise(p); p = p * 2.03 + 17.1; a *= 0.5; }
    return s / 0.875;
}
float cloud_density(vec3 p) {
    float h = (p.y - u_cloud.y) / u_cloud.z;
    if (h < 0.0 || h > 1.0) return 0.0;
    float profile = smoothstep(0.0, 0.3, h) * smoothstep(1.0, 0.5, h);
    vec2 q = p.xz * 0.0035 + vec2(u_time * 0.006, u_time * 0.0025);
    float n = fbm(q) + 0.25 * (vnoise(q * 5.7) - 0.5);
    return clamp((n - (1.0 - u_cloud.x)) * 3.0, 0.0, 1.0) * profile;
}

// clouds along the ray (camera-relative direction d) up to distance tmax:
// rgb = light added, a = transmittance left for what is behind
vec4 clouds(vec3 d, float tmax) {
    float y0 = u_cloud.y, y1 = u_cloud.y + u_cloud.z;
    float t0, t1;
    if (abs(d.y) < 1e-4) {
        if (u_cam.y < y0 || u_cam.y > y1) return vec4(0.0, 0.0, 0.0, 1.0);
        t0 = 0.0; t1 = 3000.0;
    } else {
        float ta = (y0 - u_cam.y) / d.y, tb = (y1 - u_cam.y) / d.y;
        t0 = max(min(ta, tb), 0.0);
        t1 = max(ta, tb);
    }
    t1 = min(t1, min(tmax, t0 + 600.0));
    if (t1 <= t0 || t0 > 6000.0) return vec4(0.0, 0.0, 0.0, 1.0);
    vec3 sun = normalize(u_sun);
    float day = smoothstep(-0.15, 0.15, sun.y);
    vec3 sunc = mix(vec3(1.3, 0.55, 0.25), vec3(1.25, 1.22, 1.15), smoothstep(0.0, 0.4, sun.y));
    vec3 lit = mix(vec3(0.05, 0.06, 0.10), sunc, day);          // sunlit top
    vec3 shade = mix(vec3(0.02, 0.025, 0.05), vec3(0.42, 0.48, 0.60), day); // underside
    vec3 lightd = sun.y > -0.1 ? sun : -sun;
    const int STEPS = 6;
    float dt = (t1 - t0) / float(STEPS);
    float trans = 1.0;
    vec3 col = vec3(0.0);
    for (int i = 0; i < STEPS; ++i) {
        vec3 p = u_cam + d * (t0 + (float(i) + hash12(gl_FragCoord.xy + float(i)) ) * dt);
        float den = cloud_density(p);
        if (den <= 0.0) continue;
        float toward = cloud_density(p + lightd * 18.0);
        vec3 c = mix(shade, lit, exp(-toward * 2.2));
        float a = 1.0 - exp(-den * dt * 0.045);
        col += trans * a * c;
        trans *= 1.0 - a;
        if (trans < 0.03) break;
    }
    // far clouds fade into the sky
    float fade = 1.0 - smoothstep(2500.0, 6000.0, t0);
    return vec4(col * fade, mix(1.0, trans, fade));
}

vec3 aces(vec3 x) {            // Narkowicz's fit of the ACES curve
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

void main() {
    vec3 c = texelFetch(u_scene, ivec2(gl_FragCoord.xy), 0).rgb;
    if ((u_flags & 2) != 0 && u_cloud.z > 0.0) {
        // how far the scene is along this ray (depth 0: the sky, infinitely far)
        float z = texelFetch(u_depth, ivec2(gl_FragCoord.xy), 0).r;
        vec3 d = normalize(v_dir);
        float tmax = 1e9;
        if (z > 0.0) {
            vec4 w = inverse(u_viewproj) * vec4(v_uv * 2.0 - 1.0, z, 1.0);
            tmax = length(w.xyz / w.w);
        }
        vec4 cl = clouds(d, tmax);
        c = c * cl.a + cl.rgb;
    }
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
