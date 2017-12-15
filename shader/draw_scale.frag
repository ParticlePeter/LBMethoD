#version 450

layout( location = 0 ) in   vec2 vs_tex_coord;   // input from vertex shader
layout( location = 0 ) out  vec4 fs_color;      // output from fragment shader


// R: 0 0 0 0 1 1
// G: 0 0 1 1 1 0
// B: 0 1 1 0 0 0

const vec3[] ramp = {
    vec3( 0, 0, 0 ),
    vec3( 0, 0, 1 ),
    vec3( 0, 1, 1 ),
    vec3( 0, 1, 0 ),
    vec3( 1, 1, 0 ),
    vec3( 1, 0, 0 )
};


vec3 colorRamp( float t ) {
    t *= ( ramp.length() - 1 );
    ivec2 i = ivec2( floor( min( vec2( t, t + 1 ), vec2( ramp.length() - 1 ))));
    float f = fract( t );
    return mix( ramp[ i.x ], ramp[ i.y], f );
}


void main() {
    fs_color = vec4( colorRamp( vs_tex_coord.y ), 1 );
    //fs_color = vec4( 1 );
}