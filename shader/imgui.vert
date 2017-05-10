#version 450

layout( location = 0 ) in vec2 ia_position;
layout( location = 1 ) in vec2 ia_texcoord;
layout( location = 2 ) in vec4 ia_color;

layout( push_constant ) uniform Push_Constant {
    vec2 scale;
    vec2 translate;
} pc;


out gl_PerVertex{
    vec4 gl_Position;
};


layout( location = 0 ) out struct {
    vec4 color;
    vec2 texcoord;
} vs_out;


void main() {
    vs_out.color = ia_color;
    vs_out.texcoord = ia_texcoord;
    gl_Position = vec4( ia_position * pc.scale + pc.translate, 0, 1 );
}
