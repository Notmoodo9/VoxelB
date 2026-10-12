#version 450 core
// The targeted block's outline: thin dark lines (linear HDR scene colour).

out vec4 o_color;

void main() {
    o_color = vec4(0.01, 0.01, 0.012, 1.0);
}
