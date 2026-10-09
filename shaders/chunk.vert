#version 450 core
// World sections: vertex pulling from packed greedy quads (see
// src/render/mesher.asm for the format). 6 vertices per quad, no vertex
// buffers. Rendering is camera-relative (u_origin_rel = section origin - cam).

layout(std430, binding = 0) readonly buffer Quads { uvec2 quads[]; };

layout(location = 0) uniform mat4 u_viewproj;     // rotation + projection
layout(location = 1) uniform vec3 u_origin_rel;   // section origin - camera
layout(location = 2) uniform uint u_quad_base;    // first quad of the section
layout(location = 3) uniform vec3 u_origin_world; // section origin (world)

out vec3 v_world;       // world position (for per-block patterns)
out vec3 v_rel;         // camera-relative position (fog)
flat out uint v_block;
flat out uint v_face;

// corner order per face; faces 1, 3, 4 (+X, +Y, -Z) are mirrored so every
// face winds counter-clockwise seen from outside (back-face culling)
const uint CORNERS[12] = uint[](0u, 1u, 2u, 0u, 2u, 3u,
                                0u, 2u, 1u, 0u, 3u, 2u);

void main() {
    uvec2 q = quads[u_quad_base + uint(gl_VertexID) / 6u];
    uint lo = q.x;
    vec3 p = vec3(float(lo & 63u), float((lo >> 6) & 63u), float((lo >> 12) & 63u));
    float w = float(((lo >> 18) & 31u) + 1u);
    float h = float(((lo >> 23) & 31u) + 1u);
    uint face = (lo >> 28) & 7u;
    bool flip = (face == 1u || face == 3u || face == 4u);
    uint c = CORNERS[(flip ? 6u : 0u) + uint(gl_VertexID) % 6u];
    float du = (c == 1u || c == 2u) ? w : 0.0;
    float dv = (c >= 2u) ? h : 0.0;
    float side = float(face & 1u);
    uint axis = face >> 1;
    if (axis == 0u)      { p.x += side; p.z += du; p.y += dv; }   // u = z, v = y
    else if (axis == 1u) { p.y += side; p.x += du; p.z += dv; }   // u = x, v = z
    else                 { p.z += side; p.x += du; p.y += dv; }   // u = x, v = y

    v_rel = u_origin_rel + p;
    v_world = u_origin_world + p;
    v_block = q.y & 0xFFFFu;
    v_face = face;
    gl_Position = u_viewproj * vec4(v_rel, 1.0);
}
