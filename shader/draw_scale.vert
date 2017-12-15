#version 450

// push constants
layout( push_constant ) uniform Push_Constant {
    vec2 scale;
} pc;

// per vertex data
out gl_PerVertex {                              // not redifining gl_PerVertex used to create a layer validation error
    vec4 gl_Position;                           // not having clip and cull distance features enabled
};                                              // error seems to have vanished by now, but it does no harm to keep this redefinition

// raster attributes
layout( location = 0 ) out vec2 vs_tex_coord;   // vertex shader output vertex color, will be interpolated and rasterized

// vertex index
#define VI gl_VertexIndex


void main() {
	vs_tex_coord = vec2( VI >> 1, VI & 1 );
    vec2 pos = - pc.scale * ( vec2( - 30, 160 ) * vs_tex_coord.xy + vec2( 40, 10 ) - 1 / pc.scale );
    gl_Position = vec4( pos, 0.1, 1 );
}