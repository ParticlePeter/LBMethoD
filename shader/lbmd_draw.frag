#version 450

layout( location = 0 ) in   vec2 vs_texcoord;	// input from vertex shader
layout( location = 0 ) out  vec4 fs_color;		// output from fragment shader

layout( binding = 4 ) uniform sampler2D vel_rho_tex;      // VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE


// Blue	: 0.0 - 0.25 - 0.5
// Green	: 0.0	- 0.25 -  - - 0.75 - 1.0
// Red	:					0.5 - 0.75 - 1.0

vec3 ramp( float t ) {
	return 4 * vec3(
		clamp( t, 0.5, 0.75 ) - 0.5,
		clamp( t, 0.0, 0.25 ) - clamp( t, 0.75, 1.0 ) + 0.75,
		0.5 - clamp( t, 0.25, 0.5 ));
}


void main() {
	vec3 vel_rho = texture( vel_rho_tex, vs_texcoord ).rgb;
    fs_color = vec4( ramp( 1 * length( vel_rho.rg )), 1 );
    //fs_color = vec4( ramp( 0.5 * vel_rho.b ), 1 );


    //fs_color = vec4( texture( vel_rho_tex, vs_texcoord ).b, 0, 0, 1 );

    //float rho = texture( vel_rho_tex, vs_texcoord ).b;
    //fs_color = vec4( rho <= 1.0 / 40 ? 0 : rho + 5.0 / 9 ) ;
}