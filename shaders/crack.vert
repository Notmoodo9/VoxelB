#version 450 core
// Cracks on the block being mined (milestone 18): the block's 6 faces a
// hair outside it; 36 vertices pulled from gl_VertexID.

layout(location = 0) uniform mat4 u_viewproj;
layout(location = 1) uniform vec3 u_min;        // corner, camera-relative

out vec2 v_uv;
flat out uint v_face;

const vec2 QUAD[6] = vec2[](vec2(0, 0), vec2(1, 0), vec2(1, 1),
                            vec2(0, 0), vec2(1, 1), vec2(0, 1));
const vec3 ORG[6] = vec3[](vec3(0,0,0), vec3(1,0,1), vec3(0,0,0), vec3(0,1,1), vec3(1,0,0), vec3(0,0,1));
const vec3 UAX[6] = vec3[](vec3(0,0,1), vec3(0,0,-1), vec3(1,0,0), vec3(1,0,0), vec3(-1,0,0), vec3(1,0,0));
const vec3 VAX[6] = vec3[](vec3(0,1,0), vec3(0,1,0), vec3(0,0,1), vec3(0,0,-1), vec3(0,1,0), vec3(0,1,0));

void main() {
    uint f = uint(gl_VertexID) / 6u;
    vec2 q = QUAD[uint(gl_VertexID) % 6u];
    vec3 p = (ORG[f] + UAX[f] * q.x + VAX[f] * q.y - 0.5) * 1.004 + 0.5 + u_min;
    v_uv = q;
    v_face = f;
    gl_Position = u_viewproj * vec4(p, 1.0);
    gl_Position.z += 2.0e-5 * gl_Position.w;    // (reverse-Z: a hair nearer)
}
