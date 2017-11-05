#version 450

// push constants
layout( push_constant ) uniform Push_Constant {
    vec4    point_rgba;
    float   point_size;
    float   speed_scale;
} pc;


// uniform buffer
layout( std140, binding = 0 ) uniform uboViewer {
    mat4 WVPM;                                  // World View Projection Matrix
};


// sampler and image
layout( binding = 4 ) uniform sampler2DArray vel_rho_tex;      // VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE


// particle positions
layout( binding = 7, rgba32f  ) uniform restrict imageBuffer particle_buffer;


out gl_PerVertex {                              // not redifining gl_PerVertex used to create a layer validation error
    vec4    gl_Position;
    float   gl_PointSize;                       // not having clip and cull distance features enabled
};                                              // error seems to have vanished by now, but it does no harm to keep this redefinition

layout( location = 0 ) out  vec4 vs_color;     // output to fragment shader



#define I gl_VertexIndex
#define D textureSize( vel_rho_tex, 0 )
#define X (  I % D.x )
#define Y (( I / D.x ) % D.y  )
#define Z (  I / ( D.x * D.y ))


void main() {
    
    vec4 pos_a = imageLoad( particle_buffer, I );
    vec3 pos = vec3( pos_a.x, D.y - pos_a.y, pos_a.z ); // must flip Y

    /*
    // Eulerian integration
    vec3 vel = texture( vel_rho_tex, pos ).xyz;

    /*/

    // Runge-Kutta 4 integration
    vec3 v_1 = texture( vel_rho_tex, pos ).xyz;
    vec3 v_2 = texture( vel_rho_tex, pos + 0.5 * v_1 ).xyz;
    vec3 v_3 = texture( vel_rho_tex, pos + 0.5 * v_2 ).xyz;
    vec3 v_4 = texture( vel_rho_tex, pos + v_3 ).xyz;
    vec3 vel = ( 2 * v_1 + v_2 + v_3 + 2 * v_4 ) / 6;
    //*/

    pos_a.xyz += vel;
    pos_a.a = min( pos_a.a + 0.01, 1 );
    gl_PointSize = pos_a.a * ( pc.point_size + pc.speed_scale * length( vel ));

    bvec3 smaler = lessThanEqual( pos_a.xyz, vec3( 0 ) );
    bvec3 bigger = lessThanEqual( vec3( D ), pos_a.xyz );

    if( any( smaler ) || any( bigger ))
        pos_a = vec4( 0.5 ) + vec4( X, Y, Z, - 0.5 );

    imageStore( particle_buffer, I, pos_a );

    vec4 rgba = pc.point_rgba;
    vs_color  = vec4( rgba.rgb, rgba.a * pos_a.a );
    gl_Position  = WVPM * vec4( pos_a.x, D.y - pos_a.y, pos_a.z, 1 );
}