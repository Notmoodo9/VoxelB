#version 450 core
// First person: the arm and what it holds (milestone 18; reworked after
// v0.19.3 to look like Minecraft's, D101). Drawn after the frame is
// finished, with its own cleared depth buffer. Vertex pulling, 36 vertices
// (6 faces x 2 triangles) per box:
//   u_part 0  the arm: one box, skin with a sleeve, from the lower right of
//             the view up to the fist;
//   u_part 1  a block in the hand: a small cube at the fist, turned 45 deg;
//   u_part 2  an item or a flat block (plants, doors ...): its 16 x 16
//             picture as a thin model, one 1/16 box per pixel (empty pixels
//             and the dark outline pixels around the picture are left out),
//             held diagonally at the fist like a tool.
// The whole hand sways while walking, swings in an arc when used and dips
// while the item in hand changes.

layout(std430, binding = 1) readonly buffer Faces { uint block_face[]; };
layout(std430, binding = 2) readonly buffer Textures { uvec4 tex_info[]; };
layout(binding = 1) uniform sampler2D u_icons;

layout(location = 0) uniform uint u_block;
layout(location = 1) uniform int u_part;        // 0 arm, 1 block, 2 picture
layout(location = 2) uniform vec4 u_icon_uv;    // u0, v0 (top), u1, v1
layout(location = 3) uniform float u_swing;     // 0..1 through a swing
layout(location = 4) uniform vec2 u_bob;        // walking sway
layout(location = 5) uniform float u_aspect;
layout(location = 7) uniform int u_mirror;      // 1: the off hand (lower left, mirrored)
layout(location = 8) uniform float u_equip;     // 0 lowered .. 1 up (the item changed)
layout(location = 9) uniform int u_empty;       // 1: nothing in this hand (the arm reaches further)

out vec2 v_uv;
flat out uint v_layer;
flat out float v_shade;
flat out int v_part;
flat out vec3 v_color;                          // a picture's pixel colour
out vec3 v_arm;                                 // the arm: position on the box (0..1)

const vec2 QUAD[6] = vec2[](vec2(0, 0), vec2(1, 0), vec2(1, 1),
                            vec2(0, 0), vec2(1, 1), vec2(0, 1));
// per face (-X +X -Y +Y -Z +Z): origin, u axis, v axis, normal
const vec3 ORG[6] = vec3[](vec3(0,0,0), vec3(1,0,1), vec3(0,0,0), vec3(0,1,1), vec3(1,0,0), vec3(0,0,1));
const vec3 UAX[6] = vec3[](vec3(0,0,1), vec3(0,0,-1), vec3(1,0,0), vec3(1,0,0), vec3(-1,0,0), vec3(1,0,0));
const vec3 VAX[6] = vec3[](vec3(0,1,0), vec3(0,1,0), vec3(0,0,1), vec3(0,0,-1), vec3(0,1,0), vec3(0,1,0));
const vec3 NRM[6] = vec3[](vec3(-1,0,0), vec3(1,0,0), vec3(0,-1,0), vec3(0,1,0), vec3(0,0,-1), vec3(0,0,1));

mat3 rot_x(float a) { float c = cos(a), s = sin(a); return mat3(1, 0, 0, 0, c, s, 0, -s, c); }
mat3 rot_y(float a) { float c = cos(a), s = sin(a); return mat3(c, 0, -s, 0, 1, 0, s, 0, c); }
mat3 rot_z(float a) { float c = cos(a), s = sin(a); return mat3(c, s, 0, -s, c, 0, 0, 0, 1); }

// light by the face's direction in view space: lit from the upper left
float face_shade(vec3 n) {
    return 0.62 + 0.38 * clamp(dot(n, normalize(vec3(-0.35, 0.85, 0.4))), 0.0, 1.0);
}

// an icon pixel (x right, y up from the bottom), its colour and alpha
vec4 icon_px(int x, int y) {
    if (x < 0 || y < 0 || x > 15 || y > 15) return vec4(0.0);
    vec2 t = (vec2(x, 15 - y) + 0.5) / 16.0;
    return textureLod(u_icons, mix(u_icon_uv.xy, u_icon_uv.zw, t), 0.0);
}
bool solid(int x, int y) {
    vec4 c = icon_px(x, y);
    if (c.a < 0.5) return false;
    // the picture's dark outline (icons are drawn with one) is left out:
    // in the hand the model's own sides make the edge
    bool edge = icon_px(x - 1, y).a < 0.5 || icon_px(x + 1, y).a < 0.5 ||
                icon_px(x, y - 1).a < 0.5 || icon_px(x, y + 1).a < 0.5;
    return !(edge && dot(c.rgb, vec3(0.299, 0.587, 0.114)) < 0.16);
}

void main() {
    uint box = uint(gl_VertexID) / 36u;
    uint k = uint(gl_VertexID) % 36u;
    uint f = k / 6u;
    vec2 q = QUAD[k % 6u];
    vec3 c01 = ORG[f] + UAX[f] * q.x + VAX[f] * q.y;   // corner of a unit box
    v_part = u_part;
    v_arm = c01;
    v_color = vec3(1.0);
    v_uv = vec2(q.x, 1.0 - q.y);
    v_layer = 0u;

    // ---- the hand's pose: sway, swing (Minecraft-like arc), equip dip ----
    float t = clamp(u_swing, 0.0, 1.0);
    float sw = sin(t * 3.14159265);
    float sw2 = sin(sqrt(t) * 3.14159265);
    vec3 hand = vec3(0.42, -0.34, -0.84);                 // the fist
    if (u_empty == 1) hand = vec3(0.36, -0.27, -0.8);
    // Minecraft's swing: the fist moves in toward the middle and back, a
    // little up then down; what it holds tips forward about the fist
    hand += vec3(u_bob.x - 0.3 * sw2, u_bob.y + 0.14 * sin(sqrt(t) * 6.2831853) - 0.6 * (1.0 - u_equip),
                 -0.16 * sw);
    mat3 swing = rot_y(-0.35 * sin(t * t * 3.14159265)) * rot_z(-0.3 * sw2) * rot_x(-1.1 * sw2);

    vec3 p, n;
    if (u_part == 0) {
        // the arm: 4 x 12 x 4 pixels, from the lower right corner (the
        // elbow, off screen) up and in to the fist
        vec3 local = (c01 - vec3(0.5, 1.0, 0.5)) * vec3(0.17, 0.7, 0.17);   // fist at the top
        vec3 d = normalize(vec3(-0.63, 0.59, -0.49));      // elbow -> fist
        vec3 side = normalize(cross(d, vec3(0.0, 0.0, 1.0)));
        mat3 r = mat3(side, d, cross(side, d));
        p = r * local + hand + vec3(0.0, -0.06, 0.06);
        n = r * NRM[f];
        v_shade = face_shade(n);
    } else if (u_part == 1) {
        // a block: a cube at the fist, a quarter turn and tipped toward the eye
        uint bf = block_face[u_block * 6u + f];
        v_layer = tex_info[bf & 0xFFFFu].x;
        mat3 r = swing * rot_x(0.42) * rot_y(0.78);
        p = r * ((c01 - vec3(0.5)) * 0.2) + hand + vec3(-0.01, 0.07, -0.03);
        n = r * NRM[f];
        v_shade = face_shade(n);
    } else {
        // a picture as a thin model: box = pixel x + 16 y
        int px = int(box % 16u), py = int(box / 16u);
        if (!solid(px, py)) { gl_Position = vec4(0.0); return; }
        // a side between two solid pixels is never seen: skip it
        if ((f == 0u && solid(px - 1, py)) || (f == 1u && solid(px + 1, py)) ||
            (f == 2u && solid(px, py - 1)) || (f == 3u && solid(px, py + 1))) {
            gl_Position = vec4(0.0); return;
        }
        v_color = icon_px(px, py).rgb;
        // pixel space: 16 x 16 x 1, the grip (pixel 3, 3) at the origin;
        // mirrored, as the right hand shows it (the handle in the fist, the
        // head toward the middle of the view)
        vec3 local = (vec3(float(px), float(py), -0.5) + c01 - vec3(3.0, 3.0, 0.0)) / 16.0 * 0.48;
        local.x = -local.x;
        mat3 r = swing * rot_y(0.55) * rot_z(-0.12) * rot_x(-0.3);
        p = r * local + hand + vec3(0.045, -0.06, 0.03);
        n = r * (NRM[f] * vec3(-1.0, 1.0, 1.0));
        v_shade = face_shade(n) * (f >= 4u ? 1.0 : 0.82);   // the flat sides brightest
    }
    if (u_mirror == 1) p.x = -p.x;                          // the off hand: lower left
    const float F = 1.428;                                  // cot(35 deg): a fixed 70 deg view
    float w = -p.z;
    // reverse-Z like the world (depth cleared to 0, GL_GREATER): nearer is larger
    gl_Position = vec4(p.x * F / u_aspect, p.y * F, (1.0 - w * 0.5) * w, w);
}
