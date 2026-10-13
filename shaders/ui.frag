#version 450 core
// Menus and HUD (milestone 17), see ui.vert. The glass backdrop is the
// finished frame, downsampled to 1/16 and blurred here with a few taps.

layout(binding = 0) uniform sampler2D u_font;       // SDF atlas (R8, 0.5 = edge)
layout(binding = 1) uniform sampler2D u_backdrop;   // the frame, 1/16 size
layout(binding = 2) uniform sampler2D u_images;     // thumbnails etc.
layout(binding = 3) uniform sampler2D u_icons;      // item icons (milestone 18)
layout(binding = 4) uniform sampler2D u_skin;       // the journal skin (milestone 18 part 5)
layout(location = 0) uniform vec2 u_screen;

in vec2 v_local;
in vec2 v_uv;
flat in vec2 v_size;
flat in vec4 v_color;
flat in vec4 v_color2;
flat in vec4 v_p;
flat in uint v_kind;
flat in vec4 v_box;

out vec4 o_color;

// signed distance to a rounded rectangle (negative inside), local pixels
float box(vec2 p, vec2 size, float r) {
    vec2 h = size * 0.5;
    r = min(r, min(h.x, h.y));
    vec2 d = abs(p - h) - (h - r);
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

vec3 backdrop(vec2 frag) {
    vec2 uv = frag / u_screen;
    uv.y = 1.0 - uv.y;               // (the backdrop texture is bottom-up)
    vec2 t = 1.0 / vec2(textureSize(u_backdrop, 0));
    vec3 s = vec3(0.0);
    float wsum = 0.0;
    for (int y = -2; y <= 2; ++y)
        for (int x = -2; x <= 2; ++x) {
            float w = 3.0 - 0.5 * float(abs(x) + abs(y));
            s += texture(u_backdrop, uv + vec2(x, y) * t * 1.3).rgb * w;
            wsum += w;
        }
    return s / wsum;
}

void main() {
    if (v_kind == 1u) {
        // SDF glyph: crisp at any size; weight > 0 thickens it
        float d = texture(u_font, v_uv).r;
        float w = max(fwidth(d), 1e-4) * 0.75;
        float edge = 0.5 - v_p.w;
        float soft = v_p.y;                              // shadows: wider ramp
        float a = smoothstep(edge - w - soft, edge + w, d);
        float t = clamp(v_local.y / max(v_size.y, 1.0), 0.0, 1.0);
        vec4 c = mix(v_color, v_color2, t);
        o_color = vec4(c.rgb, c.a * a);
        if (o_color.a <= 0.002) discard;
        return;
    }
    if (v_kind == 4u) {
        o_color = texture(u_images, v_uv) * v_color;
        return;
    }
    if (v_kind == 6u) {
        // 9-slice: the border (v_p.w atlas pixels) keeps its size, the
        // middle repeats; v_p.y = screen pixels per atlas pixel
        float s = max(v_p.y, 0.01);
        float B = v_p.w;
        vec2 src = v_box.zw - v_box.xy;
        vec2 dst = v_size / s;
        vec2 pos = v_local / s;
        vec2 t;
        for (int i = 0; i < 2; ++i) {
            float mid = max(src[i] - 2.0 * B, 1.0);
            if (B <= 0.0) t[i] = clamp(pos[i] * src[i] / dst[i], 0.0, src[i] - 0.001);
            else if (pos[i] < B) t[i] = pos[i];
            else if (pos[i] > dst[i] - B) t[i] = src[i] - (dst[i] - pos[i]);
            else t[i] = B + mod(pos[i] - B, mid);
        }
        vec2 px = floor(v_box.xy + clamp(t, vec2(0.0), src - 0.001));
        o_color = texelFetch(u_skin, ivec2(px), 0) * v_color;
        if (o_color.a <= 0.003) discard;
        return;
    }
    if (v_kind == 5u) {
        o_color = texture(u_icons, v_uv) * v_color;
        if (o_color.a <= 0.01) discard;
        return;
    }
    float d = box(v_local, v_size, v_p.x);
    if (v_kind == 3u) {
        // glow / shadow: fades out over p.y pixels outside the shape
        float a = 1.0 - smoothstep(0.0, v_p.y, d);
        a *= a;
        o_color = vec4(v_color.rgb, v_color.a * a);
        if (o_color.a <= 0.002) discard;
        return;
    }
    float aa = clamp(0.5 - d, 0.0, 1.0);                 // antialiased edge
    if (aa <= 0.0) discard;
    float t = clamp(v_local.y / max(v_size.y, 1.0), 0.0, 1.0);
    if (v_kind == 2u) {
        // glass: the blurred world, darkened and tinted, a faint sheen at
        // the top and a thin light border
        vec3 b = backdrop(gl_FragCoord.xy);
        vec3 c = mix(b * 0.55, v_color.rgb, v_color.a);
        c += vec3(0.06) * (1.0 - smoothstep(0.0, 0.35, t));
        float border = v_p.z > 0.0 ? 1.0 - smoothstep(v_p.z - 1.0, v_p.z, -d) : 0.0;
        c = mix(c, v_color2.rgb, border * v_color2.a);
        o_color = vec4(c, aa);
        return;
    }
    vec4 c = mix(v_color, v_color2, t);
    if (v_p.z > 0.0) {                                   // a border in color2
        float border = 1.0 - smoothstep(v_p.z - 1.0, v_p.z, -d);
        c = mix(v_color, v_color2, border);
    }
    o_color = vec4(c.rgb, c.a * aa);
}
