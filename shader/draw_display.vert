#version 450

// push constants
layout( push_constant ) uniform Push_Constant {
    vec2 scale[2];
} pc;


// uniform buffer
layout( std140, binding = 0 ) uniform uboViewer {
    mat4 WVPM;                                  // World View Projection Matrix
};


out gl_PerVertex {                              // not redifining gl_PerVertex used to create a layer validation error
    vec4 gl_Position;                           // not having clip and cull distance features enabled
};                                              // error seems to have vanished by now, but it does no harm to keep this redefinition


layout( location = 0 ) out vec3 vs_tex_coord;   // veprtex shader output vertex color, will be interpolated and rasterized


#define VI gl_VertexIndex
#define II gl_InstanceIndex

void main() {

    vs_tex_coord = vec3( VI >> 1, VI & 1, II );

    if( II == 0 ) {
        vs_tex_coord.xy *= pc.scale[ II ];
        gl_Position = WVPM * vec4( vs_tex_coord.xy, 0.1, 1 );
    } else {
        //vec4( pc.scale * ( vec2( 20, 100 ) * vs_tex_coord + vec2( 10, 200 )), 0, 1 );
        vec2 pos = - pc.scale[ II ] * ( vec2( - 30, 160 ) * vs_tex_coord.xy + vec2( 40, 10 ) - 1 / pc.scale[ II ] );
        gl_Position = vec4( pos, 0.1, 1 );
    }
}