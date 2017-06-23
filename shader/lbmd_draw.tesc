#version 450

layout( vertices = 4 ) out;


//in gl_PerVertex {                              // this is not working, gl_in must be of known size, but which
//    vec4 gl_Position;                          // when this shader is compiled with -H we see that all default gl_PerVertex from Vertex Shader are accepted, seems not to be a problem though
//} gl_in[];


out gl_PerVertex {                              // not redifining gl_PerVertex result: SPIR-V module not valid: Operand 4 of MemberDecorate requires one of these capabilities: MultiViewport
    vec4 gl_Position;                           // Operand 4 is gl_ViewportIndex which is not required, hence we simply redefine gl_out[]
} gl_out[];


void main() {
    if( gl_InvocationID == 0 ) {
        gl_TessLevelInner[0] = 64.0;
        gl_TessLevelInner[1] = 64.0;

        gl_TessLevelOuter[0] = 64.0;
        gl_TessLevelOuter[1] = 64.0;
        gl_TessLevelOuter[2] = 64.0;
        gl_TessLevelOuter[3] = 64.0;
    }
    
    gl_out[ gl_InvocationID ].gl_Position = gl_in[ gl_InvocationID ].gl_Position;
}