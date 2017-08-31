#version 450

// push constants
layout( push_constant ) uniform Push_Constant {
    uvec2 scale;
} pc;


// uniform buffer
layout( std140, binding = 0 ) uniform uboViewer {
    mat4 WVPM;                                  // World View Projection Matrix
};


out gl_PerVertex {                              // not redifining gl_PerVertex used to create a layer validation error
    vec4 gl_Position;                           // not having clip and cull distance features enabled
};                                              // error seems to have vanished by now, but it does no harm to keep this redefinition


layout( location = 0 ) out vec2 vs_tex_coord;   // vertex shader output vertex color, will be interpolated and rasterized

#define VI gl_VertexIndex

void main() {
    vs_tex_coord = pc.scale * vec2( VI >> 1, VI & 1 );
    gl_Position = WVPM * vec4( vs_tex_coord, 0.1, 1 );
}