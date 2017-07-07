#version 450

layout( vertices = 4 ) out;

// uniform buffer
layout( std140, binding = 6 ) uniform Display_UBO {
    uint    display_property;
    float   amplify_property;
    float   tess_level_inner;
    float   tess_level_outer;
};

//in gl_PerVertex {         // this is not working, gl_in must be of known size, but which
//    vec4 gl_Position;     // when this shader is compiled with -H we see that all default gl_PerVertex from Vertex Shader are accepted, seems not to be a problem though
//} gl_in[];


out gl_PerVertex {          // if not redifining gl_PerVertex SPIR-V module not valid: Operand 4 of MemberDecorate requires one of these capabilities: MultiViewport
    vec4 gl_Position;       // Operand 4 is gl_ViewportIndex which is not required, hence we simply redefine gl_out[]
} gl_out[];


void main() {
    if( gl_InvocationID == 0 ) {
        gl_TessLevelInner[0] = tess_level_inner;
        gl_TessLevelInner[1] = tess_level_inner;

        gl_TessLevelOuter[0] = tess_level_outer;
        gl_TessLevelOuter[1] = tess_level_outer;
        gl_TessLevelOuter[2] = tess_level_outer;
        gl_TessLevelOuter[3] = tess_level_outer;
    }
    
    gl_out[ gl_InvocationID ].gl_Position = gl_in[ gl_InvocationID ].gl_Position;
}