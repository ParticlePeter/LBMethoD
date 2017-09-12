#version 450

// push constants
layout( push_constant ) uniform Push_Constant {
    uvec3   sim_domain;
    uint    line_type___line_axis___repl_axis___velocity_axis;
    int     repl_count;
    float   line_offset;
    float   repl_spread;
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


// sampler and image
layout( binding = 4 ) uniform sampler2DArray vel_rho_tex;      // VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE


// out per vertex redefinition
out gl_PerVertex {                              // not redifining gl_PerVertex used to create a layer validation error
    vec4 gl_Position;                           // not having clip and cull distance features enabled
};                                              // error seems to have vanished by now, but it does no harm to keep this redefinition


layout( location = 0 ) out vec4 vs_color;


// specialization constants for init or loop phase
#define DISPLAY_VELOCITY    0
#define DISPLAY_AXIS        1
#define DISPLAY_GRID        2
//layout( constant_id = 0 ) const uint DISPLAY_TYPE = DISPLAY_VELOCITY;
uint DISPLAY_TYPE = pc.line_type___line_axis___repl_axis___velocity_axis & 0xff;
uint LA = ( pc.line_type___line_axis___repl_axis___velocity_axis >>  8 ) & 0xff;
uint RA = ( pc.line_type___line_axis___repl_axis___velocity_axis >> 16 ) & 0xff;
uint VA = ( pc.line_type___line_axis___repl_axis___velocity_axis >> 24 ) & 0xff;





// vertex index
#define VI gl_VertexIndex
#define II gl_InstanceIndex

#define DI imageSize( vel_rho_img )

#define SD pc.sim_domain
#define LN pc.lines_norm






// transformation based on image dimension and display scale
//const vec2 xform = 2 * pc.scale / vec2( imageSize( vel_rho_tex[0] )) - pc.scale;
const vec2 dir = vec2( 1, -1 );
void main() {

    vec4 pos = vec4( 0, 0, 0, 1 );

    switch( DISPLAY_TYPE ) {
    case DISPLAY_VELOCITY :
        vs_color = vec4( 1, 1, 0, 1 );
        pos[ LA ] += 0.5 + VI;
        pos[ RA ] += 0.5 + II * pc.repl_spread + pc.line_offset;
        pos[ VA ] += texture( vel_rho_tex, pos.xyz )[ VA ] * pc.sim_domain[ VA ] * vec3( 1, -1, 1 )[ VA ];  // latter param is fixing 
        break;


    case DISPLAY_AXIS :
        const vec4[3] colors = { vec4( 1, 0, 0, 1 ), vec4( 0, 1, 0, 1 ), vec4( 0, 0, 1, 1 ) };
        vs_color = colors[ II ];
        pos = vec4( VI * vs_color.rgb, 1 );
        break;


    case DISPLAY_GRID :
        vs_color = vec4( 0.25 );
        //vs_color = vec3( 1, 0, 0 );
        pos[ LA ] = float( II );
        pos[ 1 - LA ] = float( VI * SD[ 1 - LA ] );
        break;
    }

    gl_Position = WVPM * pos;
}