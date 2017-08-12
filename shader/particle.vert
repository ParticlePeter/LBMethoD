#version 450

// uniform buffer
layout( std140, binding = 0 ) uniform uboViewer {
    mat4 WVPM;                                  // World View Projection Matrix
};

layout( location = 0 ) in vec4 ia_position;

out gl_PerVertex {                              // not redifining gl_PerVertex used to create a layer validation error
    vec4	gl_Position;
    float	gl_PointSize;                       // not having clip and cull distance features enabled
};                                              // error seems to have vanished by now, but it does no harm to keep this redefinition



void main() {
	gl_PointSize = 5;
    gl_Position = WVPM * ( ia_position + vec4( 0, 0, -0.01, 0 ));
}