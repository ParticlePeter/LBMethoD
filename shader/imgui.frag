#version 450

layout( set = 0, binding = 1 ) uniform sampler2D font_tex;

layout( location = 0 ) in struct {
    vec4 color;
    vec2 texcoord;
} fs_in;

layout( location = 0 ) out vec4 fs_color;


void main() {
    fs_color = fs_in.color * texture( font_tex, fs_in.texcoord );
}
