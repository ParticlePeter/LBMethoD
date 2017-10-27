#version 450

layout( location = 0 ) in   vec4 vs_color;
layout( location = 0 ) out  vec4 fs_color;      // output from fragment shader


// uniform buffer
layout( std140, binding = 6 ) uniform Display_UBO {
    uint    display_property;
    float   amplify_property;
    uint    color_layers;
    uint    z_layer;
};


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


void main() {
	//if( dot( vs_color.rgb, vs_color.rgb ) < 0.01 ) discard;
	//fs_color = vs_color;

    float vel_mag = amplify_property * length( vs_color.xy );
    fs_color = vec4( colorRamp( vel_mag ), 1 );
}