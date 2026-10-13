#version 450 core
// The item in hand (milestone 18): a block as a small cube in the lower
// right of the view, or a flat picture (plants, items) from the icon atlas.
// Drawn after the frame is finished; only faces turned to the eye are kept
// (a cube is convex), so no depth buffer is needed. Vertex pulling: 36
// vertices = 6 faces x 2 triangles.

layout(std430, binding = 1) readonly buffer Faces { uint block_face[]; };
layout(std430, binding = 2) readonly buffer Textures { uvec4 tex_info[]; };

layout(location = 0) uniform uint u_block;
layout(location = 1) uniform int u_flat;        // 1: a picture from u_icon_uv
layout(location = 2) uniform vec4 u_icon_uv;    // u0, v0 (top), u1, v1
layout(location = 3) uniform float u_swing;     // 0..1 through a swing
layout(location = 4) uniform vec2 u_bob;        // walking sway
layout(location = 5) uniform float u_aspect;
layout(location = 7) uniform int u_mirror;     // 1: the off hand (lower left, mirrored)

out vec2 v_uv;
flat out uint v_layer;
flat out float v_shade;
flat out int v_flat;

const vec2 QUAD[6] = vec2[](vec2(0, 0), vec2(1, 0), vec2(1, 1),
                            vec2(0, 0), vec2(1, 1), vec2(0, 1));
// per face (-X +X -Y +Y -Z +Z): origin, u axis, v axis, normal
const vec3 ORG[6] = vec3[](vec3(0,0,0), vec3(1,0,1), vec3(0,0,0), vec3(0,1,1), vec3(1,0,0), vec3(0,0,1));
const vec3 UAX[6] = vec3[](vec3(0,0,1), vec3(0,0,-1), vec3(1,0,0), vec3(1,0,0), vec3(-1,0,0), vec3(1,0,0));
const vec3 VAX[6] = vec3[](vec3(0,1,0), vec3(0,1,0), vec3(0,0,1), vec3(0,0,-1), vec3(0,1,0), vec3(0,1,0));
const vec3 NRM[6] = vec3[](vec3(-1,0,0), vec3(1,0,0), vec3(0,-1,0), vec3(0,1,0), vec3(0,0,-1), vec3(0,0,1));
const float SHADE[6] = float[](0.62, 0.8, 0.5, 1.0, 0.7, 0.85);

mat3 rot_y(float a) { float c = cos(a), s = sin(a); return mat3(c, 0, -s, 0, 1, 0, s, 0, c); }
mat3 rot_x(float a) { float c = cos(a), s = sin(a); return mat3(1, 0, 0, 0, c, s, 0, -s, c); }

void main() {
    uint f = uint(gl_VertexID) / 6u;
    vec2 q = QUAD[uint(gl_VertexID) % 6u];
    v_flat = u_flat;
    float sw = sin(u_swing * 3.14159265);
    mat3 r = rot_x(0.45 - sw * 0.9) * rot_y(0.72 + sw * 0.3);
    vec3 at = vec3(0.6 - sw * 0.16, -0.44 + sw * 0.14 + u_bob.y, -1.2 - sw * 0.1)
            + vec3(u_bob.x, 0.0, 0.0);
    vec3 p, n;
    if (u_flat == 1) {
        // one upright picture, turned a little toward the view
        if (f != 4u) { gl_Position = vec4(0.0); return; }
        p = vec3(q.x - 0.5, q.y - 0.5, 0.0);
        n = vec3(0.0, 0.0, 1.0);
        mat3 rf = rot_x(-0.1 - sw * 1.0) * rot_y(-0.35 + sw * 0.3);
        p = rf * (p * 0.5) + at;
        v_uv = mix(u_icon_uv.xy, u_icon_uv.zw, vec2(q.x, 1.0 - q.y));
        v_shade = 1.0;
        v_layer = 0u;
    } else {
        p = ORG[f] + UAX[f] * q.x + VAX[f] * q.y - vec3(0.5);
        n = r * NRM[f];
        p = r * (p * 0.34) + at;
        // back faces collapse (the cube is convex)
        if (dot(n, -p) <= 0.0) { gl_Position = vec4(0.0); return; }
        v_uv = vec2(q.x, 1.0 - q.y);
        uint bf = block_face[u_block * 6u + f];
        v_layer = tex_info[bf & 0xFFFFu].x;
        v_shade = SHADE[f];
    }
    if (u_mirror == 1) p.x = -p.x;                // the off hand: lower left
    const float F = 1.428;                       // cot(35 deg): a fixed 70 deg view
    gl_Position = vec4(p.x * F / u_aspect, p.y * F, 0.0, -p.z);
}
