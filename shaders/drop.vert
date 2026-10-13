#version 450 core
// Dropped items (milestone 18): a small spinning cube for blocks, or a
// spinning flat picture (plants, items) from the icon atlas. One draw per
// drop; 36 vertices (6 faces x 2 triangles), faces turned away collapse.

layout(std430, binding = 1) readonly buffer Faces { uint block_face[]; };
layout(std430, binding = 2) readonly buffer Textures { uvec4 tex_info[]; };

layout(location = 0) uniform mat4 u_viewproj;   // camera rotation + projection
layout(location = 1) uniform vec3 u_pos;        // centre, camera-relative
layout(location = 2) uniform float u_spin;      // radians
layout(location = 3) uniform uint u_block;
layout(location = 4) uniform int u_flat;
layout(location = 5) uniform vec4 u_icon_uv;    // u0, v0 (top), u1, v1

out vec2 v_uv;
flat out uint v_layer;
flat out float v_shade;
flat out int v_flat;

const vec2 QUAD[6] = vec2[](vec2(0, 0), vec2(1, 0), vec2(1, 1),
                            vec2(0, 0), vec2(1, 1), vec2(0, 1));
const vec3 ORG[6] = vec3[](vec3(0,0,0), vec3(1,0,1), vec3(0,0,0), vec3(0,1,1), vec3(1,0,0), vec3(0,0,1));
const vec3 UAX[6] = vec3[](vec3(0,0,1), vec3(0,0,-1), vec3(1,0,0), vec3(1,0,0), vec3(-1,0,0), vec3(1,0,0));
const vec3 VAX[6] = vec3[](vec3(0,1,0), vec3(0,1,0), vec3(0,0,1), vec3(0,0,-1), vec3(0,1,0), vec3(0,1,0));
const vec3 NRM[6] = vec3[](vec3(-1,0,0), vec3(1,0,0), vec3(0,-1,0), vec3(0,1,0), vec3(0,0,-1), vec3(0,0,1));
const float SHADE[6] = float[](0.62, 0.8, 0.5, 1.0, 0.7, 0.85);

void main() {
    uint f = uint(gl_VertexID) / 6u;
    vec2 q = QUAD[uint(gl_VertexID) % 6u];
    float c = cos(u_spin), s = sin(u_spin);
    mat3 r = mat3(c, 0, -s, 0, 1, 0, s, 0, c);
    v_flat = u_flat;
    vec3 p;
    if (u_flat == 1) {
        if (f != 4u) { gl_Position = vec4(0.0); return; }
        p = r * (vec3(q.x - 0.5, q.y - 0.5, 0.0) * 0.42) + u_pos;
        v_uv = mix(u_icon_uv.xy, u_icon_uv.zw, vec2(q.x, 1.0 - q.y));
        v_shade = 1.0;
        v_layer = 0u;
    } else {
        vec3 n = r * NRM[f];
        p = r * ((ORG[f] + UAX[f] * q.x + VAX[f] * q.y - vec3(0.5)) * 0.26) + u_pos;
        if (dot(n, u_pos) >= 0.0) { gl_Position = vec4(0.0); return; }   // turned away
        v_uv = vec2(q.x, 1.0 - q.y);
        uint bf = block_face[u_block * 6u + f];
        v_layer = tex_info[bf & 0xFFFFu].x;
        v_shade = SHADE[f];
    }
    gl_Position = u_viewproj * vec4(p, 1.0);
}
