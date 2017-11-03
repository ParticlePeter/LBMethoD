#version 450

// push constants
layout( push_constant ) uniform Push_Constant {
    uvec3 sim_domaine;
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
    vec4	gl_Position;
    float	gl_PointSize;                       // not having clip and cull distance features enabled
};                                              // error seems to have vanished by now, but it does no harm to keep this redefinition

layout( location = 0 ) out  float vs_alpha;     // output to fragment shader



#define I gl_VertexIndex
#define D pc.sim_domaine
#define X (  I % D.x )
#define Y (( I / D.x ) % D.y  )
#define Z (  I / ( D.x * D.y ))


void main() {
	
	vec4 pos_a = imageLoad( particle_buffer, I );
	pos_a.xyz += texture( vel_rho_tex, vec3( pos_a.x, D.y - pos_a.y, pos_a.z )).xyz;
	pos_a.a = min( pos_a.a + 0.01, 1 );

	bvec3 smaler = lessThanEqual( pos_a.xyz, vec3( 0 ) );
	bvec3 bigger = lessThanEqual( vec3( D ), pos_a.xyz );

	if( any( smaler ) || any( bigger ))
		pos_a = vec4( 0.5 ) + vec4( X, Y, Z, - 0.5 );

    imageStore( particle_buffer, I, pos_a );

    vs_alpha = pos_a.a;
    gl_PointSize = 2 * pos_a.a;
    gl_Position  = WVPM * vec4( pos_a.x, D.y - pos_a.y, pos_a.z, 1 );
}