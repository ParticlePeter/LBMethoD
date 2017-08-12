#version 450

layout( location = 0 ) out  vec4 fs_color;      // output from fragment shader


void main() {
    fs_color = vec4( 1, 1, 0, 1 );
}