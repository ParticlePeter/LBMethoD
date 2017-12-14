import appstate;
import erupted;

import std.parallelism;
import exportstate;

import appstate : setSimFuncPlay, setDefaultSimFuncs;
import dlsl.vector;



//////////////////////
// cpu state struct //
//////////////////////
struct VDrive_Cpu_State {
    // Directions:              R       E       N       W       S       NE      NW      SW      SE
    immutable float[9] pw = [   4.0/9,  1.0/9,  1.0/9,  1.0/9,  1.0/9,  1.0/36, 1.0/36, 1.0/36, 1.0/36 ];

    size_t  cell_count = 0;
    float*  popul_buffer_f;
    double* popul_buffer_d;
    ubyte   ping;
    size_t  current_buffer_mem_size;
    float*  sim_image_ptr;              // pointer to mapped image to be displayd
    float*  sim_export_ptr;

}



// initialize data required for simulation
void cpuInit( ref VDrive_State vd ) {
    vd.vc.ping = 8;

    if( vd.use_double ) {
        if( vd.vc.popul_buffer_d is null || vd.vc.sim_image_ptr is null )
            vd.cpuReset;

        for( int I = 0; I < vd.vc.cell_count; ++I ) {
            vd.vc.sim_image_ptr[ 2 * I + 0 ] = 0;
            vd.vc.sim_image_ptr[ 2 * I + 1 ] = 0;
            for( int p = 0; p < 9; ++p )  {
                float w = vd.vc.pw[ p ];
                vd.vc.popul_buffer_d[ p * vd.vc.cell_count + I ] = w;
            }
        }
    } else {
        if( vd.vc.popul_buffer_f is null || vd.vc.sim_image_ptr is null )
            vd.cpuReset;

        for( int I = 0; I < vd.vc.cell_count; ++I ) {
            // init display image velocity
            vd.vc.sim_image_ptr[ 2 * I + 0 ] = 0;
            vd.vc.sim_image_ptr[ 2 * I + 1 ] = 0;
            // init all distribution f(unctions) with equilibrium, p = population
            for( int p = 0; p < 9; ++p )  {
                float w = vd.vc.pw[ p ];
                vd.vc.popul_buffer_f[ p * vd.vc.cell_count + I ] = w;
                //if( p > 0 ) popul_buffer[ ( p + 8 ) * vd.vc.cell_count + I ] = vd.vc.pw[ p ];
            }// buffer offsets coresponding streaming ( in 2D so far )
        }
    }

    //vd.device.vkFlushMappedMemoryRanges( 1, &sim_image_flush );
    import vdrive.memory;
    vd.sim_image.flushMappedMemoryRange;

    //vd.sim_index = 0;
    vd.ve.store_index = -1;

}


// reset simulation data, also allocates and frees if required and
// sets up play function pointer for either float or double prcision
void cpuReset( ref VDrive_State vd ) {

    assert( !( vd.vc.popul_buffer_f !is null && vd.vc.popul_buffer_d !is null ));

    auto old_cell_count = vd.vc.cell_count;
    vd.vc.cell_count = vd.sim_domain[0] * vd.sim_domain[1] * vd.sim_domain[2];
    size_t buffer_size = vd.vc.cell_count * vd.sim_layers;
    size_t old_buffer_mem_size = vd.vc.current_buffer_mem_size;
    vd.vc.current_buffer_mem_size = buffer_size * ( vd.use_double ? double.sizeof : float.sizeof );
    if( vd.vc.current_buffer_mem_size < old_buffer_mem_size )
        vd.vc.current_buffer_mem_size = old_buffer_mem_size;


    bool must_init;
    import core.stdc.stdlib : malloc, free;
    if( vd.use_double ) {
        setSimFuncPlay( & cpuSimD_Play );
        if( vd.vc.popul_buffer_f !is null ) {
            if( old_buffer_mem_size < vd.vc.current_buffer_mem_size ) { // 2 * float.sizeof = double.sizeof
                free( cast( void* )vd.vc.popul_buffer_f );
                vd.vc.popul_buffer_f = null;
                vd.vc.cell_count = vd.vc.current_buffer_mem_size = 0;
                vd.cpuReset;
            } else {
                vd.vc.popul_buffer_d = cast( double* )vd.vc.popul_buffer_f;
                vd.vc.popul_buffer_f = null;
                must_init = true;
            }
        } else if( old_buffer_mem_size < vd.vc.current_buffer_mem_size ) {
            if( vd.vc.popul_buffer_d !is null )
                free( cast( void* )vd.vc.popul_buffer_d );
            vd.vc.popul_buffer_d = cast( double* )malloc( vd.vc.current_buffer_mem_size );
        }

    } else {    // vd.use_double = false;
        setSimFuncPlay( & cpuSimF_Play );
        if( vd.vc.popul_buffer_d !is null ) {
            if( old_cell_count * 2 < vd.vc.cell_count ) { // 2 * float.sizeof = double.sizeof
                free( cast( void* )vd.vc.popul_buffer_d );
                vd.vc.popul_buffer_d = null;
                vd.vc.cell_count = vd.vc.current_buffer_mem_size = 0;
                vd.cpuReset;
            } else {
                vd.vc.popul_buffer_f = cast( float* )vd.vc.popul_buffer_d;
                vd.vc.popul_buffer_d = null;
                must_init = true;
            }
        } else if( old_cell_count < vd.vc.cell_count ) {
            if( vd.vc.popul_buffer_f !is null )
                free( cast( void* )vd.vc.popul_buffer_f );
            vd.vc.popul_buffer_f = cast( float* )malloc( vd.vc.current_buffer_mem_size );
        }
    }

    if( must_init )
        vd.cpuInit;

}


// free cpu simulation resources
void cpuFree( ref VDrive_State vd ) {
    import core.stdc.stdlib : free;
    free( cast( void* )vd.vc.popul_buffer_f ); vd.vc.popul_buffer_f = null;
    free( cast( void* )vd.vc.popul_buffer_d ); vd.vc.popul_buffer_d = null;

    vd.vc.cell_count = 0;

}


// setup cpu play and profile function pointer
void setCpuSimFuncs( ref VDrive_State vd ) nothrow @system {
    if( vd.use_double ) {
        setSimFuncPlay( & cpuSimD_Play );
        setSimFuncProfile( & cpuSimD_Profile );
    } else {
        setSimFuncPlay( & cpuSimF_Play );
        setSimFuncProfile( & cpuSimF_Profile );
    }
}


// these aliases are shortcuts to templated function cpuSim
// they are used as function pointers called in module appstate
alias cpuSimF_Play      = cpuSim!( float  );
alias cpuSimD_Play      = cpuSim!( double );
alias cpuSimF_Profile   = cpuSim!( float,  true );
alias cpuSimD_Profile   = cpuSim!( double, true );


// multi-threaded template function implementing one cpu sim step
void cpuSim( T, bool PROFILE = false )( ref VDrive_State vd ) nothrow @system {

    float    omega = vd.compute_ubo.collision_frequency;
    float    wall_velocity = vd.compute_ubo.wall_velocity;
    int      D_x = vd.sim_domain[0];
    int      D_y = vd.sim_domain[1];

    static if( is( T == double )) {
        assert( vd.vc.popul_buffer_d !is null );
        T* popul_buffer = vd.vc.popul_buffer_d;
    } else {
        assert( vd.vc.popul_buffer_f !is null );
        T* popul_buffer = vd.vc.popul_buffer_f;
    }


    ubyte pong = vd.vc.ping;
    vd.vc.ping = cast( ubyte )( 8 - vd.vc.ping );


    try {
        static if( PROFILE ) vd.startStopWatch;
        import std.range : iota;
        foreach( I; parallel( iota( 0, vd.vc.cell_count, 1 ), vd.sim_work_group_size[0] )) {

            // load populations
            T[9] f = [
                popul_buffer[                             I ],
                popul_buffer[ ( vd.vc.ping + 1 ) * vd.vc.cell_count + I ],
                popul_buffer[ ( vd.vc.ping + 2 ) * vd.vc.cell_count + I ],
                popul_buffer[ ( vd.vc.ping + 3 ) * vd.vc.cell_count + I ],
                popul_buffer[ ( vd.vc.ping + 4 ) * vd.vc.cell_count + I ],
                popul_buffer[ ( vd.vc.ping + 5 ) * vd.vc.cell_count + I ],
                popul_buffer[ ( vd.vc.ping + 6 ) * vd.vc.cell_count + I ],
                popul_buffer[ ( vd.vc.ping + 7 ) * vd.vc.cell_count + I ],
                popul_buffer[ ( vd.vc.ping + 8 ) * vd.vc.cell_count + I ],
            ];

            // compute macroscopic density before applying wall velocity where required
            T rho = f[0] + f[1] + f[2] + f[3] + f[4] + f[5] + f[6] + f[7] + f[8];

            // compute 2D coordinates X and Y;
            size_t X = I % D_x;
            size_t Y = I / D_x;

            // Ladd's momentum correction for moving walls, applied to reflected populations not perpendicular to wall velocity
            if( Y == D_y - 1 /*|| Y == 0*/ ) {  // Handle top wall speed - 2 * w_i * rho * dot( c_i, u_w ) / c_s ^ 2
                f[7] -= 2 * vd.vc.pw[7] * rho * wall_velocity;
                f[8] += 2 * vd.vc.pw[8] * rho * wall_velocity;
            }

            // compute macroscopic velocity after wall velocity is applied
            T v_x = ( f[1] - f[3] + f[5] - f[7] + f[8] - f[6] ) / rho;
            T v_y = ( f[2] - f[4] + f[5] - f[7] + f[6] - f[8] ) / rho;

            // store velocities and densities in stage buffer to copy to image with format VK_FORMAT_R32G32B32A32_SFLOAT
            vd.vc.sim_image_ptr[ 4 * I + 0 ] = cast( float )v_x;
            vd.vc.sim_image_ptr[ 4 * I + 1 ] = cast( float )v_y;
            vd.vc.sim_image_ptr[ 4 * I + 2 ] = 0;
            vd.vc.sim_image_ptr[ 4 * I + 3 ] = 1;

            T[9] f_eq = [
                vd.vc.pw[0] * rho * (1                                                        - 1.5 * (v_x * v_x + v_y * v_y)), // vd.vc.pw[0] * rho * ( 1                     - V_D_V ), //
                vd.vc.pw[1] * rho * (1 + 3 * ( v_x)       + 4.5 * ( v_x)       * ( v_x)       - 1.5 * (v_x * v_x + v_y * v_y)), // vd.vc.pw[1] * rho * ( 1 + 3 *  v_x  + V_X_2 - V_D_V ), //
                vd.vc.pw[2] * rho * (1 + 3 * ( v_y)       + 4.5 * ( v_y)       * ( v_y)       - 1.5 * (v_x * v_x + v_y * v_y)), // vd.vc.pw[2] * rho * ( 1 + 3 *  v_y  + V_Y_2 - V_D_V ), //
                vd.vc.pw[3] * rho * (1 + 3 * (-v_x)       + 4.5 * (-v_x)       * (-v_x)       - 1.5 * (v_x * v_x + v_y * v_y)), // vd.vc.pw[3] * rho * ( 1 - 3 *  v_x  + V_X_2 - V_D_V ), //
                vd.vc.pw[4] * rho * (1 + 3 * (-v_y)       + 4.5 * (-v_y)       * (-v_y)       - 1.5 * (v_x * v_x + v_y * v_y)), // vd.vc.pw[4] * rho * ( 1 - 3 *  v_y  + V_Y_2 - V_D_V ), //
                vd.vc.pw[5] * rho * (1 + 3 * ( v_x + v_y) + 4.5 * ( v_x + v_y) * ( v_x + v_y) - 1.5 * (v_x * v_x + v_y * v_y)), // vd.vc.pw[5] * rho * ( 1 + 3 * X_P_Y + XPY_2 - V_D_V ), //
                vd.vc.pw[6] * rho * (1 + 3 * (-v_x + v_y) + 4.5 * (-v_x + v_y) * (-v_x + v_y) - 1.5 * (v_x * v_x + v_y * v_y)), // vd.vc.pw[6] * rho * ( 1 - 3 * X_M_Y + XMY_2 - V_D_V ), //
                vd.vc.pw[7] * rho * (1 + 3 * (-v_x - v_y) + 4.5 * (-v_x - v_y) * (-v_x - v_y) - 1.5 * (v_x * v_x + v_y * v_y)), // vd.vc.pw[7] * rho * ( 1 - 3 * X_P_Y + XPY_2 - V_D_V ), //
                vd.vc.pw[8] * rho * (1 + 3 * ( v_x - v_y) + 4.5 * ( v_x - v_y) * ( v_x - v_y) - 1.5 * (v_x * v_x + v_y * v_y)), // vd.vc.pw[8] * rho * ( 1 + 3 * X_M_Y + XMY_2 - V_D_V )  //
            ];

            // Collide - inlining is not working properly, hence manually
            f[0] = f[0] * ( 1 - omega ) + f_eq[0] * omega; // mix( f[0], f_eq[0], omega );
            f[1] = f[1] * ( 1 - omega ) + f_eq[1] * omega; // mix( f[1], f_eq[1], omega );
            f[2] = f[2] * ( 1 - omega ) + f_eq[2] * omega; // mix( f[2], f_eq[2], omega );
            f[3] = f[3] * ( 1 - omega ) + f_eq[3] * omega; // mix( f[3], f_eq[3], omega );
            f[4] = f[4] * ( 1 - omega ) + f_eq[4] * omega; // mix( f[4], f_eq[4], omega );
            f[5] = f[5] * ( 1 - omega ) + f_eq[5] * omega; // mix( f[5], f_eq[5], omega );
            f[6] = f[6] * ( 1 - omega ) + f_eq[6] * omega; // mix( f[6], f_eq[6], omega );
            f[7] = f[7] * ( 1 - omega ) + f_eq[7] * omega; // mix( f[7], f_eq[7], omega );
            f[8] = f[8] * ( 1 - omega ) + f_eq[8] * omega; // mix( f[8], f_eq[8], omega );

            // Store new populations
            popul_buffer[ I ] = f[0];

            //immutable int[9] inv = [ 0, 3, 4, 1, 2, 7, 8, 5, 6 ];                                buf_off              buf_off         buffer_offset
            popul_buffer[ X == D_x - 1 ? ( pong + 3 ) * vd.vc.cell_count + I : ( pong + 1 ) * vd.vc.cell_count +   1 + I ] = f[1];
            popul_buffer[ Y ==       0 ? ( pong + 4 ) * vd.vc.cell_count + I : ( pong + 2 ) * vd.vc.cell_count - D_x + I ] = f[2];
            popul_buffer[ X ==       0 ? ( pong + 1 ) * vd.vc.cell_count + I : ( pong + 3 ) * vd.vc.cell_count -   1 + I ] = f[3];
            popul_buffer[ Y == D_y - 1 ? ( pong + 2 ) * vd.vc.cell_count + I : ( pong + 4 ) * vd.vc.cell_count + D_x + I ] = f[4];

            popul_buffer[ ( X == D_x - 1 || Y ==       0 ) ? ( pong + 7 ) * vd.vc.cell_count + I : ( pong + 5 ) * vd.vc.cell_count - D_x + 1 + I ] = f[5];
            popul_buffer[ ( Y ==       0 || X ==       0 ) ? ( pong + 8 ) * vd.vc.cell_count + I : ( pong + 6 ) * vd.vc.cell_count - D_x - 1 + I ] = f[6];
            popul_buffer[ ( X ==       0 || Y == D_y - 1 ) ? ( pong + 5 ) * vd.vc.cell_count + I : ( pong + 7 ) * vd.vc.cell_count + D_x - 1 + I ] = f[7];
            popul_buffer[ ( Y == D_y - 1 || X == D_x - 1 ) ? ( pong + 6 ) * vd.vc.cell_count + I : ( pong + 8 ) * vd.vc.cell_count + D_x + 1 + I ] = f[8];

        }
        static if( PROFILE ) vd.stopStopWatch;
    } catch( Exception ) {}



    import vdrive.memory;
    vd.sim_stage_buffer.flushMappedMemoryRange;

    // increment indexes
    ++vd.sim_index;
    ++vd.compute_ubo.comp_index;

    // display the result
    vd.drawSim;

}
