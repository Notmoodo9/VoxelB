#version 450 core
// The outline of the targeted block (milestone 16): the 12 edges of a box
// as 24 line vertices, pulled from gl_VertexID (no vertex buffer).

layout(location = 0) uniform mat4 u_viewproj;   // camera rotation + projection
layout(location = 1) uniform vec3 u_min;        // box corner, camera-relative
layout(location = 2) uniform vec3 u_size;

// corner index bits: 1 = +x, 2 = +y, 4 = +z
const int EDGES[24] = int[](0, 1, 2, 3, 4, 5, 6, 7,     // along x
                            0, 2, 1, 3, 4, 6, 5, 7,     // along y
                            0, 4, 1, 5, 2, 6, 3, 7);    // along z

void main() {
    int c = EDGES[gl_VertexID];
    vec3 p = u_min + vec3(c & 1, (c >> 1) & 1, (c >> 2) & 1) * u_size;
    gl_Position = u_viewproj * vec4(p, 1.0);
    // a hair towards the camera (reverse-Z: larger is nearer), so the
    // lines win against the block's own faces
    gl_Position.z += 2.0e-5 * gl_Position.w;
}
