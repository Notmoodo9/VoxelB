#version 450 core
// One triangle that covers the screen (vertices 0..2, no buffers), for the
// sky and the post-processing passes (milestone 14). v_dir is the
// camera-relative view direction through the pixel (sky only: needs
// u_viewproj, the camera's rotation + projection).

layout(location = 0) uniform mat4 u_viewproj;

out vec2 v_uv;      // 0..1 across the screen
out vec3 v_dir;     // view ray (not normalised)

void main() {
    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    v_uv = p;
    vec2 ndc = p * 2.0 - 1.0;
    // depth 0: the far plane with reverse-Z
    gl_Position = vec4(ndc, 0.0, 1.0);
    vec4 w = inverse(u_viewproj) * vec4(ndc, 0.5, 1.0);
    v_dir = w.xyz / w.w;
}
