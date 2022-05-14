#version 450

// push constants
layout( push_constant ) uniform Push_Constant {
    vec4    point_rgba;     // Add and ...
    float   point_size;     // ... use with ...
    float   speed_scale;    // ... Display_UBO
    int     ping_pong;

} pc;


// specialization constants for init or loop phase
layout( constant_id = 0 ) const uint TYPE = 0;
#define VELOCITY        0
#define DEBUG_DENSITY   1
#define DEBUG_POPUL     2


// uniform buffer
layout( std140, binding = 0 ) uniform uboViewer {
    mat4 WVPM;                                  // World View Projection Matrix
};


// populations 1 single buffered rest velocity, 8 double buffered link velocities
layout( binding = 2, r32f  ) uniform restrict readonly imageBuffer popul_buffer;


// sampler and image
layout( binding = 4 ) uniform sampler2DArray vel_rho_tex;      // VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE


// particle positions
layout( binding = 7, rgba32f  ) uniform restrict imageBuffer particle_buffer;


out gl_PerVertex {                              // not redifining gl_PerVertex used to create a layer validation error
    vec4    gl_Position;
    float   gl_PointSize;                       // not having clip and cull distance features enabled
};                                              // error seems to have vanished by now, but it does no harm to keep this redefinition

layout( location = 0 ) out  vec4 vs_color;     // output to fragment shader



#define VI gl_VertexIndex
#define D textureSize( vel_rho_tex, 0 )
#define X (  VI % D.x )
#define Y (( VI / D.x ) % D.y  )
#define Z (  VI / ( D.x * D.y ))
#define II gl_InstanceIndex


void main() {

    if( TYPE == VELOCITY ) {
        vec4 pos_a = imageLoad( particle_buffer, VI );
    //  vec3 pos = vec3( pos_a.x, pos_a.y, pos_a.z ); // must flip Y
        vec3 pos = vec3( pos_a.x, D.y - pos_a.y, pos_a.z ); // must flip Y

        /*
        // Eulerian integration
        vec3 vel = texture( vel_rho_tex, pos / D ).xyz;

        /*/

        // Runge-Kutta 4 integration

        // Unnormalized Coordinates
        // vec3 v_1 = texture( vel_rho_tex, pos ).xyz;
        // vec3 v_2 = texture( vel_rho_tex, pos + 0.5 * v_1 ).xyz;
        // vec3 v_3 = texture( vel_rho_tex, pos + 0.5 * v_2 ).xyz;
        // vec3 v_4 = texture( vel_rho_tex, pos + v_3 ).xyz;
        // vec3 vel = ( 2 * v_1 + v_2 + v_3 + 2 * v_4 ) / 6;   // Todo: Add Factor to UI

        // Normalized Coordinates
        // Todo(pp): add 1/D to Display_UBO and use as factor, same bellow
        vec3 v_1 = texture( vel_rho_tex, pos / D ).xyz;
        vec3 v_2 = texture( vel_rho_tex, ( pos + 0.5 * v_1 ) / D ).xyz;
        vec3 v_3 = texture( vel_rho_tex, ( pos + 0.5 * v_2 ) / D ).xyz;
        vec3 v_4 = texture( vel_rho_tex, ( pos + v_3 ) / D ).xyz;
        vec3 vel = ( 2 * v_1 + v_2 + v_3 + 2 * v_4 ) / 6;   // Todo: Add Factor to UI

        // Cool Jitter FX
        // vec3 uvw = pos / D;
        //vec3 v_1 = texture( vel_rho_tex, uvw ).xyz;
        //vec3 v_2 = texture( vel_rho_tex, uvw + 0.5 / D * v_1 ).xyz;
        //vec3 v_3 = texture( vel_rho_tex, uvw + 0.5 / D * v_2 ).xyz;
        //vec3 v_4 = texture( vel_rho_tex, uvw + v_3 ).xyz;
        //*/

        pos_a.xyz += vel;
        pos_a.a = min( pos_a.a + 0.01, 1 ); // particles leaving boundary are faded into their bound origin
        gl_PointSize = pos_a.a * ( pc.point_size + pc.speed_scale * length( vel ));

        bvec3 smaler = lessThanEqual( pos_a.xyz, vec3( 0 ) );
        bvec3 bigger = lessThanEqual( vec3( D ), pos_a.xyz );

        if( any( smaler ) || any( bigger ))
            pos_a = vec4( 0.5 ) + vec4( X, Y, Z, - 0.5 );

        imageStore( particle_buffer, VI, pos_a );

        vec4 rgba = pc.point_rgba;
        vs_color  = vec4( rgba.rgb, rgba.a * pos_a.a );
        gl_Position = WVPM * vec4( pos_a.x, D.y - pos_a.y, pos_a.z, 1 );
    }

    else if ( TYPE == DEBUG_DENSITY ) {
        gl_PointSize = abs( pc.point_size );
        vec3 pos = 0.5 + vec3( X, Y, Z );                               // 0.5 can result in rounding errors, such that if e.g Z = 2, layer 1 and 2 would glow, but if Z = 1 no layer would emit (on NVidia 780)
        float a  = texelFetch( vel_rho_tex, ivec3( X, Y, Z ), 0 ).a;    // in such a case it is better to use texelFetch with the direct integer coords
        //float a  = texture( vel_rho_tex, pos - vec3( 0, 0, 0.1) ).a;  // or use texture function with a slightly lower Z value to achieve relyable rounding
        vs_color = vec4( pc.point_rgba.rgb, a );
        gl_Position = WVPM * vec4( pos, 1 );
    }

    else if( TYPE == DEBUG_POPUL ) {
        int cell_count = int( D.x * D.y * D.z );
        //int popul_idx = VI % cell_count;
        const float P = pc.speed_scale;
        const vec3[] popul_offset = {
            vec3(0),
            vec3(P,0,0), vec3(-P,0,0), vec3(0,P,0), vec3(0,-P,0), vec3(0,0,P), vec3(0,0,-P),
            vec3(P), vec3(-P), vec3(P,P,-P), vec3(-P,-P,P), vec3(P,-P,P), vec3(-P,P,-P), vec3(-P,P,P), vec3(P,-P,-P) };

        gl_PointSize = abs( pc.point_size ) * ( 1 - length( popul_offset[ II ] ));
        vec3 pos = vec3( 0.5 ) + vec3( X, Y, Z ) + popul_offset[ II ];
        //float a  = 1;
        int PP_II = II == 0 ? 0 : II + pc.ping_pong * 14;
        float a  = 50 * imageLoad( popul_buffer, VI + PP_II * cell_count ).r;
        vs_color = vec4( pc.point_rgba.rgb, a );
        gl_Position = WVPM * vec4( pos, 1 );
    }
}