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

    switch( PROPERTY ) {

        case DENSITY :
        case VEL_MAG :
            if( color_layers == 0 ) {
                fs_color = vec4( colorRamp( vs_tex_coord.y ), 1 );
            } else {
                float ty = floor( color_layers * vs_tex_coord.y ) / color_layers;
                fs_color = vec4( colorRamp( ty ), 1 );
            }
        break;

        case VEL_X :
        case VEL_Y :
        case VEL_CURL :
            if( color_layers == 0 ) {
                fs_color = vec4( max( 0, 2 * vs_tex_coord.y - 1 ), max( 0, 1 - 2 * vs_tex_coord.y ), 0, 1 );
            } else {
                float ty = round( color_layers * vs_tex_coord.y ) / color_layers;
                fs_color = vec4( max( 0, 2 * ty - 1 ), max( 0, 1 - 2 * ty ), 0, 1 );
            }
        break;

        case VEL_GRAD : {
            discard;
            fs_color = vec4( 0 );
        } break;
    }
}
