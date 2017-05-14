#version 450

// push constants
layout( push_constant ) uniform Push_Constant {
    vec2 scale;
} pc;


// uniform buffer(s)
layout( std140, binding = 0 ) uniform uboViewer {
    mat4 WVPM;                                  // World View Projection Matrix
};

//layout( location = 0 ) in  vec4 ia_position;    // input assembly/attributes, we passed in two vec3
//in int gl_VertexIndex;

layout( location = 0 ) out vec2 vs_texcoord;  	// vertex shader output vertex color, will be interpolated and rasterized

out gl_PerVertex {                              // not redifining gl_PerVertex used to create a layer validation error
    vec4 gl_Position;                           // not having clip and cull distance features enabled
};                                              // error seems to have vanished by now, but it does no harm to keep this redefinition

#define VI gl_VertexIndex

void main() {
    vs_texcoord = vec2( VI >> 1, VI & 1 );
    gl_Position = WVPM * vec4( pc.scale * ( 2 * vs_texcoord - 1 ), 0, 1 );
}