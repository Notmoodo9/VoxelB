#version 450 core
// World sections, Milestone 5 shading: flat debug colour per block (until the
// textured block registry of M7), per-block brightness jitter and subtle
// block-edge lines so single blocks stay visible inside merged quads, simple
// directional face shading and distance fog into the sky colour.

layout(std430, binding = 1) readonly buffer Colors { uint block_color[]; };

in vec3 v_world;
in vec3 v_rel;
flat in uint v_block;
flat in uint v_face;

out vec4 o_color;

const vec3 SKY = vec3(0.33, 0.62, 0.98);
const float FACE_LIGHT[6] = float[](0.78, 0.78, 0.52, 1.0, 0.66, 0.66);

float hash3(ivec3 p) {
    uint h = uint(p.x) * 73856093u ^ uint(p.y) * 19349663u ^ uint(p.z) * 83492791u;
    h ^= h >> 13; h *= 0x5bd1e995u; h ^= h >> 15;
    return float(h & 1023u) / 1023.0;
}

void main() {
    vec3 color = unpackUnorm4x8(block_color[v_block]).rgb;

    // which block is this fragment on? step half a block inwards
    vec3 n = vec3(0.0);
    n[v_face >> 1] = (v_face & 1u) == 1u ? 1.0 : -1.0;
    ivec3 cell = ivec3(floor(v_world - n * 0.5));
    color *= 0.93 + 0.12 * hash3(cell);

    // block edges: darken near the cell border on the two in-plane axes
    vec3 f = fract(v_world);
    vec3 edge = min(f, 1.0 - f);
    float e = 1.0;
    for (int i = 0; i < 3; i++)
        if (i != int(v_face >> 1)) e = min(e, edge[i]);
    color *= mix(0.82, 1.0, smoothstep(0.0, 0.045, e));

    color *= FACE_LIGHT[v_face];

    float dist = length(v_rel);
    float fog = 1.0 - exp(-dist * 0.0028);
    o_color = vec4(mix(color, SKY, clamp(fog, 0.0, 1.0)), 1.0);
}
