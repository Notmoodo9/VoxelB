#version 450 core
// Item icons (milestone 18): one block drawn as a small isometric cube (top,
// right and left faces) or, for plant-like shapes, a flat picture, into one
// cell of the icon atlas. Vertex pulling: 18 vertices = 3 faces x 2 triangles.

layout(std430, binding = 1) readonly buffer Faces { uint block_face[]; };
layout(std430, binding = 2) readonly buffer Textures { uvec4 tex_info[]; };

layout(location = 0) uniform uint u_block;
layout(location = 1) uniform int u_kind;       // 0 cube, 1 slab (half height), 2 flat

out vec2 v_uv;
flat out uint v_layer;
flat out float v_shade;
flat out uint v_tint;

const vec2 QUAD[6] = vec2[](vec2(0, 0), vec2(1, 0), vec2(1, 1),
                            vec2(0, 0), vec2(1, 1), vec2(0, 1));

void main() {
    uint f = uint(gl_VertexID) / 6u;            // 0 top, 1 right (+X), 2 left (+Z)
    vec2 q = QUAD[uint(gl_VertexID) % 6u];
    uint face;
    vec3 p;
    float h = u_kind == 1 ? 0.5 : 1.0;
    if (u_kind == 2) {
        // flat: one upright picture filling the cell (the other two collapse)
        face = 4u;
        p = vec3(0.0);
        vec2 s = q * 2.0 - 1.0;
        gl_Position = f == 0u ? vec4(s * 0.92, 0.0, 1.0) : vec4(0.0);
        v_uv = vec2(q.x, 1.0 - q.y);
        v_shade = 1.0;
    } else {
        if (f == 0u) { face = 3u; p = vec3(q.x, h, q.y); v_uv = vec2(q.x, q.y); v_shade = 1.0; }
        else if (f == 1u) { face = 1u; p = vec3(1.0, q.y * h, 1.0 - q.x); v_uv = vec2(q.x, 1.0 - q.y * h); v_shade = 0.78; }
        else { face = 5u; p = vec3(q.x, q.y * h, 1.0); v_uv = vec2(q.x, 1.0 - q.y * h); v_shade = 0.6; }
        // isometric: x to the right-down, z to the left-down, y up
        vec2 s = vec2((p.x - p.z) * 0.866, p.y - (p.x + p.z) * 0.5);
        s.y += (1.0 - h) * 0.5;                  // centre a slab too
        gl_Position = vec4(s * 0.94, 0.0, 1.0);
    }
    uint bf = block_face[u_block * 6u + face];
    v_layer = tex_info[bf & 0xFFFFu].x;
    v_tint = (bf >> 19) & 3u;
}
