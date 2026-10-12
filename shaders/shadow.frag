#version 450 core
// Shadow pass (milestone 14 part 2): depth only, from chunk.vert with a
// cascade selected (u_cascade). Cut-out textures (leaves, plants) are
// alpha-tested, so their holes let light through.

layout(binding = 0) uniform sampler2DArray u_blocks;

in vec2 v_uv;
flat in uvec2 v_layers;

void main() {
    float a = textureLod(u_blocks, vec3(v_uv, float(v_layers.x)), 0.0).a;
    if (a < 0.5) discard;
}
