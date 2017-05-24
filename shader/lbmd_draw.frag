#version 450

layout( location = 0 ) in   vec2 vs_texcoord;   // input from vertex shader
layout( location = 0 ) out  vec4 fs_color;      // output from fragment shader

layout( binding = 4 ) uniform sampler2D vel_rho_tex[2];      // VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE

// uniform buffer
layout( std140, binding = 6 ) uniform Display_UBO {
    uint    display_property;
    float   amplify_property;
};

#define DISPLAY_DENSITY 0
#define DISPLAY_VELOCITY_MAGNITUDE 1
#define DISPLAY_VELOCITY_GRADIENT 2
#define DISPLAY_VELOCITY_CURL 3


// Blue : 0.0 - 0.25 - 0.5
// Green: 0.0 - 0.25 -  -  - 0.75 - 1.0
// Red  :                    0.5  - 0.75 - 1.0
/*
float ramp( float start, float end, float t ) {
    return clamp( 0, 1, ( t - start ) / ( end - start ));
}

float triangle( float start, float mid, float end, float t ) {
    return clamp( 0, 1, ( t - start ) / ( mid - start )) - clamp( 0, 1, ( t - mid ) / ( end - mid ));
}


//vec3 colorRamp( float t ) {
//    return vec3(
//        ramp( 0.5, 1, t ),
//        triangle( 0.25, 0.50, 0.75, t ),
//        triangle( 0.00, 0.25, 0.50, t ));
//}


      
// R: 0 0 0 0 1 1  
// G: 0 0 1 1 1 0
// B: 0 1 1 0 0 0
vec3 colorRamp( float t ) {
    return vec3(
        ramp(                                   0.6, 0.8, t ),
        ramp(      0.2,             0.4, t ) - ramp( 0.8, 1.0, t ),
        ramp( 0.0, 0.2, t ) - ramp( 0.4,        0.6, t )
    );
}

/*/

vec3 colorRamp( float t ) {
    return 5 * vec3(
        clamp( t,                                0.6,      0.8 )      - 0.6,
        clamp( t,      0.2,              0.4 ) - clamp( t, 0.8, 1.0 ) + 0.6,
        clamp( t, 0.0, 0.2 ) - clamp( t, 0.4,    0.6 )                + 0.4
    );
}
//*/


void main() {

    // get velocity and densoty data
    vec4 vel_rho = texture( vel_rho_tex[0], vs_texcoord );                          // access velocity density texture

    switch( display_property ) {
        case DISPLAY_DENSITY :
        fs_color = vec4( colorRamp( amplify_property * vel_rho.a ), 1 );
        break; 

        case DISPLAY_VELOCITY_MAGNITUDE :
        fs_color = vec4( colorRamp( amplify_property * length( vel_rho.xy )), 1 );
        break;

        case DISPLAY_VELOCITY_GRADIENT :
        float speed = amplify_property * length( vel_rho.xy  );                                // amplified velocity magnitude                                                      
        fs_color = vec4( 0.5 + dFdx( speed ), 0.5 + dFdy( speed ), 0, 1 );
        break;

        case DISPLAY_VELOCITY_CURL :
        vel_rho *= amplify_property;
        float curl = ( dFdx( vel_rho.y ) - dFdy( vel_rho.x ));  // compute 2D curl   
        fs_color = vec4( max( 0, curl ), max( 0, -curl ), 0, 1 );
    }

}