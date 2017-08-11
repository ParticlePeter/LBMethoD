#version 450

layout( location = 0 ) in   vec2 vs_tex_coord;   // input from vertex shader
layout( location = 0 ) out  vec4 fs_color;      // output from fragment shader

layout( binding = 4 ) uniform sampler2D vel_rho_tex;      // VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE

// uniform buffer
layout( std140, binding = 6 ) uniform Display_UBO {
    uint    display_property;
    float   amplify_property;
    uint    color_layers;
};

#define DISPLAY_DENSITY 0
#define DISPLAY_VELOCITY_X 1
#define DISPLAY_VELOCITY_Y 2
#define DISPLAY_VELOCITY_MAGNITUDE 3
#define DISPLAY_VELOCITY_GRADIENT 4
#define DISPLAY_VELOCITY_CURL 5



// Blue : 0.0 - 0.25 - 0.5
// Green: 0.0 - 0.25 -  -  - 0.75 - 1.0
// Red  :                    0.5  - 0.75 - 1.0

const vec3[] ramp = {
    vec3( 0, 0, 0 ),
    vec3( 0, 0, 1 ),
    vec3( 0, 1, 1 ),
    vec3( 0, 1, 0 ),
    vec3( 1, 1, 0 ),
    vec3( 1, 0, 0 )
};

/*
float ramp( float start, float end, float t ) {
    return clamp( 0, 1, ( t - start ) / ( end - start ));
}
*/
float triangle( float start, float mid, float end, float t ) {
    return clamp( 0, 1, ( t - start ) / ( mid - start )) - clamp( 0, 1, ( t - mid ) / ( end - mid ));
}

float hermite( float start, float mid, float end, float t ) {
    return smoothstep( start, mid, t ) - smoothstep( mid, end, t );
}

float box( float start, float end, float t ) {
    return step( start, t ) - step( end, t );
}

float smoothbox( float start, float end, float s, float t ) {
    return smoothstep( start - s, start + s, t ) - smoothstep( end - s, end + s, t );
}


/*
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
//*
    t *= ( ramp.length() - 1 );
    ivec2 i = ivec2( floor( min( vec2( t, t + 1 ), vec2( ramp.length() - 1 ))));
    float f = fract( t );
    return mix( ramp[ i.x ], ramp[ i.y], f );
/*/
    return 5 * vec3(
        clamp( t,                                0.6,      0.8 )      - 0.6,
        clamp( t,      0.2,              0.4 ) - clamp( t, 0.8, 1.0 ) + 0.6,
        clamp( t, 0.0, 0.2 ) - clamp( t, 0.4,    0.6 )                + 0.4
    );
//*/
}
//*/


void main() {

    // get velocity and densoty data
    vec4 vel_rho = texture( vel_rho_tex, vs_tex_coord );                          // access velocity density texture

    switch( display_property ) {
        case DISPLAY_DENSITY :
            fs_color = vec4( colorRamp( amplify_property * vel_rho.a ), 1 );
        break;

        case DISPLAY_VELOCITY_X :
            if( color_layers == 0 ) vel_rho *= amplify_property;
            else vel_rho = trunc( vel_rho * color_layers * amplify_property ) / color_layers;
            fs_color = vec4( max( 0, vel_rho.x ), max( 0, - vel_rho.x ), 0, 1 );
        break;

        case DISPLAY_VELOCITY_Y :
                        if( color_layers == 0 ) vel_rho *= amplify_property;
            else vel_rho = trunc( vel_rho * color_layers * amplify_property ) / color_layers;
            fs_color = vec4( max( 0, vel_rho.y ), max( 0, - vel_rho.y ), 0, 1 );
        break;  

        case DISPLAY_VELOCITY_MAGNITUDE : {
            float vel_mag;
            if( color_layers == 0 )
                vel_mag = amplify_property * length( vel_rho.xy );
            else
                vel_mag = floor( color_layers * amplify_property * length( vel_rho.xy )) / color_layers;
            fs_color = vec4( colorRamp( vel_mag ), 1 );

            //fs_color = amplify_property * vel_rho;
            //float  t = amplify_property * length( vel_rho.xy );
            //fs_color = vec4( 0, 0, triangle( 0.2, 0.3, 0.4, t ) + triangle( 0.7, 0.8, 0.9, t ), 1 );
            //fs_color = vec4( 0, 0, hermite( 0.2, 0.3, 0.4, t ) + hermite( 0.7, 0.8, 0.9, t ), 1 );
            //fs_color = vec4( 0, 0, smoothbox( 0.3, 0.4, 0.02, t ) + box( 0.8, 0.9, 0.02, t ), 1 );
        } break;

        case DISPLAY_VELOCITY_GRADIENT : {
            float vel_mag;
            if( color_layers == 0 )
                vel_mag = amplify_property * length( vel_rho.xy );
            else
                vel_mag = floor( color_layers * amplify_property * length( vel_rho.xy )) / color_layers;                                                    
            fs_color = vec4( 0.5 + dFdx( vel_mag ), 0.5 + dFdy( vel_mag ), 0, 1 );
        } break;

        case DISPLAY_VELOCITY_CURL :
            float curl;
            if( color_layers == 0 ) {
                vel_rho *= amplify_property;
                curl = dFdx( vel_rho.y ) - dFdy( vel_rho.x );  // compute 2D curl
            } else {
                vel_rho *= color_layers * amplify_property;
                curl = trunc( dFdx( vel_rho.y ) - dFdy( vel_rho.x )) / color_layers;  // compute 2D curl
            }   
            fs_color = vec4( max( 0, curl ), max( 0, -curl ), 0, 1 );
    }
}