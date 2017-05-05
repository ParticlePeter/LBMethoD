#version 450

layout( location = 0 ) in   vec2 vs_texcoord;	// input from vertex shader
layout( location = 0 ) out  vec4 fs_color;		// output from fragment shader

void main() {
    fs_color = vec4( vs_texcoord, 0, 1 );
}