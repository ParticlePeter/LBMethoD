#version 450

// Todo(pp): split into seperate draw_scale shader and draw_taylor_green shader 
// latter could be selectable in Display Parameter

layout( location = 0 ) in   vec2 vs_tex_coord;  // input from vertex shader
layout( location = 0 ) out  vec4 fs_color;      // output from fragment shader

layout( binding = 4 ) uniform sampler2DArray vel_rho_tex[2];      // VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE

// uniform buffer
layout( std140, binding = 5 ) uniform Compute_UBO {
    float   omega;            // collision frequency
    float   wall_velocity;
    int     wall_thickness;
    int     comp_index;
};

// uniform buffer
layout( std140, binding = 6 ) uniform Display_UBO {
    uint    display_property;
    float   amplify_property;
    uint    color_layers;
    uint    z_layer;
};

#define DISPLAY_DENSITY 0
#define DISPLAY_VELOCITY_X 1
#define DISPLAY_VELOCITY_Y 2
#define DISPLAY_VELOCITY_MAGNITUDE 3
#define DISPLAY_VELOCITY_GRADIENT 4
#define DISPLAY_VELOCITY_CURL 5
//#define DISPLAY_TAYLOR_GREEN 6



// R: 0 0 0 0 1 1
// G: 0 0 1 1 1 0
// B: 0 1 1 0 0 0

const vec3[] ramp = {
    vec3( 0, 0, 0 ),
    vec3( 0, 0, 1 ),
    vec3( 0, 1, 1 ),
    vec3( 0, 1, 0 ),
    vec3( 1, 1, 0 ),
    vec3( 1, 0, 0 )
};



vec3 colorRamp( float t ) {
    t *= ( ramp.length() - 1 );
    ivec2 i = ivec2( floor( min( vec2( t, t + 1 ), vec2( ramp.length() - 1 ))));
    float f = fract( t );
    return mix( ramp[ i.x ], ramp[ i.y], f );
}


#define PI 3.1415926535897932384626433832795
#define u_max wall_velocity
#define t comp_index
#define rho0 1
#define D textureSize( vel_rho_tex[0], 0 )


void main() {

    vec2 tex_coord = vs_tex_coord.xy;

    // get velocity and density data
    vec4 vel_rho = texture( vel_rho_tex[0], vec3( tex_coord, z_layer ));  // access velocity density layer texture

    float nu  = 1.0 / ( 6.0 * omega );  // float nu = vg.sim_speed_of_sound * vg.sim_speed_of_sound * ( vg.sim_relaxation_rate / vg.sim_unit_temporal - 0.5 );
    float kx  = 2.0 * PI / D.x;
    float ky  = 2.0 * PI / D.y;
    float td  = nu * ( kx * kx + ky * ky ); // 1.0 / ( nu * ( kx * kx + ky * ky ));    // this is twice divided, why ???
    float xx  = tex_coord.x; // X + 0.5;
    float yy  = tex_coord.y; // Y + 0.5;
    float ux  = - u_max * sqrt( ky / kx ) * cos( kx * xx ) * sin( ky * yy ) * exp( -1.0 * t * td ); // / td );
    float uy  =   u_max * sqrt( kx / ky ) * sin( kx * xx ) * cos( ky * yy ) * exp( -1.0 * t * td ); // / td );
    float pp  = - 0.25  * rho0 * u_max * u_max
              * (( ky / kx ) * cos( 2.0 * kx * xx ) + ( kx / ky ) * cos( 2.0 * ky * yy ))
              * exp( - 2.0 * t * td ); // / td );
    float rho = rho0 + 3.0 * pp;

    //vel_rho = vec4( ux, uy, 0, 1 );
    //vel_rho = abs( vec4( ux, uy, 0, 1 ) - vel_rho );

    switch( display_property ) {
        case DISPLAY_DENSITY : {
            //fs_color = vec4( colorRamp( amplify_property * vel_rho.a ), 1 );
            float vel_mag;
            if( color_layers == 0 )
                vel_mag = amplify_property * vel_rho.a;
            else
                vel_mag = floor( color_layers * amplify_property * vel_rho.a ) / color_layers;
            fs_color = vec4( colorRamp( vel_mag ), 1 );
        } break;

        case DISPLAY_VELOCITY_X :
            if( color_layers == 0 ) vel_rho *= amplify_property;
            else vel_rho = trunc( vel_rho * color_layers * amplify_property ) / color_layers;
            fs_color = vec4( max( 0, vel_rho.x ), max( 0, - vel_rho.x ), 0, 1 );
        break;

        case DISPLAY_VELOCITY_Y :
            if( color_layers == 0 ) vel_rho *= amplify_property;
            else vel_rho = trunc( vel_rho * color_layers * amplify_property ) / color_layers;
            fs_color = vec4( max( 0, vel_rho.y ), max( 0, - vel_rho.y ), 0, 1 );
        break;

        case DISPLAY_VELOCITY_MAGNITUDE : {
            float vel_mag;
            if( color_layers == 0 )
                vel_mag = amplify_property * length( vel_rho.xy );
            else
                vel_mag = floor( color_layers * amplify_property * length( vel_rho.xy )) / color_layers;
            fs_color = vec4( colorRamp( vel_mag ), 1 );

            //fs_color = amplify_property * vel_rho;
            //float  t = amplify_property * length( vel_rho.xy );
            //fs_color = vec4( 0, 0, triangle( 0.2, 0.3, 0.4, t ) + triangle( 0.7, 0.8, 0.9, t ), 1 );
            //fs_color = vec4( 0, 0, hermite( 0.2, 0.3, 0.4, t ) + hermite( 0.7, 0.8, 0.9, t ), 1 );
            //fs_color = vec4( 0, 0, smoothbox( 0.3, 0.4, 0.02, t ) + box( 0.8, 0.9, 0.02, t ), 1 );
        } break;

        case DISPLAY_VELOCITY_GRADIENT : {
            float vel_mag;
            if( color_layers == 0 )
                vel_mag = amplify_property * length( vel_rho.xy );
            else
                vel_mag = floor( color_layers * amplify_property * length( vel_rho.xy )) / color_layers;
            fs_color = vec4( 0.5 + dFdx( vel_mag ), 0.5 + dFdy( vel_mag ), 0, 1 );
        } break;

        case DISPLAY_VELOCITY_CURL : {
            float curl;
            if( color_layers == 0 ) {
                vel_rho *= amplify_property;
                curl = dFdx( vel_rho.y ) - dFdy( vel_rho.x );  // compute 2D curl
            } else {
                vel_rho *= color_layers * amplify_property;
                curl = trunc( dFdx( vel_rho.y ) - dFdy( vel_rho.x )) / color_layers;  // compute 2D curl
            }
            fs_color = vec4( max( 0, curl ), max( 0, -curl ), 0, 1 );
        } break;
    }
}