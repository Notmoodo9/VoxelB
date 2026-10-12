#version 450 core
// World sections: vertex pulling from packed greedy quads (format in
// src/render/mesher.asm) and model quads of shaped blocks (src/render/shapes.asm). 6 vertices per quad, no vertex buffers. Rendering
// is camera-relative (section origin - camera). Milestone 11: drawn with
// glMultiDrawArraysIndirect; the draw records are an instanced vertex
// buffer (stride 32, divisor 1), so the command's base instance picks the
// draw's origins as attributes; gl_VertexID counts from the command's first
// vertex (first quad * 6).
// Milestone 12: distant terrain tiles (src/world/lod.asm) share the buffer;
// a record's count attribute carries the tile's level in its top byte
// (0 = a section). LOD quads are whole cells of 2^level blocks (format in
// src/include/lod.inc); the origin's world y holds the tile's box height.
// Textures: block face -> texture (binding 1), texture -> array layers and
// animation (binding 2); see src/render/block_textures.asm.

layout(std430, binding = 0) readonly buffer Quads { uvec2 quads[]; };
layout(std430, binding = 1) readonly buffer Faces { uint block_face[]; };
layout(std430, binding = 2) readonly buffer Textures { uvec4 tex_info[]; };

layout(location = 0) uniform mat4 u_viewproj;     // rotation + projection
layout(location = 0) in vec3 a_origin_rel;        // section origin - camera
layout(location = 1) in vec3 a_origin_world;      // section origin (mod 65536)
layout(location = 2) in uint a_count;             // quads | LOD level << 24
layout(location = 4) uniform float u_time;        // seconds

out vec3 v_rel;          // camera-relative position (fog)
out vec2 v_tuv;          // biome tint map coordinates (world x, z / 4096)
flat out uint v_tint;    // 0 none, 1 grass, 2 foliage (tint map layer + 1)
out vec2 v_uv;           // texel space / 16 (repeats per block)
flat out uint v_face;
flat out uvec2 v_layers; // current and next animation frame
flat out float v_mix;    // blend between them (interpolated animations)
flat out uint v_glow;    // glow layer + 1 (0 = none)
flat out uint v_level;   // LOD level (0 = full detail)

// corner order per face; faces 1, 3, 4 (+X, +Y, -Z) are mirrored so every
// face winds counter-clockwise seen from outside (back-face culling)
const uint CORNERS[12] = uint[](0u, 1u, 2u, 0u, 2u, 3u,
                                0u, 2u, 1u, 0u, 3u, 2u);

void main() {
    vec3 u_origin_rel = a_origin_rel;
    vec3 u_origin_world = a_origin_world;
    uvec2 q = quads[uint(gl_VertexID) / 6u];
    uint lo = q.x;
    uint level = a_count >> 24;
    uint face = level > 0u ? (lo >> 21) & 7u : (lo >> 28) & 7u;
    bool flip = (face == 1u || face == 3u || face == 4u);
    uint c = CORNERS[(flip ? 6u : 0u) + uint(gl_VertexID) % 6u];
    vec3 p;      // block-space position of the face's first corner
    float w, h;  // extent along u and v
    float side;  // offset of the face plane along its axis
    float bend = 0.0;   // plants: how far this vertex sways (0 at the ground)
    bool plant = false;
    if (level > 0u) {
        // LOD quad: x, z in cells, y in blocks above the tile's lowest quad;
        // widths in cells, heights in cells (top faces) or blocks (sides)
        float S = float(1u << level);
        uint axis = face >> 1;
        p = vec3(float(lo & 31u) * S, float((lo >> 10) & 2047u), float((lo >> 5) & 31u) * S);
        w = float(((lo >> 24) & 31u) + 1u) * S;
        h = float(((q.y >> 16) & 2047u) + 1u) * (axis == 1u ? S : 1.0);
        side = (face & 1u) != 0u ? (axis == 1u ? 1.0 : S) : 0.0;
    } else if (face >= 6u) {
        // plant: one of two diagonal planes through the box (both sides drawn)
        plant = true;
        vec3 blk = vec3(float(lo & 31u), float((lo >> 5) & 31u), float((lo >> 10) & 31u));
        vec3 bmin = vec3(float((lo >> 15) & 15u), float((lo >> 19) & 15u), float((lo >> 23) & 15u));
        vec3 bsize = vec3(float(((q.y >> 16) & 15u) + 1u), float(((q.y >> 20) & 15u) + 1u),
                          float(((q.y >> 24) & 15u) + 1u)) / 16.0;
        uint cc = CORNERS[uint(gl_VertexID) % 6u];
        float s = (cc == 1u || cc == 2u) ? 1.0 : 0.0;
        float t = (cc >= 2u) ? 1.0 : 0.0;
        p = blk + bmin / 16.0;
        p.x += (face == 6u ? s : 1.0 - s) * bsize.x;
        p.z += s * bsize.z;
        p.y += t * bsize.y;
        v_uv = vec2(s, -t);
        bend = t + float((q.y >> 28) & 1u);
    } else if ((lo & 0x80000000u) == 0u) {
        // greedy cube quad: whole blocks
        p = vec3(float(lo & 63u), float((lo >> 6) & 63u), float((lo >> 12) & 63u));
        w = float(((lo >> 18) & 31u) + 1u);
        h = float(((lo >> 23) & 31u) + 1u);
        side = float(face & 1u);
    } else {
        // model quad: one face of a box inside a block, in 1/16 units
        vec3 blk = vec3(float(lo & 31u), float((lo >> 5) & 31u), float((lo >> 10) & 31u));
        vec3 bmin = vec3(float((lo >> 15) & 15u), float((lo >> 19) & 15u), float((lo >> 23) & 15u));
        vec3 bsize = vec3(float(((q.y >> 16) & 15u) + 1u), float(((q.y >> 20) & 15u) + 1u),
                          float(((q.y >> 24) & 15u) + 1u)) / 16.0;
        p = blk + bmin / 16.0;
        uint ax = face >> 1;
        side = (face & 1u) != 0u ? bsize[ax] : 0.0;
        if (ax == 0u)      { w = bsize.z; h = bsize.y; }
        else if (ax == 1u) { w = bsize.x; h = bsize.z; }
        else               { w = bsize.x; h = bsize.y; }
    }
    if (!plant) {
        float du = (c == 1u || c == 2u) ? w : 0.0;
        float dv = (c >= 2u) ? h : 0.0;
        uint axis = face >> 1;
        if (axis == 0u)      { p.x += side; p.z += du; p.y += dv; }   // u = z, v = y
        else if (axis == 1u) { p.y += side; p.x += du; p.z += dv; }   // u = x, v = z
        else                 { p.z += side; p.x += du; p.y += dv; }   // u = x, v = y

        // texture coordinates: side faces upright (row 0 at the top), the
        // horizontal axis running left to right as seen from outside
        if (axis == 0u)      v_uv = vec2(face == 0u ? p.z : -p.z, -p.y);
        else if (axis == 1u) v_uv = vec2(p.x, p.z);
        else                 v_uv = vec2(face == 5u ? p.x : -p.x, -p.y);
    }

    uint block = q.y & 0xFFFFu;
    uint bf = block_face[block * 6u + (plant ? 0u : face)];   // plants: one texture
    uvec4 info = tex_info[bf & 0xFFFFu];
    uint frames = info.y & 0xFFFFu;
    float t = u_time * 1000.0 / float(max(info.z, 1u));
    uint frame = uint(t) % frames;
    v_layers = uvec2(info.x + frame, info.x + (frame + 1u) % frames);
    v_mix = ((info.y >> 16) != 0u) ? fract(t) : 0.0;
    v_glow = 0u;
    if (info.w != 0u) {
        uint gframes = max(info.w >> 16, 1u);
        v_glow = (info.w & 0xFFFFu) + frame % gframes;
    }
    v_face = face;
    v_level = level;
    vec3 wp = u_origin_world + p;
    v_tint = (bf >> 19) & 3u;
    // one tint texel per 4 x 4 blocks (texel centres at 4i + 2); LOD tiles:
    // their own map, one texel per 16 x 16 blocks
    v_tuv = wp.xz / (level > 0u ? 16384.0 : 4096.0);

    vec3 rel = u_origin_rel + p;
    if (((bf >> 16) & 1u) != 0u && level == 0u) {
        // sway: a slow wind wave over world position (vertices on shared
        // corners move together, so no cracks). Plants bend from the ground.
        float phase = u_time * 1.7 + wp.x * 0.35 + wp.z * 0.27 + wp.y * 0.2;
        if (plant) {
            float ph = u_time * 2.1 + floor(wp.x) * 0.31 + floor(wp.z) * 0.23;
            rel.x += 0.09 * bend * sin(ph);
            rel.z += 0.07 * bend * sin(ph * 0.79 + 1.1);
        } else {
            rel.x += 0.045 * sin(phase);
            rel.z += 0.035 * sin(phase * 0.83 + 1.3);
        }
    }
    v_rel = rel;
    gl_Position = u_viewproj * vec4(rel, 1.0);
}
