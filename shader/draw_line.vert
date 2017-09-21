#version 450

// push constants
layout( push_constant ) uniform Push_Constant {
    uvec3   sim_domain;
    uint    line_type___line_axis___repl_axis___velocity_axis;
    int     repl_count;
    float   line_offset;
    float   repl_spread;
    float   point_size;
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
    vec4    gl_Position;                        // not having clip and cull distance features enabled
    float   gl_PointSize;
};                                              // error seems to have vanished by now, but it does no harm to keep this redefinition


layout( location = 0 ) out vec4 vs_color;


// specialization constants for init or loop phase
#define DISPLAY_VELOCITY    0
#define DISPLAY_VEL_BASE    1
#define DISPLAY_AXIS        2
#define DISPLAY_GRID        3
#define DISPLAY_BOUNDS      4
#define DISPLAY_GHIA        5


const float[2][17] ghia_idx = {
    { 127, 123, 122, 121, 120, 115, 109,  102,  63,  29,  28,  19,  11,   9,   8,   7,  -1 },
    { 127, 124, 123, 122, 121, 108,  93,   78,  63,  57,  29,  21,  12,   8,   7,   6,  -1 },
};

const float[2][7][17] ghia_uv = {
    {
        { 1,  0.84123,  0.78871,  0.73722,  0.68717,  0.23151,  0.00332, -0.13641, -0.20581, -0.21090, -0.15662, -0.10150, -0.06434, -0.04775, -0.04192, -0.03717, 0 },
        { 1,  0.75837,  0.68439,  0.61756,  0.55892,  0.29093,  0.16256,  0.02135, -0.11477, -0.17119, -0.32726, -0.24299, -0.14612, -0.10338, -0.09266, -0.08186, 0 },
        { 1,  0.65928,  0.57492,  0.51117,  0.46604,  0.33304,  0.18719,  0.05702, -0.06080, -0.10648, -0.27805, -0.38289, -0.29730, -0.22220, -0.20196, -0.18109, 0 },
        { 1,  0.53236,  0.48296,  0.46547,  0.46101,  0.34682,  0.19791,  0.07156, -0.04272, -0.86636, -0.24427, -0.34323, -0.41933, -0.37827, -0.35344, -0.32407, 0 },
        { 1,  0.48223,  0.46120,  0.45992,  0.46036,  0.33556,  0.20087,  0.08183, -0.03039, -0.07404, -0.22855, -0.33050, -0.40435, -0.43643, -0.42901, -0.41165, 0 },
        { 1,  0.47244,  0.47048,  0.47323,  0.47167,  0.34228,  0.20591,  0.08342, -0.03800, -0.07503, -0.23176, -0.32393, -0.38324, -0.43025, -0.43590, -0.43154, 0 },
        { 1,  0.47221,  0.47783,  0.48070,  0.47804,  0.34635,  0.20673,  0.08344,  0.03111, -0.07540, -0.23186, -0.32709, -0.38000, -0.41657, -0.42537, -0.42735, 0 },
    },

    {
        
        { 0, -0.05906, -0.07391, -0.08864, -0.10313, -0.16914, -0.22445, -0.24533,  0.05454,  0.17527,  0.17507,  0.16077,  0.12317,  0.10890,  0.10091,  0.09233, 0 },
        { 0, -0.12146, -0.15663, -0.19254, -0.22847, -0.23827, -0.44993, -0.38598,  0.05188,  0.30174,  0.30203,  0.28124,  0.22965,  0.20920,  0.19713,  0.18360, 0 },
        { 0, -0.21388, -0.27669, -0.33714, -0.39188, -0.51550, -0.42665, -0.31966,  0.02526,  0.32235,  0.33075,  0.37095,  0.32627,  0.30353,  0.29012,  0.27485, 0 },
        { 0, -0.39017, -0.47425, -0.52357, -0.54053, -0.44307, -0.37401, -0.31184,  0.00999,  0.28188,  0.29030,  0.37119,  0.42768,  0.41906,  0.40917,  0.39560, 0 },
        { 0, -0.49774, -0.55069, -0.55408, -0.52876, -0.41442, -0.36214, -0.30018,  0.00945,  0.27280,  0.28066,  0.35368,  0.42951,  0.43648,  0.43329,  0.42447, 0 },
        { 0, -0.53858, -0.55216, -0.52347, -0.48590, -0.41050, -0.36213, -0.30448,  0.00824,  0.27348,  0.28117,  0.35060,  0.41824,  0.43564,  0.44030,  0.43979, 0 },
        { 0, -0.54302, -0.52987, -0.49099, -0.45863, -0.41496, -0.36737, -0.30719,  0.00831,  0.27224,  0.28003,  0.35070,  0.41487,  0.43124,  0.43733,  0.43983, 0 },
    }
};

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







// transformation based on image dimension and display scale
//const vec2 xform = 2 * pc.scale / vec2( imageSize( vel_rho_tex[0] )) - pc.scale;
const vec2 dir = vec2( 1, -1 );
void main() {
    gl_PointSize = pc.point_size;
    vec4 pos = vec4( 0, 0, 0, 1 );

    switch( DISPLAY_TYPE ) {
    case DISPLAY_VELOCITY :
        vs_color = vec4( 1, 1, 0, 1 );
        pos[ LA ] += 0.5 + VI;
        pos[ RA ] += 0.5 + II * pc.repl_spread + pc.line_offset;
        pos[ VA ] += texture( vel_rho_tex, pos.xyz )[ VA ] * pc.sim_domain[ VA ] * vec3( 1, -1, 1 )[ VA ];  // latter param is fixing 
        break;


    case DISPLAY_VEL_BASE :
        vs_color = vec4( 0.375 );
        pos[ LA ] += 0.5 + VI;
        pos[ RA ] += 0.5 + II * pc.repl_spread + pc.line_offset;
        //pos[ VA ] += texture( vel_rho_tex, pos.xyz )[ VA ] * pc.sim_domain[ VA ] * vec3( 1, -1, 1 )[ VA ];  // latter param is fixing 
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


    case DISPLAY_GHIA :
        vs_color = vec4( 1, 0, 0, 1 );
        //pos.xy = LA == 1 ? vec2( ghia_uv[0][ pc.repl_count ][ VI ], ghia_idx[1][VI] ) : vec2( ghia_idx[ 0 ][ VI ], ghia_uv[0][ pc.repl_count ][ VI ] );
        pos[ LA ] = ghia_idx[ LA ][ VI ] + 0.5;
        pos[ 1 - LA ] = ghia_uv[ 1 - LA ][ pc.repl_count ][ VI ] * 12.6 + 63.5;
        break;
    }

    gl_Position = WVPM * pos;
}