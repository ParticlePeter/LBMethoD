#version 450

// rastered vertex attributes
layout( location = 0 ) in   vec2 vs_tex_coord;  // input from vertex shader
layout( location = 0 ) out  vec4 fs_color;      // output from fragment shader


// uniform buffer
layout( std140, binding = 6 ) uniform Display_UBO {
    float   amplify_property;
    uint    color_layers;
    uint    z_layer;
};


// image and sampler
layout( binding = 4 ) uniform sampler2DArray vel_rho_tex[2];      // VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE


// specialization constant for display property
#define DENSITY     0
#define VEL_X       1
#define VEL_Y       2
#define VEL_MAG     3
#define VEL_GRAD    4
#define VEL_CURL    5
layout( constant_id = 0 ) const uint PROPERTY = VEL_MAG;


// ramp values
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


// ramp value interpolator
vec3 colorRamp( float t ) {
    t *= ( ramp.length() - 1 );
    ivec2 i = ivec2( floor( min( vec2( t, t + 1 ), vec2( ramp.length() - 1 ))));
    float f = fract( t );
    return mix( ramp[ i.x ], ramp[ i.y], f );
}


void main() {

    // get velocity and density data
    vec4 vel_rho = texture( vel_rho_tex[0], vec3( vs_tex_coord, z_layer ));  // access velocity density layer texture

    // switch based on display mode
    switch( PROPERTY ) {

        case DENSITY : {
            float vel_mag;
            if( color_layers == 0 )
                vel_mag = amplify_property * vel_rho.a;
            else
                vel_mag = floor( color_layers * amplify_property * vel_rho.a ) / color_layers;
            fs_color = vec4( colorRamp( vel_mag ), 1 );
        } break;

        case VEL_X :
            if( color_layers == 0 ) vel_rho *= amplify_property;
            else vel_rho = round( vel_rho * color_layers * amplify_property ) / color_layers;
            fs_color = vec4( max( 0, vel_rho.x ), max( 0, - vel_rho.x ), 0, 1 );
        break;

        case VEL_Y :
            if( color_layers == 0 ) vel_rho *= amplify_property;
            else vel_rho = round( vel_rho * color_layers * amplify_property ) / color_layers;
            fs_color = vec4( max( 0, vel_rho.y ), max( 0, - vel_rho.y ), 0, 1 );
        break;

        case VEL_MAG : {
            float vel_mag;
            if( color_layers == 0 )
                vel_mag = amplify_property * length( vel_rho.xy );
            else
                vel_mag = floor( color_layers * amplify_property * length( vel_rho.xy )) / color_layers;
            fs_color = vec4( colorRamp( vel_mag ), 1 );
        } break;

        case VEL_GRAD : {
            float vel_mag;
            if( color_layers == 0 )
                vel_mag = amplify_property * length( vel_rho.xy );
            else
                vel_mag = floor( color_layers * amplify_property * length( vel_rho.xy )) / color_layers;
            fs_color = vec4( 0.5 + dFdx( vel_mag ), 0.5 + dFdy( vel_mag ), 0, 1 );
        } break;

        case VEL_CURL : {
            float curl;
            if( color_layers == 0 ) {
                vel_rho *= amplify_property;
                curl = dFdx( vel_rho.y ) - dFdy( vel_rho.x );  // compute 2D curl
            } else {
                vel_rho *= color_layers * amplify_property;
                curl = round( dFdx( vel_rho.y ) - dFdy( vel_rho.x )) / color_layers;  // compute 2D curl
            }
            fs_color = vec4( max( 0, curl ), max( 0, -curl ), 0, 1 );
        } break;
    }
}