#version 450 core
// Debug test scene (Milestone 3): a 32x32 field of block columns plus a
// checkered ground quad, generated from gl_VertexID alone (no vertex data).
// Rendering is camera-relative: u_viewproj holds rotation + projection only.

layout(location = 0) uniform mat4 u_viewproj;
layout(location = 1) uniform vec3 u_cam_pos;

out vec3 v_world;
out vec3 v_normal;
out vec3 v_color;
flat out int v_ground;

const int GRID = 32;
const float SPACING = 2.0;

// two triangles per face, as (a, b) coordinates on the face
const vec2 QUAD[6] = vec2[](vec2(0, 0), vec2(1, 0), vec2(1, 1),
                            vec2(0, 0), vec2(1, 1), vec2(0, 1));

uint hash(uint x) {
    x ^= x >> 16; x *= 0x7feb352du;
    x ^= x >> 15; x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

vec3 palette(float t) {
    // vivid ramp: grass green -> lime -> yellow -> orange -> magenta
    const vec3 c[5] = vec3[](vec3(0.10, 0.75, 0.25), vec3(0.55, 0.90, 0.15),
                             vec3(1.00, 0.85, 0.10), vec3(1.00, 0.45, 0.10),
                             vec3(0.90, 0.15, 0.60));
    float x = clamp(t, 0.0, 1.0) * 4.0;
    int i = min(int(x), 3);
    return mix(c[i], c[i + 1], x - float(i));
}

void main() {
    int cube = gl_VertexID / 36;
    int v = gl_VertexID % 36;
    int face = v / 6;
    vec2 q = QUAD[v % 6];

    if (cube == GRID * GRID) {
        // ground quad: only the first 6 vertices are used
        if (v >= 6) { gl_Position = vec4(0.0); return; }
        float half_size = 400.0;
        vec3 p = vec3((q.x * 2.0 - 1.0) * half_size, 0.0, (q.y * 2.0 - 1.0) * half_size);
        v_world = p;
        v_normal = vec3(0.0, 1.0, 0.0);
        v_color = vec3(0.30, 0.55, 0.30);
        v_ground = 1;
        gl_Position = u_viewproj * vec4(p - u_cam_pos, 1.0);
        return;
    }

    int gx = cube % GRID;
    int gz = cube / GRID;
    vec2 c = vec2(gx, gz) - vec2(GRID) * 0.5;
    // smooth hills plus a little per-column noise
    float hill = 5.0 + 4.0 * sin(c.x * 0.35) * cos(c.y * 0.28);
    float h = max(1.0, floor(hill + float(hash(uint(cube)) % 3u)));

    int axis = face / 2;            // 0 x, 1 y, 2 z
    float side = float(face % 2);   // 0 = low side, 1 = high side
    vec3 unit;
    unit[axis] = side;
    unit[(axis + 1) % 3] = q.x;
    unit[(axis + 2) % 3] = q.y;
    vec3 n = vec3(0.0);
    n[axis] = side * 2.0 - 1.0;

    vec3 base = vec3(c.x * SPACING, 0.0, c.y * SPACING);
    vec3 p = base + unit * vec3(SPACING * 0.9, h, SPACING * 0.9);
    v_world = p;
    v_normal = n;
    v_color = palette((h - 1.0) / 10.0);
    v_ground = 0;
    gl_Position = u_viewproj * vec4(p - u_cam_pos, 1.0);
}
