
import appstate;
import erupted;

import std.parallelism;
import exportstate;

import appstate : setSimFuncPlay, setDefaultSimFuncs;
import dlsl.vector;

import vdrive.buffer;
private alias Sim_Stage_Buffer = Core_Buffer_T!( 0, BMC.Memory | BMC.Mem_Range );


//nothrow @nogc:


///////////////////////////////////
// cpu state and resource struct //
///////////////////////////////////
struct VDrive_Cpu_State {
    // Directions:              R       E       N       W       S       NE      NW      SW      SE
    immutable float[9] pw = [   4.0/9,  1.0/9,  1.0/9,  1.0/9,  1.0/9,  1.0/36, 1.0/36, 1.0/36, 1.0/36 ];

    size_t      cell_count = 0;
    float*      popul_buffer_f;
    double*     popul_buffer_d;
    ubyte       ping;
    size_t      current_buffer_mem_size;
    float*      sim_image_ptr;          // pointer to mapped image to be displayd
    float*      sim_export_ptr;

    Sim_Stage_Buffer        sim_stage_buffer;
    VkExtent3D              sim_macro_image_extent;
    VkImageSubresourceRange sim_macro_image_subresourceRange;
}


// create and map macro image staging buffer
void createCpuMacroImageStaggingBuffer(
    ref VDrive_State                    app,
    const ref VkExtent3D                extent,
    const ref VkImageSubresourceRange   subresource_range

    ) {

    // staging buffer for cpu computed velocity copy to the sim_image
    if(!app.cpu.sim_stage_buffer.is_null ) {
        app.graphics_queue.vkQueueWaitIdle;
        app.destroy( app.cpu.sim_stage_buffer );    // destroy old image and its view, keeping the sampler
    }

    uint32_t buffer_size = 4 * app.sim.domain[0] * app.sim.domain[1];   // only in 2D and with VK_FORMAT_R32G32B32A32_SFLOAT
    VkDeviceSize buffer_mem_size = buffer_size * cast( uint32_t )( float.sizeof );

    app.cpu.sim_stage_buffer = Meta_Buffer_T!Sim_Stage_Buffer( app )
        .usage( VK_BUFFER_USAGE_TRANSFER_SRC_BIT )
        .bufferSize( buffer_mem_size )
        .construct( VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT )
        .mapMemory( app.cpu.sim_image_ptr )
        .reset;

    app.cpu.sim_macro_image_extent = extent;
    app.cpu.sim_macro_image_subresourceRange = subresource_range;
}


// initialize data required for simulation
void cpuInit( ref VDrive_State app ) {
    app.cpu.ping = 8;

    if( app.sim.use_double ) {
        if( app.cpu.popul_buffer_d is null || app.cpu.sim_image_ptr is null )
            app.cpuReset;

        for( int I = 0; I < app.cpu.cell_count; ++I ) {
            app.cpu.sim_image_ptr[ 2 * I + 0 ] = 0;
            app.cpu.sim_image_ptr[ 2 * I + 1 ] = 0;
            for( int p = 0; p < 9; ++p )  {
                float w = app.cpu.pw[ p ];
                app.cpu.popul_buffer_d[ p * app.cpu.cell_count + I ] = w;
            }
        }
    } else {
        if( app.cpu.popul_buffer_f is null || app.cpu.sim_image_ptr is null )
            app.cpuReset;

        for( int I = 0; I < app.cpu.cell_count; ++I ) {
            // init display image velocity
            app.cpu.sim_image_ptr[ 2 * I + 0 ] = 0;
            app.cpu.sim_image_ptr[ 2 * I + 1 ] = 0;
            // init all distribution f(unctions) with equilibrium, p = population
            for( int p = 0; p < 9; ++p )  {
                float w = app.cpu.pw[ p ];
                app.cpu.popul_buffer_f[ p * app.cpu.cell_count + I ] = w;
                //if( p > 0 ) popul_buffer[ ( p + 8 ) * app.cpu.cell_count + I ] = app.cpu.pw[ p ];
            }// buffer offsets coresponding streaming ( in 2D so far )
        }
    }

    app.exp.store_index = -1;
}


// reset simulation data, also allocates and frees if required and
// sets up play function pointer for either float or double prcision
void cpuReset( ref VDrive_State app ) {

    assert( !( app.cpu.popul_buffer_f !is null && app.cpu.popul_buffer_d !is null ));

    auto old_cell_count = app.cpu.cell_count;
    app.cpu.cell_count = app.sim.domain[0] * app.sim.domain[1] * app.sim.domain[2];
    size_t buffer_size = app.cpu.cell_count * ( app.sim.layout_value_count[ app.sim.layout ] + app.sim.layers );
    size_t old_buffer_mem_size = app.cpu.current_buffer_mem_size;
    app.cpu.current_buffer_mem_size = buffer_size * ( app.sim.use_double ? double.sizeof : float.sizeof );
    if( app.cpu.current_buffer_mem_size < old_buffer_mem_size )
        app.cpu.current_buffer_mem_size = old_buffer_mem_size;


    bool must_init;
    import core.stdc.stdlib : malloc, free;
    if( app.sim.use_double ) {
        //setSimFuncPlay( & cpuSimD_Play );
        if( app.cpu.popul_buffer_f !is null ) {
            if( old_buffer_mem_size < app.cpu.current_buffer_mem_size ) { // 2 * float.sizeof = double.sizeof
                free( cast( void* )app.cpu.popul_buffer_f );
                app.cpu.popul_buffer_f = null;
                app.cpu.cell_count = app.cpu.current_buffer_mem_size = 0;
                app.cpuReset;
            } else {
                app.cpu.popul_buffer_d = cast( double* )app.cpu.popul_buffer_f;
                app.cpu.popul_buffer_f = null;
                must_init = true;
            }
        } else if( old_buffer_mem_size < app.cpu.current_buffer_mem_size ) {
            if( app.cpu.popul_buffer_d !is null )
                free( cast( void* )app.cpu.popul_buffer_d );
            app.cpu.popul_buffer_d = cast( double* )malloc( app.cpu.current_buffer_mem_size );
        }

    } else {    // app.sim.use_double = false;
        //setSimFuncPlay( & cpuSimF_Play );
        if( app.cpu.popul_buffer_d !is null ) {
            if( old_cell_count * 2 < app.cpu.cell_count ) { // 2 * float.sizeof = double.sizeof
                free( cast( void* )app.cpu.popul_buffer_d );
                app.cpu.popul_buffer_d = null;
                app.cpu.cell_count = app.cpu.current_buffer_mem_size = 0;
                app.cpuReset;
            } else {
                app.cpu.popul_buffer_f = cast( float* )app.cpu.popul_buffer_d;
                app.cpu.popul_buffer_d = null;
                must_init = true;
            }
        } else if( old_cell_count < app.cpu.cell_count ) {
            if( app.cpu.popul_buffer_f !is null )
                free( cast( void* )app.cpu.popul_buffer_f );
            app.cpu.popul_buffer_f = cast( float* )malloc( app.cpu.current_buffer_mem_size );
        }
    }

    if( must_init )
        app.cpuInit;

}


// free cpu simulation resources
void cpuFree( ref VDrive_State app ) {
    import core.stdc.stdlib : free;
    free( cast( void* )app.cpu.popul_buffer_f ); app.cpu.popul_buffer_f = null;
    free( cast( void* )app.cpu.popul_buffer_d ); app.cpu.popul_buffer_d = null;

    app.cpu.cell_count = 0;

}


// setup cpu play and profile function pointer
void setCpuSimFuncs( ref VDrive_State app ) nothrow @system {
    if( app.sim.use_double ) {
        //setSimFuncPlay( & cpuSimD_Play );
        //setSimFuncProfile( & cpuSimD_Profile );
    } else {
        //setSimFuncPlay( & cpuSimF_Play );
        //setSimFuncProfile( & cpuSimF_Profile );
    }
}


// these aliases are shortcuts to templated function cpuSim
// they are used as function pointers called in module appstate
alias cpuSimF_Play      = cpuSim!( float  );
alias cpuSimD_Play      = cpuSim!( double );
alias cpuSimF_Profile   = cpuSim!( float,  true );
alias cpuSimD_Profile   = cpuSim!( double, true );


// multi-threaded template function implementing one cpu sim step
void cpuSim( T, bool PROFILE = false )( ref VDrive_State app ) nothrow @system {

    float    omega = app.sim.compute_ubo.collision_frequency;
    float    wall_velocity = app.sim.compute_ubo.wall_velocity_soss;
    int      D_x = app.sim.domain[0];
    int      D_y = app.sim.domain[1];

    static if( is( T == double )) {
        assert( app.cpu.popul_buffer_d !is null );
        T* popul_buffer = app.cpu.popul_buffer_d;
    } else {
        assert( app.cpu.popul_buffer_f !is null );
        T* popul_buffer = app.cpu.popul_buffer_f;
    }


    ubyte pong = app.cpu.ping;
    app.cpu.ping = cast( ubyte )( 8 - app.cpu.ping );


    try {
        static if( PROFILE ) app.startStopWatch;
        import std.range : iota;
        foreach( I; parallel( iota( 0, app.cpu.cell_count, 1 ), app.sim.work_group_size[0] )) {

            // load populations
            T[9] f = [
                popul_buffer[                             I ],
                popul_buffer[ ( app.cpu.ping + 1 ) * app.cpu.cell_count + I ],
                popul_buffer[ ( app.cpu.ping + 2 ) * app.cpu.cell_count + I ],
                popul_buffer[ ( app.cpu.ping + 3 ) * app.cpu.cell_count + I ],
                popul_buffer[ ( app.cpu.ping + 4 ) * app.cpu.cell_count + I ],
                popul_buffer[ ( app.cpu.ping + 5 ) * app.cpu.cell_count + I ],
                popul_buffer[ ( app.cpu.ping + 6 ) * app.cpu.cell_count + I ],
                popul_buffer[ ( app.cpu.ping + 7 ) * app.cpu.cell_count + I ],
                popul_buffer[ ( app.cpu.ping + 8 ) * app.cpu.cell_count + I ],
            ];

            // compute macroscopic density before applying wall velocity where required
            T rho = f[0] + f[1] + f[2] + f[3] + f[4] + f[5] + f[6] + f[7] + f[8];

            // compute 2D coordinates X and Y;
            size_t X = I % D_x;
            size_t Y = I / D_x;

            // Ladd's momentum correction for moving walls, applied to reflected populations not perpendicular to wall velocity
            if( Y == D_y - 1 /*|| Y == 0*/ ) {  // Handle top wall speed - 2 * w_i * rho * dot( c_i, u_w ) / c_s ^ 2
                f[7] -= 2 * app.cpu.pw[7] * rho * wall_velocity;
                f[8] += 2 * app.cpu.pw[8] * rho * wall_velocity;
            }

            // compute macroscopic velocity after wall velocity is applied
            T v_x = ( f[1] - f[3] + f[5] - f[7] + f[8] - f[6] ) / rho;
            T v_y = ( f[2] - f[4] + f[5] - f[7] + f[6] - f[8] ) / rho;

            // store velocities and densities in stage buffer to copy to image with format VK_FORMAT_R32G32B32A32_SFLOAT
            app.cpu.sim_image_ptr[ 4 * I + 0 ] = cast( float )v_x;
            app.cpu.sim_image_ptr[ 4 * I + 1 ] = cast( float )v_y;
            app.cpu.sim_image_ptr[ 4 * I + 2 ] = 0;
            app.cpu.sim_image_ptr[ 4 * I + 3 ] = 1;

            T[9] f_eq = [
                app.cpu.pw[0] * rho * (1                                                        - 1.5 * (v_x * v_x + v_y * v_y)), // app.cpu.pw[0] * rho * ( 1                     - V_D_V ), //
                app.cpu.pw[1] * rho * (1 + 3 * ( v_x)       + 4.5 * ( v_x)       * ( v_x)       - 1.5 * (v_x * v_x + v_y * v_y)), // app.cpu.pw[1] * rho * ( 1 + 3 *  v_x  + V_X_2 - V_D_V ), //
                app.cpu.pw[2] * rho * (1 + 3 * ( v_y)       + 4.5 * ( v_y)       * ( v_y)       - 1.5 * (v_x * v_x + v_y * v_y)), // app.cpu.pw[2] * rho * ( 1 + 3 *  v_y  + V_Y_2 - V_D_V ), //
                app.cpu.pw[3] * rho * (1 + 3 * (-v_x)       + 4.5 * (-v_x)       * (-v_x)       - 1.5 * (v_x * v_x + v_y * v_y)), // app.cpu.pw[3] * rho * ( 1 - 3 *  v_x  + V_X_2 - V_D_V ), //
                app.cpu.pw[4] * rho * (1 + 3 * (-v_y)       + 4.5 * (-v_y)       * (-v_y)       - 1.5 * (v_x * v_x + v_y * v_y)), // app.cpu.pw[4] * rho * ( 1 - 3 *  v_y  + V_Y_2 - V_D_V ), //
                app.cpu.pw[5] * rho * (1 + 3 * ( v_x + v_y) + 4.5 * ( v_x + v_y) * ( v_x + v_y) - 1.5 * (v_x * v_x + v_y * v_y)), // app.cpu.pw[5] * rho * ( 1 + 3 * X_P_Y + XPY_2 - V_D_V ), //
                app.cpu.pw[6] * rho * (1 + 3 * (-v_x + v_y) + 4.5 * (-v_x + v_y) * (-v_x + v_y) - 1.5 * (v_x * v_x + v_y * v_y)), // app.cpu.pw[6] * rho * ( 1 - 3 * X_M_Y + XMY_2 - V_D_V ), //
                app.cpu.pw[7] * rho * (1 + 3 * (-v_x - v_y) + 4.5 * (-v_x - v_y) * (-v_x - v_y) - 1.5 * (v_x * v_x + v_y * v_y)), // app.cpu.pw[7] * rho * ( 1 - 3 * X_P_Y + XPY_2 - V_D_V ), //
                app.cpu.pw[8] * rho * (1 + 3 * ( v_x - v_y) + 4.5 * ( v_x - v_y) * ( v_x - v_y) - 1.5 * (v_x * v_x + v_y * v_y)), // app.cpu.pw[8] * rho * ( 1 + 3 * X_M_Y + XMY_2 - V_D_V )  //
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
            popul_buffer[ X == D_x - 1 ? ( pong + 3 ) * app.cpu.cell_count + I : ( pong + 1 ) * app.cpu.cell_count +   1 + I ] = f[1];
            popul_buffer[ Y ==       0 ? ( pong + 4 ) * app.cpu.cell_count + I : ( pong + 2 ) * app.cpu.cell_count - D_x + I ] = f[2];
            popul_buffer[ X ==       0 ? ( pong + 1 ) * app.cpu.cell_count + I : ( pong + 3 ) * app.cpu.cell_count -   1 + I ] = f[3];
            popul_buffer[ Y == D_y - 1 ? ( pong + 2 ) * app.cpu.cell_count + I : ( pong + 4 ) * app.cpu.cell_count + D_x + I ] = f[4];

            popul_buffer[ ( X == D_x - 1 || Y ==       0 ) ? ( pong + 7 ) * app.cpu.cell_count + I : ( pong + 5 ) * app.cpu.cell_count - D_x + 1 + I ] = f[5];
            popul_buffer[ ( Y ==       0 || X ==       0 ) ? ( pong + 8 ) * app.cpu.cell_count + I : ( pong + 6 ) * app.cpu.cell_count - D_x - 1 + I ] = f[6];
            popul_buffer[ ( X ==       0 || Y == D_y - 1 ) ? ( pong + 5 ) * app.cpu.cell_count + I : ( pong + 7 ) * app.cpu.cell_count + D_x - 1 + I ] = f[7];
            popul_buffer[ ( Y == D_y - 1 || X == D_x - 1 ) ? ( pong + 6 ) * app.cpu.cell_count + I : ( pong + 8 ) * app.cpu.cell_count + D_x + 1 + I ] = f[8];

        }
        static if( PROFILE ) app.stopStopWatch;
    } catch( Exception ) {}



    import vdrive.memory;
    app.flushMappedMemoryRange( app.cpu.sim_stage_buffer.mem_range );
    //app.cpu.sim_stage_buffer.flushMappedMemoryRange;

    // increment indexes
    ++app.sim.index;
    ++app.sim.compute_ubo.comp_index;

    // display the result
    app.drawSim;
}



//////////////////////////////
// destroy vulkan resources //
//////////////////////////////
void destroyCpuResources( ref VDrive_State app ) {
    app.destroy( app.cpu.sim_stage_buffer );
}

