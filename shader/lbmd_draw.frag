#version 450

layout( location = 0 ) in   vec2 vs_texcoord;   // input from vertex shader
layout( location = 0 ) out  vec4 fs_color;      // output from fragment shader

layout( binding = 4 ) uniform sampler2D vel_rho_tex[2];      // VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE

// uniform buffer
layout( std140, binding = 5 ) uniform Sim_UBO {
    float omega;
    float amp_speed;
};


// Blue : 0.0 - 0.25 - 0.5
// Green: 0.0 - 0.25 -  -  - 0.75 - 1.0
// Red  :              0.5 - 0.75 - 1.0

vec3 ramp( float t ) {
    return 4 * vec3(
        clamp( t, 0.5, 0.75 ) - 0.5,
        clamp( t, 0.0, 0.25 ) - clamp( t, 0.75, 1.0 ) + 0.75,
        0.5 - clamp( t, 0.25, 0.5 ));
}


void main() {
    vec4 vel_rho = texture( vel_rho_tex[0], vs_texcoord );                      // access velocity density texture
    //fs_color = vec4( vel_rho.a, 0, 0, 1 );                                      // draw density
    //fs_color = vec4( ramp( 0.5 * vel_rho.a ), 1 );                              // draw density with ramp
    //fs_color = vec4( ramp( 3 * length( vel_rho.xyz )), 1 );                     // draw velocity magnitude with ramp
    
    float speed = amp_speed * length( vel_rho.xy  );                            // amplified velocity magnitude                                                      
    fs_color = vec4( 0.5 + dFdx( speed ), 0.5 + dFdy( speed ), 0, 1 );          // draw gradient
    
    //float curl = ( dFdx( speed * vel_rho.y ) - dFdy( speed * vel_rho.x ));      // compute 2D curl   
    //fs_color = vec4( max( 0, curl ), max( 0, -curl ), 0, 1 );                   // draw 2D curl
}