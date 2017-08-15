import gui;
import erupted;


import std.parallelism;
import data_grid;
import exportstate;

import gui : setSimFuncPlay, setSimFuncPause, setDefaultSimFuncs;
import dlsl.vector;



struct VDrive_Cpu_State {
    // Directions:              R       E       N       W       S       NE      NW      SW      SE
    immutable float[9] pw = [   4.0/9,  1.0/9,  1.0/9,  1.0/9,  1.0/9,  1.0/36, 1.0/36, 1.0/36, 1.0/36 ];

    size_t  cell_count = 0;
    float*  popul_buffer_f;
    double* popul_buffer_d;
    ubyte   ping;
    size_t  current_buffer_mem_size;
    float*  sim_image_ptr;              // cpu simulation resources

}




ref VDrive_Gui_State cpuInit( ref VDrive_Gui_State vg ) {
    vg.vc.ping = 8;

    if( vg.sim_use_double ) {
        if( vg.vc.popul_buffer_d is null || vg.sim_image_ptr is null )
            vg.cpuReset;

        for( int I = 0; I < vg.vc.cell_count; ++I ) {
            vg.sim_image_ptr[ 2 * I + 0 ] = 0;
            vg.sim_image_ptr[ 2 * I + 1 ] = 0;
            for( int p = 0; p < 9; ++p )  {
                float w = vg.vc.pw[ p ];
                vg.vc.popul_buffer_d[ p * vg.vc.cell_count + I ] = w;
            }
        }
    } else {
        if( vg.vc.popul_buffer_f is null || vg.sim_image_ptr is null )
            vg.cpuReset;

        for( int I = 0; I < vg.vc.cell_count; ++I ) {
            // init display image velocity
            vg.sim_image_ptr[ 2 * I + 0 ] = 0;
            vg.sim_image_ptr[ 2 * I + 1 ] = 0;
            // init all distribution f(unctions) with equilibrium, p = population
            for( int p = 0; p < 9; ++p )  {
                float w = vg.vc.pw[ p ];
                vg.vc.popul_buffer_f[ p * vg.vc.cell_count + I ] = w;
                //if( p > 0 ) popul_buffer[ ( p + 8 ) * vg.vc.cell_count + I ] = vg.vc.pw[ p ];
            }// buffer offsets coresponding streaming ( in 2D so far )
        }
    }

    //vg.device.vkFlushMappedMemoryRanges( 1, &sim_image_flush );
    import vdrive.memory;
    vg.sim_image.flushMappedMemoryRange;

    //vg.sim_index = 0;
    vg.ve.store_index = -1;

    return vg;
}



ref VDrive_Gui_State cpuReset( ref VDrive_Gui_State vg ) {

    assert( !( vg.vc.popul_buffer_f !is null && vg.vc.popul_buffer_d !is null ));

    auto old_cell_count = vg.vc.cell_count;
    vg.vc.cell_count = vg.sim_domain[0] * vg.sim_domain[1] * vg.sim_domain[2];
    size_t buffer_size = vg.vc.cell_count * vg.sim_layers;
    size_t old_buffer_mem_size = vg.vc.current_buffer_mem_size;
    vg.vc.current_buffer_mem_size = buffer_size * ( vg.sim_use_double ? double.sizeof : float.sizeof );
    if( vg.vc.current_buffer_mem_size < old_buffer_mem_size )
        vg.vc.current_buffer_mem_size = old_buffer_mem_size;


    bool must_init;
    import core.stdc.stdlib : malloc, free;
    if( vg.sim_use_double ) {
        if( vg.vc.popul_buffer_f !is null ) {
            if( old_buffer_mem_size < vg.vc.current_buffer_mem_size ) { // 2 * float.sizeof = double.sizeof
                free( cast( void* )vg.vc.popul_buffer_f );
                vg.vc.popul_buffer_f = null;
                vg.vc.cell_count = vg.vc.current_buffer_mem_size = 0;
                vg.cpuReset;
            } else {
                vg.vc.popul_buffer_d = cast( double* )vg.vc.popul_buffer_f;
                vg.vc.popul_buffer_f = null;
                must_init = true;
            }
        } else if( old_buffer_mem_size < vg.vc.current_buffer_mem_size ) {
            if( vg.vc.popul_buffer_d !is null )
                free( cast( void* )vg.vc.popul_buffer_d );
            vg.vc.popul_buffer_d = cast( double* )malloc( vg.vc.current_buffer_mem_size );
        }

    } else {    // vg.sim_use_double = false;
        vg.setSimFuncPlay( & cpuSimF_Play );
        if( vg.vc.popul_buffer_d !is null ) {
            if( old_cell_count * 2 < vg.vc.cell_count ) { // 2 * float.sizeof = double.sizeof
                free( cast( void* )vg.vc.popul_buffer_d );
                vg.vc.popul_buffer_d = null;
                vg.vc.cell_count = vg.vc.current_buffer_mem_size = 0;
                vg.cpuReset;
            } else {
                vg.vc.popul_buffer_f = cast( float* )vg.vc.popul_buffer_d;
                vg.vc.popul_buffer_d = null;
                must_init = true;
            }
        } else if( old_cell_count < vg.vc.cell_count ) {
            if( vg.vc.popul_buffer_f !is null )
                free( cast( void* )vg.vc.popul_buffer_f );
            vg.vc.popul_buffer_f = cast( float* )malloc( vg.vc.current_buffer_mem_size );
        }
    }

    if( must_init )
        vg.cpuInit;

    vg.ve.grid.minDomain = vec4( 0 );
    vg.ve.grid.maxDomain = vec4( 1 );
    vg.ve.grid.cellCount = uvec4( vg.sim_domain, 0 );

    return vg;
}



auto ref cpuFree( ref VDrive_Gui_State vg ) {
    import core.stdc.stdlib : free;
    free( cast( void* )vg.vc.popul_buffer_f ); vg.vc.popul_buffer_f = null;
    free( cast( void* )vg.vc.popul_buffer_d ); vg.vc.popul_buffer_d = null;

    vg.vc.cell_count = 0;

    return vg;
}


void setCpuSimFuncs( ref VDrive_Gui_State vg ) nothrow @system {
    if( vg.sim_use_double ) {
        vg.setSimFuncPlay( & cpuSimD_Play );
        vg.setSimFuncProfile( & cpuSimD_Profile );
    } else {
        vg.setSimFuncPlay( & cpuSimF_Play );
        vg.setSimFuncProfile( & cpuSimF_Profile );
    }

    vg.setSimFuncPause;                 // set default pause function
    vg.sim_play_cmd_buffer_count = 1;   // submit only the graphics display buffer
}


alias cpuSimF_Play      = cpuSim!( float,  false );
alias cpuSimD_Play      = cpuSim!( double, false );
alias cpuSimF_Export    = cpuSim!( float,  true );
alias cpuSimD_Export    = cpuSim!( double, true );
alias cpuSimF_Profile   = cpuSim!( float,  false, true );
alias cpuSimD_Profile   = cpuSim!( double, false, true );


void cpuSim( T, bool EXPORT, bool PROFILE = false )( ref VDrive_Gui_State vg ) nothrow @system {

    float    omega = vg.compute_ubo.collision_frequency;
    float    wall_velocity = vg.compute_ubo.wall_velocity;
    int      D_x = vg.sim_domain[0];
    int      D_y = vg.sim_domain[1];

    static if( is( T == double )) {
        assert( vg.vc.popul_buffer_d !is null );
        T* popul_buffer = vg.vc.popul_buffer_d;
    } else {
        assert( vg.vc.popul_buffer_f !is null );
        T* popul_buffer = vg.vc.popul_buffer_f;
    }

    static if( EXPORT ) {
        if( vg.ve.grid.cellCount.w < vg.ve.step_count ) {
            vg.ve.grid.cellCount.w = vg.ve.step_count;
            vg.ve.grid.create_domain_from_min_max;
        }

        bool store_data = false;
        if( vg.ve.start_index <= vg.sim_index && vg.ve.store_index < ( vg.ve.step_count - 1 ) && ( vg.sim_index - vg.ve.start_index - 1 ) % vg.ve.step_size == 0 ) {
            store_data = true;
            ++vg.ve.store_index;
            //import core.stdc.stdio : printf;
            //printf( "Sim Index: %d, Store Index: %d\n", vg.sim_index, vg.vc.store_index );
        }
    }

    ubyte pong = vg.vc.ping;
    vg.vc.ping = cast( ubyte )( 8 - vg.vc.ping );

    static if( PROFILE )
        vg.startStopWatch;

    //foreach( I, ref cell; parallel( popul_buffer[ 0 .. vg.vc.cell_count ], vg.sim_work_group_size[0] )) {
    for( int I = 0; I < vg.vc.cell_count; ++I ) {
        // load populations
        //import std.stdio;
        //writeln( vg.vc.cell_count );

        T[9] f = [
            popul_buffer[                             I ],
            popul_buffer[ ( vg.vc.ping + 1 ) * vg.vc.cell_count + I ],
            popul_buffer[ ( vg.vc.ping + 2 ) * vg.vc.cell_count + I ],
            popul_buffer[ ( vg.vc.ping + 3 ) * vg.vc.cell_count + I ],
            popul_buffer[ ( vg.vc.ping + 4 ) * vg.vc.cell_count + I ],
            popul_buffer[ ( vg.vc.ping + 5 ) * vg.vc.cell_count + I ],
            popul_buffer[ ( vg.vc.ping + 6 ) * vg.vc.cell_count + I ],
            popul_buffer[ ( vg.vc.ping + 7 ) * vg.vc.cell_count + I ],
            popul_buffer[ ( vg.vc.ping + 8 ) * vg.vc.cell_count + I ],
        ];

        T rho = f[0] + f[1] + f[2] + f[3] + f[4] + f[5] + f[6] + f[7] + f[8];
        T v_x = ( f[1] - f[3] + f[5] - f[7] + f[8] - f[6] ) / rho;
        T v_y = ( f[2] - f[4] + f[5] - f[7] + f[6] - f[8] ) / rho;

        // store velocities and densities in image
        vg.sim_image_ptr[ 2 * I + 0 ] = cast( float )v_x;
        vg.sim_image_ptr[ 2 * I + 1 ] = cast( float )v_y;

//        if( vg.vc.start_index <= vg.sim_index && vg.sim_index < vg.vc.start_index + vg.vc.step_count ) {
//            vg.vc.grid[ I + ( vg.sim_index - vg.vc.start_index ) * vg.vc.cell_count ] = vec3( v_x, v_y, 0 );
//        }

        static if( EXPORT ) {
            if( store_data ) {
                vg.ve.grid[ I + vg.ve.store_index * vg.vc.cell_count ] = vec3( v_x, v_y, 0 );
            }
        }

        T X_P_Y = v_x + v_y;
        T X_M_Y = v_x - v_y;
        T V_X_2 = 4.5 * v_x * v_x;
        T V_Y_2 = 4.5 * v_y * v_y;
        T XPY_2 = 4.5 * X_P_Y * X_P_Y;
        T XMY_2 = 4.5 * X_M_Y * X_M_Y;
        T V_D_V = 1.5 * ( v_x * v_x + v_y * v_y );

        T[9] f_eq = [                                    // #define SQ(x) ((x) * (x))
            vg.vc.pw[0] * rho * ( 1                     - V_D_V ), // vg.vc.pw[0] * rho * (1                                           - 1.5 * (SQ(v_x) + SQ(v_y))),
            vg.vc.pw[1] * rho * ( 1 + 3 *  v_x  + V_X_2 - V_D_V ), // vg.vc.pw[1] * rho * (1 + 3 * ( v_x)       + 4.5 * SQ( v_x)       - 1.5 * (SQ(v_x) + SQ(v_y))),
            vg.vc.pw[2] * rho * ( 1 + 3 *  v_y  + V_Y_2 - V_D_V ), // vg.vc.pw[2] * rho * (1 + 3 * ( v_y)       + 4.5 * SQ( v_y)       - 1.5 * (SQ(v_x) + SQ(v_y))),
            vg.vc.pw[3] * rho * ( 1 - 3 *  v_x  + V_X_2 - V_D_V ), // vg.vc.pw[3] * rho * (1 + 3 * (-v_x)       + 4.5 * SQ(-v_x)       - 1.5 * (SQ(v_x) + SQ(v_y))),
            vg.vc.pw[4] * rho * ( 1 - 3 *  v_y  + V_Y_2 - V_D_V ), // vg.vc.pw[4] * rho * (1 + 3 * (-v_y)       + 4.5 * SQ(-v_y)       - 1.5 * (SQ(v_x) + SQ(v_y))),
            vg.vc.pw[5] * rho * ( 1 + 3 * X_P_Y + XPY_2 - V_D_V ), // vg.vc.pw[5] * rho * (1 + 3 * ( v_x + v_y) + 4.5 * SQ( v_x + v_y) - 1.5 * (SQ(v_x) + SQ(v_y))),
            vg.vc.pw[6] * rho * ( 1 - 3 * X_M_Y + XMY_2 - V_D_V ), // vg.vc.pw[6] * rho * (1 + 3 * (-v_x + v_y) + 4.5 * SQ(-v_x + v_y) - 1.5 * (SQ(v_x) + SQ(v_y))),
            vg.vc.pw[7] * rho * ( 1 - 3 * X_P_Y + XPY_2 - V_D_V ), // vg.vc.pw[7] * rho * (1 + 3 * (-v_x - v_y) + 4.5 * SQ(-v_x - v_y) - 1.5 * (SQ(v_x) + SQ(v_y))),
            vg.vc.pw[8] * rho * ( 1 + 3 * X_M_Y + XMY_2 - V_D_V )  // vg.vc.pw[8] * rho * (1 + 3 * ( v_x - v_y) + 4.5 * SQ( v_x - v_y) - 1.5 * (SQ(v_x) + SQ(v_y)))
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

        // compute 2D coordinates X and Y;
        size_t X = I % D_x;
        size_t Y = I / D_x;

        // Handle top wall speed - 2 * w_i * rho * dot( c_i, u_w ) / c_s ^ 2
        if( Y == D_y - 1 /*|| Y == 0*/ ) {
            f[1] += 2 * vg.vc.pw[1] * rho * wall_velocity;
            f[3] -= 2 * vg.vc.pw[3] * rho * wall_velocity;
            f[5] += 2 * vg.vc.pw[5] * rho * wall_velocity;
            f[6] -= 2 * vg.vc.pw[6] * rho * wall_velocity;
            f[7] -= 2 * vg.vc.pw[7] * rho * wall_velocity;
            f[8] += 2 * vg.vc.pw[8] * rho * wall_velocity;
        }

        // Store new populations
        popul_buffer[ I ] = f[0];

        //immutable int[9] inv = [ 0, 3, 4, 1, 2, 7, 8, 5, 6 ];                                buf_off              buf_off         buffer_offset
        popul_buffer[ X == D_x - 1 ? ( pong + 3 ) * vg.vc.cell_count + I : ( pong + 1 ) * vg.vc.cell_count +   1 + I ] = f[1];
        popul_buffer[ Y ==       0 ? ( pong + 4 ) * vg.vc.cell_count + I : ( pong + 2 ) * vg.vc.cell_count - D_x + I ] = f[2];
        popul_buffer[ X ==       0 ? ( pong + 1 ) * vg.vc.cell_count + I : ( pong + 3 ) * vg.vc.cell_count -   1 + I ] = f[3];
        popul_buffer[ Y == D_y - 1 ? ( pong + 2 ) * vg.vc.cell_count + I : ( pong + 4 ) * vg.vc.cell_count + D_x + I ] = f[4];

        //writefln( "I: %s, X: %s, Y: %s, D_x: %s, D_y: %s, vg.vc.ping: %s, pong: %s, vg.vc.cell_count: %s, B: %s, S: %s, P: %s", I, X, Y, D_x, D_y, vg.vc.ping, pong, vg.vc.cell_count,
        //    ( pong + 7 ) * vg.vc.cell_count + I, ( pong + 5 ) * vg.vc.cell_count - D_x + 1 + I, popul_buffer.length );
        popul_buffer[ ( X == D_x - 1 || Y ==       0 ) ? ( pong + 7 ) * vg.vc.cell_count + I : ( pong + 5 ) * vg.vc.cell_count - D_x + 1 + I ] = f[5];
        popul_buffer[ ( Y ==       0 || X ==       0 ) ? ( pong + 8 ) * vg.vc.cell_count + I : ( pong + 6 ) * vg.vc.cell_count - D_x - 1 + I ] = f[6];
        popul_buffer[ ( X ==       0 || Y == D_y - 1 ) ? ( pong + 5 ) * vg.vc.cell_count + I : ( pong + 7 ) * vg.vc.cell_count + D_x - 1 + I ] = f[7];
        popul_buffer[ ( Y == D_y - 1 || X == D_x - 1 ) ? ( pong + 6 ) * vg.vc.cell_count + I : ( pong + 8 ) * vg.vc.cell_count + D_x + 1 + I ] = f[8];

    }

    static if( PROFILE )
        vg.stopStopWatch;

    static if( EXPORT ) {
        if( vg.ve.grid.cellCount.w - 1 <= vg.ve.store_index ) {
            vg.cpuExport;
        }
    }

    import vdrive.memory;
    //vg.sim_image.flushMappedMemoryRange;
    vg.sim_stage_buffer.flushMappedMemoryRange;

    // sim index is now controled through the draw_step function like this one
    ++vg.sim_index;

    import appstate;
    vg.vd.draw;                                // let vulkan dance

}


auto ref cpuExport( ref VDrive_Gui_State vg ) @system nothrow {

    import std.string : fromStringz;
    import std.conv : to;
    import ensight;

    Export_Options options;
    options.output      = vg.ve.case_file_name.ptr.fromStringz.to!string;
    options.variable    = vg.ve.variable_name;
    options.format      = vg.ve.file_format;
    options.overwrite   = true;
    options.set_default_options;

//    import std.stdio;
//    auto cc = vg.vc.grid.cellCount;
//    auto num_cells = cc.x * cc.y * cc.z * cc.w;
//    foreach( i; 0 .. num_cells )
//        writeln( vg.vc.grid[ i ] );

    // assign non export function
    //if( vg.sim_use_double ) setSimFuncPlay( & cpuSimD_Play );
    //else                    setSimFuncPlay( & cpuSimF_Play );

    // stop simulation
    vg.setDefaultSimFuncs;

    vg.ve.grid.ensStore( options );
}


