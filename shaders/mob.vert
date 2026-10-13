#version 450 core
// Animals (milestone 19, src/render/mob_render.asm): every box is one record
// in the Parts buffer; 36 vertices each (6 faces x 2 triangles), built here
// from the record (vertex pulling, no vertex buffers). A box is posed by its
// own turn at its pivot (legs swing, the head looks), scaled to blocks (16
// pixels = 1 block; babies smaller with bigger heads; wings roll), tipped over when the
// animal dies, then turned by the body's yaw and placed camera-relative.
// The skin layout per box (pixels, as tools/texgen/mobgen.py paints it):
//   top (u+d, v) w x d, bottom (u+d+w, v) w x d, -X (u, v+d) d x h,
//   front -Z (u+d, v+d) w x h, +X (u+d+w, v+d) d x h, back (u+2d+w, v+d) w x h
// The same records draw into the sun's shadow cascades (u_cascade > 0).

struct Part {
    vec4 a;     // camera-relative position (blocks), body yaw
    vec4 b;     // pivot (pixels), scale
    vec4 c;     // box corner from the pivot (pixels), skin layer
    vec4 d;     // box size (pixels), the box's pitch
    vec4 e;     // the box's yaw, the body's roll (dying), skin u, v (pixels)
    vec4 f;     // sky light 0..1, red tint 0..1, box scale (baby heads), pink tint 0..1
    vec4 g;     // the box's roll (wings flapping), unused x3
};
layout(std430, binding = 11) readonly buffer Parts { Part parts[]; };

layout(location = 0) uniform mat4 u_viewproj;     // rotation + projection
layout(location = 16) uniform int u_cascade;      // shadow pass: cascade + 1 (0: camera)
struct ShadowData { mat4 m[4]; vec4 splits; vec4 light; vec4 texel; vec4 origin[4]; };
layout(std430, binding = 7) readonly buffer Shadow { ShadowData sd; };

out vec3 v_rel;
out vec2 v_uv;
out vec3 v_n;
flat out float v_layer;
flat out vec3 v_light;    // sky, red tint, pink tint (fed)

const vec2 ST[6] = vec2[](vec2(0, 0), vec2(1, 0), vec2(1, 1), vec2(0, 0), vec2(1, 1), vec2(0, 1));

vec3 rot_y(vec3 p, float a) { float c = cos(a), s = sin(a); return vec3(p.x * c - p.z * s, p.y, p.x * s + p.z * c); }
vec3 rot_x(vec3 p, float a) { float c = cos(a), s = sin(a); return vec3(p.x, p.y * c - p.z * s, p.y * s + p.z * c); }
vec3 rot_z(vec3 p, float a) { float c = cos(a), s = sin(a); return vec3(p.x * c - p.y * s, p.x * s + p.y * c, p.z); }

void main() {
    uint id = uint(gl_VertexID) / 36u;
    uint k = uint(gl_VertexID) % 36u;
    uint f = k / 6u;
    Part P = parts[id];
    vec2 st = ST[k % 6u];
    float s = st.x, t = st.y;
    float w = P.d.x, h = P.d.y, d = P.d.z;
    float u = P.e.z, v = P.e.w;
    vec3 q, n;
    vec4 r;
    if (f == 0u)      { q = vec3(s, 1.0, t);             r = vec4(u + d, v, w, d);             n = vec3(0, 1, 0); }
    else if (f == 1u) { q = vec3(s, 0.0, t);             r = vec4(u + d + w, v, w, d);         n = vec3(0, -1, 0); }
    else if (f == 2u) { q = vec3(0.0, 1.0 - t, s);       r = vec4(u, v + d, d, h);             n = vec3(-1, 0, 0); }
    else if (f == 3u) { q = vec3(1.0 - s, 1.0 - t, 0.0); r = vec4(u + d, v + d, w, h);         n = vec3(0, 0, -1); }
    else if (f == 4u) { q = vec3(1.0, 1.0 - t, 1.0 - s); r = vec4(u + d + w, v + d, d, h);     n = vec3(1, 0, 0); }
    else              { q = vec3(s, 1.0 - t, 1.0);       r = vec4(u + 2.0 * d + w, v + d, w, h); n = vec3(0, 0, 1); }
    v_uv = (r.xy + st * r.zw) / 64.0;
    vec3 p = (P.c.xyz + q * P.d.xyz) * P.f.z;
    p = rot_y(rot_x(rot_z(p, P.g.x), P.d.w), P.e.x);
    n = rot_y(rot_x(rot_z(n, P.g.x), P.d.w), P.e.x);
    p = (p + P.b.xyz) * (P.b.w / 16.0);
    p = rot_z(p, P.e.y);
    n = rot_z(n, P.e.y);
    p = rot_y(p, P.a.w);
    n = rot_y(n, P.a.w);
    vec3 rel = p + P.a.xyz;
    v_rel = rel;
    v_n = n;
    v_layer = P.c.w;
    v_light = vec3(P.f.x, P.f.y, P.f.w);
    gl_Position = (u_cascade > 0 ? sd.m[u_cascade - 1] : u_viewproj) * vec4(rel, 1.0);
}
