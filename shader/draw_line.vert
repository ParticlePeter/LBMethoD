#version 450

// push constants
layout( push_constant ) uniform Push_Constant {
    vec3 display_scale;
    uint lines_axis;
    vec3 lines_norm;
} pc;


// uniform buffer
layout( std140, binding = 0 ) uniform uboViewer {
    mat4 WVPM;                                  // World View Projection Matrix
};


// uniform buffer
layout( std140, binding = 6 ) uniform Display_UBO {
    uint    display_property;
    float   amplify_property;
    uint    color_layers;
    uint    z_layer;
};

// specialization constants for init or loop phase
#define DISPLAY_VELOCITY    0
#define DISPLAY_AXIS        1
layout( constant_id = 0 ) const uint DISPLAY_TYPE = DISPLAY_VELOCITY;



// sampler and image
layout( binding = 4 ) uniform sampler2DArray vel_rho_tex;      // VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE


// out per vertex redefinition
out gl_PerVertex {                              // not redifining gl_PerVertex used to create a layer validation error
    vec4 gl_Position;                           // not having clip and cull distance features enabled
};                                              // error seems to have vanished by now, but it does no harm to keep this redefinition


layout( location = 0 ) out vec3 vs_color;


// vertex index
#define VI gl_VertexIndex
#define II gl_InstanceIndex

#define DI imageSize( vel_rho_img )

#define DS pc.display_scale
#define LN pc.lines_norm

//#define LA pc.lines_axis
uint  LA = ( pc.lines_axis ) & 3;
uvec3 IC = uvec3(
    ( pc.lines_axis >>  8 ) & 255,
    ( pc.lines_axis >> 16 ) & 255,
    ( pc.lines_axis >> 24 ) & 255
);



// transformation based on image dimension and display scale
//const vec2 xform = 2 * pc.scale / vec2( imageSize( vel_rho_tex[0] )) - pc.scale;
const vec2 dir = vec2( 1, -1 );
void main() {

    if( DISPLAY_TYPE == DISPLAY_VELOCITY ) {
        vec2 offset = ( vec2( 2 * II + 2 ) - vec2( IC + 1 )) / vec2( IC + 1 );
        offset[ 1 - LA ] = 2 * VI * LN[ 1 - LA ] - 1; //DS[ 1 - LA ] - DS[ 1 - LA ];

        vec2 tex_coord = 0.5 * offset + 0.5;
        vec4 vel_rho = texture( vel_rho_tex, vec3( tex_coord, z_layer )); // access velocity density texture, result

        offset *= DS.xy;
        offset[ LA ] += dir[ LA ] * vel_rho[ LA ] * DS[ LA ];

        /*
        vec4 pos  = vec4( 0, 0, 0, 1 );
        pos[ LA ] = 2 * tex_coord[ LA ] * pc.display_scale[ LA ] - pc.display_scale[ LA ];  // add positional axis offset
        pos[ 1 - LA ] = dir[ LA ] * vel_rho[ 1 - LA ] + tex_coord[ 1 - LA ];
        */

        vs_color = vec3( 1, 1, 0 );
        vec4 pos = vec4( offset, 0, 1 );
        gl_Position = WVPM * pos;
    }

    else if( DISPLAY_TYPE == DISPLAY_AXIS ) {
        const vec3[3] colors = { vec3( 1, 0, 0 ), vec3( 0, 1, 0 ), vec3( 0, 0, 1 ) };
        vs_color = colors[ II ];
        vec4 pos = vec4( VI * vs_color, 1 );
        gl_Position = WVPM * pos;
    }

    else { // if( DISPLAY_TYPE == DISPLAY_GRID ) {

    }
}