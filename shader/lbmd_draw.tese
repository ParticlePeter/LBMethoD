#version 450 core

layout( quads, fractional_odd_spacing ) in; // equal_spacing, fractional_odd_spacing, fractional_even_spacing

// uniform buffer
layout( std140, binding = 0 ) uniform uboViewer {
    mat4 WVPM;                                  // World View Projection Matrix
};

layout( binding = 4 ) uniform sampler2D vel_rho_tex[2];      // VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE

// uniform buffer
layout( std140, binding = 6 ) uniform Display_UBO {
    uint    display_property;
    float   amplify_property;
    float   tess_level_inner;
    float   tess_level_outer;
    float   tess_height_amp;
    float   tess_dead_zone;
};


layout( set = 0, binding = 0 ) uniform sampler2D texDisplacement;

layout( location = 0 ) out vec2 vs_texcoord;

float deadZoneOrig( float t, float dz ) {
    return min(( t / ( 1.0 - dz )), 0.5 ) + max((( t - dz ) / ( 1.0 - dz )), 0.5 ) - 0.5;
}

float deadZone( float v, float t ) {
    float result = v * ( 1 - t );
    if( t > 0.5 ) result += t;
    return result;
}

// only fractional_odd_spacing does not produce central line segments, hence it is preferred here
// otherwise we would have different line segment count between right-left and top-bottom
vec2 deadZone( vec2 v, float t ) {
    return mix( v, step( vec2( 0.5 ), v ), t );
}

void main() {
    vs_texcoord = deadZone( gl_TessCoord.st, tess_dead_zone );
    vec4 m_1 = mix( gl_in[0].gl_Position, gl_in[1].gl_Position, vs_texcoord.x ); //deadZone( gl_TessCoord.x, tess_dead_zone ));
    vec4 m_2 = mix( gl_in[2].gl_Position, gl_in[3].gl_Position, vs_texcoord.x ); //deadZone( gl_TessCoord.x, tess_dead_zone ));
    vec4 pos = mix( m_1, m_2, vs_texcoord.y ); //deadZone( gl_TessCoord.y, tess_dead_zone ));
    vec4 vel_rho = texture( vel_rho_tex[0], vs_texcoord.st );
    pos.z = - length( vel_rho.xy ) * tess_height_amp;
    gl_Position = WVPM * pos;
}