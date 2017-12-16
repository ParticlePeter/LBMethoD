#version 450

// uniform buffer
layout( std140, binding = 0 ) uniform uboViewer {
    mat4 WVPM;                                  // World View Projection Matrix
};


layout( location = 0 ) out vec4 vs_color;




// vertex index
#define VI gl_VertexIndex
#define II gl_InstanceIndex



// transformation based on image dimension and display scale
//const vec2 xform = 2 * pc.scale / vec2( imageSize( vel_rho_tex[0] )) - pc.scale;
const vec2 dir = vec2( 1, -1 );
void main() {
    const vec4[3] colors = { vec4( 1, 0, 0, 1 ), vec4( 0, 1, 0, 1 ), vec4( 0, 0, 1, 1 ) };
    vs_color = colors[ II ];
    gl_Position = WVPM * vec4( 10 * VI * vs_color.rgb, 1 );
}