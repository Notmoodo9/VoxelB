#version 450 core
// Debug test scene shading: sun + ambient, ground checker, distance fog into
// the clear colour. Edit and save while the game runs to try hot reload.

layout(location = 1) uniform vec3 u_cam_pos;

in vec3 v_world;
in vec3 v_normal;
in vec3 v_color;
flat in int v_ground;

out vec4 o_color;

const vec3 SKY = vec3(0.33, 0.62, 0.98);
const vec3 SUN_DIR = normalize(vec3(0.45, 0.85, 0.30));

void main() {
    vec3 color = v_color;
    if (v_ground != 0) {
        ivec2 cell = ivec2(floor(v_world.xz / 2.0));
        color *= ((cell.x + cell.y) & 1) == 0 ? 1.0 : 0.82;
    }
    float diffuse = max(dot(normalize(v_normal), SUN_DIR), 0.0);
    color *= 0.38 + 0.72 * diffuse;
    float dist = length(v_world - u_cam_pos);
    float fog = 1.0 - exp(-dist * 0.006);
    o_color = vec4(mix(color, SKY, clamp(fog, 0.0, 1.0)), 1.0);
}
