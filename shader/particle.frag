#version 450

layout( location = 0 ) in   vec4 vs_color;      // input from vertex shader
layout( location = 0 ) out  vec4 fs_color;      // output from fragment shader


void main() {
    // round particle appereance through discarding fragments
    float dist = 1 - smoothstep( 0.4, 0.5, length( gl_PointCoord.st - 0.5 ));
    if ( dist < 0.01 ) discard;
    fs_color = vs_color;
}