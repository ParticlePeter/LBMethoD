#version 450 core

layout( quads, fractional_odd_spacing ) in;

// uniform buffer
layout( std140, binding = 0 ) uniform uboViewer {
    mat4 WVPM;                                  // World View Projection Matrix
};

layout( binding = 4 ) uniform sampler2D vel_rho_tex[2];      // VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE

// uniform buffer
layout( std140, binding = 6 ) uniform Display_UBO {
    uint    display_property;
    float   amplify_property;
};


layout( set = 0, binding = 0 ) uniform sampler2D texDisplacement;

layout( location = 0 ) out vec2 vs_texcoord;    // vertex shader output vertex color, will be interpolated and rasterized


void main() {
    vs_texcoord = gl_TessCoord.st;
    vec4 vel_rho = texture( vel_rho_tex[0], gl_TessCoord.xy );
    vec4 m_1 = mix( gl_in[0].gl_Position, gl_in[1].gl_Position, gl_TessCoord.x );
    vec4 m_2 = mix( gl_in[2].gl_Position, gl_in[3].gl_Position, gl_TessCoord.x );
    vec4 pos = mix( m_1, m_2, gl_TessCoord.y );
    //float displacement = texture( texDisplacement, gl_TessCoord.xy ).x;
    pos.z = - length( vel_rho.xy );
    gl_Position = WVPM * pos;
}