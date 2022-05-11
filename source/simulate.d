
import erupted;

import vdrive;
import appstate;

import settings : setting;


//nothrow @nogc:


//////////////////////////////////////////
// simulation state and resource struct //
//////////////////////////////////////////
struct Sim_State {

    alias Macro_Image = Core_Image_T!( 1, 2, IMC.Memory | IMC.Extent | IMC.Sub_Range );

    // simulation resources
    struct Compute_UBO {
        nothrow:
        @setting void   		relaxation_rate( float rate )   { collision_frequency = 1 / rate; }
        @setting float  		relaxation_rate()               { return 1 / collision_frequency; }
        @setting void   		wall_velocity( float vel )      { wall_velocity_soss =  vel * 3.0f; }   // pre-multiply wall velocity with speed of sound squared (3.0f) for shader usage
        @setting float  		wall_velocity()                 { return wall_velocity_soss / 3.0f; }   // divide shader usage of wall velocity by speed of sound squared (3.0f)
        float                   collision_frequency = 1;    // sim param omega
        @setting float          wall_velocity_soss  = 0;    // sim param wall velocity times speed of sound squared for lid driven cavity
        @setting uint32_t       wall_thickness      = 1;
        uint32_t                comp_index          = 0;
        float[2]                mouse_xy            = [ 0, 0 ];
        float[2]                force_xy            = [ 0, 0 ];
        int32_t                 force_type          = 0;
        int32_t[4]              slide_axis          = 0;
    } @setting Compute_UBO* compute_ubo;
    VDrive_State.Ubo_Buffer	compute_ubo_buffer;
    VkCommandPool           cmd_pool;               // we do not reset this on window resize events
    VkCommandBuffer[2]      cmd_buffers;            // using ping pong approach for now
    Macro_Image             macro_image;            // output macroscopic moments density and velocity
    Core_Buffer_Memory_View popul_buffer;           // mesoscopic velocity populations
    //VkBufferView            popul_buffer_view;      // arbitrary count of buffer views, dynamic resizing is not that easy as we would have to recreate the descriptor set each time
    VkPipelineCache         compute_cache;
    Core_Pipeline           loop_pso;
    Core_Pipeline           init_pso;

    enum Layout : uint32_t { D0Q0, D2Q9, D3Q15, D3Q27 };
    immutable ubyte[4] layout_value_count = [ 0, 17, 29, 53 ];

    // compute parameter
    @setting Layout         layout              = Layout.D2Q9;
    @setting uint32_t[3]    domain              = [ 1600, 900, 1 ]; //[ 256, 256, 1 ];   // [ 256, 64, 1 ];
    @setting uint32_t[3]    work_group_size     = [ 800, 1, 1 ];
    @setting uint32_t       step_size           = 1;
    @setting uint32_t       layers              = 0;
    @setting bool           use_double          = false;

    uint32_t                ping_pong           = 1;
    @setting char[64]       init_shader         = "shader\\init_D2Q9.comp";
    @setting char[64]       loop_shader         = "shader\\loop_D2Q9_ldc.comp";

    // simulate parameter
    enum Collision          : uint32_t { SRT, TRT, MRT, CSC, CSC_DRAG };
    @setting Collision      collision           = Collision.CSC_DRAG;
    immutable float         unit_speed_of_sound = 0.5773502691896258; // 1 / sqrt( 3 );
    float                   speed_of_sound      = unit_speed_of_sound;
    @setting float          unit_spatial        = 1;
    @setting float          unit_temporal       = 1;

    uint32_t                index               = 0;

    // mouse force reference parameter
    float[2]                force_reference;

    bool use_3_dim()        { return layout != Layout.D2Q9; }
    uint32_t cell_count()   { return domain[0] * domain[1] * domain[2]; }
    ubyte cell_val_count()  { return layout_value_count[ layout ]; }
}


// compute mouse force and update compute UBO
private auto planeHit( VDrive_State* app, float x, float y ) nothrow @nogc {
    import dlsl.vector, dlsl.matrix, std.math : tan;
    float   half_res_y = 2.0f / ( app.windowHeight - 1 );
    float   top = tan( app.projection_fovy * 0.00872664625997164788461845384244 /* PI / 360.0 */ );
    auto    mat = ( mat3( app.tbb.worldTransform )).transpose;
    auto    dir = (
                mat[2]
                + top * mat[1] * (                     1 - half_res_y * app.mouse.pos_y )
                - top * mat[0] * ( app.projection_aspect - half_res_y * app.mouse.pos_x )
                ).normalize;
    auto    eye = app.tbb.eye;
    return  ( eye.xy - eye.z / dir.z * dir.xy ).data;
}

// compute mouse force from current hit on plane and previous, used with mouse click-drag event
void mouseForce( VDrive_State* app ) nothrow @nogc {
    app.sim.compute_ubo.mouse_xy = app.planeHit( app.mouse.vel_x, app.mouse.vel_y );
    app.sim.compute_ubo.force_xy = app.sim.compute_ubo.mouse_xy[] - app.sim.force_reference[];
    app.sim.force_reference = app.sim.compute_ubo.mouse_xy;
}

// set reference on plane for force computation, used with mouse click event
void mouseForceReference( VDrive_State* app ) nothrow @nogc {
    app.sim.compute_ubo.force_xy[] = 0;
    app.sim.force_reference = app.sim.compute_ubo.mouse_xy = app.planeHit( app.mouse.vel_x, app.mouse.vel_y );
    app.sim.compute_ubo.force_type = app.tbb.button;
}


//////////////////////////////////////////
// create or recreate simulation buffer //
//////////////////////////////////////////
void createPopulBuffer( ref VDrive_State app ) {

    // (re)create buffer and buffer view
    if(!app.sim.popul_buffer.is_null ) {
        app.graphics_queue.vkQueueWaitIdle;
        app.destroy( app.sim.popul_buffer );       // destroy old buffer and view
    }

    // For D2Q9 we need 1 + 2 * 8 Shader Storage Buffers with sim_dim.x * sim_dim.y cells,
    // for 512 ^ 2 cells this means ( 1 + 2 * 8 ) * 4 * 512 * 512 = 17_825_792 bytes
    // create one buffer 1 + 2 * 8 buffer views into that buffer
    uint32_t values_per_cell = app.sim.layout_value_count[ app.sim.layout ];
    uint32_t buffer_size = values_per_cell * app.sim.domain[0] * app.sim.domain[1] * ( app.sim.use_3_dim ? app.sim.domain[2] : 1 );
    uint32_t buffer_mem_size = buffer_size * ( app.sim.use_double ? double.sizeof : float.sizeof ).toUint;

    app.sim.popul_buffer = Meta_Buffer_Memory_View( app )
        .usage( VK_BUFFER_USAGE_STORAGE_TEXEL_BUFFER_BIT )
        .bufferSize( buffer_mem_size )
        .viewFormat( app.sim.use_double ? VK_FORMAT_R32G32_UINT : VK_FORMAT_R32_SFLOAT )
        .construct( VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT )
        .reset;
}



////////////////////////////////////////////////
/// create or recreate simulation image array //
////////////////////////////////////////////////
void createMacroImage( ref VDrive_State app ) {

    // 1) (re)create Image
    if( app.sim.macro_image.image != VK_NULL_HANDLE ) {
        app.graphics_queue.vkQueueWaitIdle;
        app.destroy( app.sim.macro_image, false );
    }

    // Todo(pp): the format should be choose-able
    // Todo(pp): here checks are required if this image format is available for VK_IMAGE_USAGE_STORAGE_BIT

    auto image_format = VK_FORMAT_R32G32B32A32_SFLOAT; //VK_FORMAT_R16G16B16A16_SFLOAT

    // specify and construct image with new Binding Rvalues to ref Parameters syntax, requires dmd v2.086.0 and higher
    auto meta_macro_image = Meta_Image_T!( Sim_State.Macro_Image )( app )
        .format( image_format )
        .extent( app.sim.domain[0], app.sim.domain[1] )         // specifying only two dims we request a 2D image
        .arrayLayers( app.sim.domain[2] )                       // array layers, mip levels default is 1
        .addUsage( VK_IMAGE_USAGE_SAMPLED_BIT )
        .addUsage( VK_IMAGE_USAGE_STORAGE_BIT )
        .addUsage( VK_BUFFER_USAGE_TRANSFER_DST_BIT )
        .tiling( VK_IMAGE_TILING_OPTIMAL )                      // tiling, sample count default is 1
        .constructImage

        // allocate and bind image memory
        .allocateMemory( VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT )  // : VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT )   // Todo(pp): check which memory property is required for the image format

        // specify and construct image view
        .viewArrayLayers( 0, app.sim.domain[2] )
        .viewType( VK_IMAGE_VIEW_TYPE_2D_ARRAY )
        .constructView;
    //  .constructSampler( 0 );     // re-creates sampler and does not destroy the old one, which is stored in Core_Sampler

    // specify and construct sampler 0
    if( app.sim.macro_image.sampler[0].is_null )
        meta_macro_image.filter( VK_FILTER_LINEAR, VK_FILTER_LINEAR ).constructSampler( 0 );
    //  meta_macro_image.unnormalizedCoordinates( VK_TRUE ).constructSampler( 0 );

    // specify and construct sampler 1, inherits sampler 0 specification, as we didn't reset the sampler create info
    if( app.sim.macro_image.sampler[1].is_null )
        meta_macro_image.filter( VK_FILTER_NEAREST, VK_FILTER_NEAREST ).constructSampler( 1 );

    // extract Core_Image_T from Meta_Image_T meta_macro_image, but don't reset it, we still need some of its data later
    meta_macro_image.extractCore( app.sim.macro_image );

    debug {
        app.setDebugName( app.sim.macro_image.sampler[0], "Macro Image Sampler Linear" );
        app.setDebugName( app.sim.macro_image.sampler[1], "Macro Image Sampler Nearest" );
    }


    // transition VkImage from layout VK_IMAGE_LAYOUT_UNDEFINED into layout VK_IMAGE_LAYOUT_GENERAL for compute shader access
    auto init_cmd_buffer = app.allocateCommandBuffer( app.cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY );
    auto init_cmd_buffer_bi = createCmdBufferBI( VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT );
    init_cmd_buffer.vkBeginCommandBuffer( & init_cmd_buffer_bi );

    // record image layout transition to VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
    init_cmd_buffer.recordTransition(
        meta_macro_image.image,
        meta_macro_image.subresourceRange,
        VK_IMAGE_LAYOUT_UNDEFINED,
        VK_IMAGE_LAYOUT_GENERAL,
        0,  // no access mask required here
        VK_ACCESS_SHADER_WRITE_BIT,
        VK_PIPELINE_STAGE_HOST_BIT,
        VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT );

    init_cmd_buffer.vkEndCommandBuffer;                 // finish recording and submit the command
    auto submit_info = init_cmd_buffer.queueSubmitInfo; // submit the command buffer
    app.graphics_queue.vkQueueSubmit( 1, & submit_info, VK_NULL_HANDLE ).vkAssert;

    // setup staging buffer and members for cpu sim
    import cpustate : createCpuMacroImageStaggingBuffer;
    app.createCpuMacroImageStaggingBuffer( meta_macro_image.extent, meta_macro_image.subresourceRange );

    // reset
    meta_macro_image.reset;
}



/////////////////////////////////////////////////////////////////////////////////////////
// create compute pipelines and compute command buffers to initialize and simulate LBM //
/////////////////////////////////////////////////////////////////////////////////////////
void createSimResources( ref VDrive_State app ) {
    app.sim.compute_cache = app.createPipelineCache;
    app.createBoltzmannPSO( true, true, true );
}



///////////////////////////////////////////////////
// create LBM init and loop PSOs helper function //
///////////////////////////////////////////////////
private void createBoltzmannPSO( ref VDrive_State app, ref Core_Pipeline pso, char[] shader_path ) {

    //import std.stdio;
    //auto wgs = app.sim.work_group_size;
    //writefln( "In createBoltzmannPSO: app.sim.work_group_size = [ %s, %s, %s ]\n", wgs[0], wgs[1], wgs[2] );

    // create meta_Specialization struct to specify shader local work group size and algorithm
    //Meta_Specialization_T!( 4 ) meta_sc;
    auto meta_sc = Meta_Specialization_T!( 4 )()
        .addMapEntry( MapEntry32(  app.sim.work_group_size[0] ))                                     // default constantID is 0, next would be 1
        .addMapEntry( MapEntry32(  app.sim.work_group_size[1] ))                                     // default constantID is 1, next would be 2
        .addMapEntry( MapEntry32(  app.sim.work_group_size[2] ))                                     // default constantID is 2, next would be 3
        .addMapEntry( MapEntry32(( app.sim.step_size << 8 ) + cast( uint32_t )app.sim.collision ))   // upper 24 bits is the step_size, lower 8 bits the algorithm
        .construct;

    if(!pso.is_null ) {
        app.graphics_queue.vkQueueWaitIdle;     // wait for queue idle, we need to destroy the pipeline
        app.destroy( pso );                     // possibly destroy old compute pipeline and layout
    }

    pso = Meta_Compute_T!( 1, 1)( app )         // extracting the core items after construction with reset call
        .shaderStageCreateInfo( app.createPipelineShaderStage( shader_path.ptr, & meta_sc.specialization_info ))
        .addDescriptorSetLayout( app.descriptor.descriptor_set_layout )
        .addPushConstantRange( VK_SHADER_STAGE_COMPUTE_BIT, 0, 8 )
        .construct( app.sim.compute_cache )     // construct using pipeline cache
        .destroyShaderModule                    // destroy shader modules
        .reset;                                 // reset temporary Meta_Compute struct and extract core pipeline data

    //import std.stdio;
    //writeln( meta_compute.static_config );
    //pso = meta_compute.reset;

}



///////////////////////////////////
// create LBM init and loop PSOs //
///////////////////////////////////
void createBoltzmannPSO( ref VDrive_State app, bool init_pso, bool loop_pso, bool reset_sim ) {

    // (re)create Boltzmann init PSO if required
    if( init_pso ) {
        app.createBoltzmannPSO( app.sim.init_pso, app.sim.init_shader );

        debug {
            app.setDebugName( app.sim.init_pso.pipeline,        "Simulation Init Pipeline" );
            app.setDebugName( app.sim.init_pso.pipeline_layout, "Simulation Init Pipeline Layout" );
        }
    }

    if( reset_sim ) {

        //////////////////////////////////////////////////
        // initialize populations with compute pipeline //
        //////////////////////////////////////////////////

        auto init_cmd_buffer = app.allocateCommandBuffer( app.cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY );
        auto init_cmd_buffer_bi = createCmdBufferBI( VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT );
        init_cmd_buffer.vkBeginCommandBuffer( & init_cmd_buffer_bi );


        init_cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_COMPUTE, app.sim.init_pso.pipeline ); // bind compute app.sim.loop_pso
        init_cmd_buffer.vkCmdBindDescriptorSets(        // VkCommandBuffer              commandBuffer           // bind descriptor set
            VK_PIPELINE_BIND_POINT_COMPUTE,             // VkPipelineBindPoint          pipelineBindPoint
            app.sim.init_pso.pipeline_layout,           // VkPipelineLayout             layout
            0,                                          // uint32_t                     firstSet
            1,                                          // uint32_t                     descriptorSetCount
            & app.descriptor.descriptor_set,            // const( VkDescriptorSet )*    pDescriptorSets
            0,                                          // uint32_t                     dynamicOffsetCount
            null                                        // const( uint32_t )*           pDynamicOffsets
        );

        // determine dispatch group X count from simulation domain app.sim.domain and compute work group size app.sim.work_group_size[0]
        uint32_t dispatch_x = app.sim.domain[0] * app.sim.domain[1] * app.sim.domain[2] / app.sim.work_group_size[0];
        init_cmd_buffer.vkCmdDispatch( dispatch_x, 1, 1 );      // dispatch compute command
        init_cmd_buffer.vkEndCommandBuffer;                     // finish recording and submit the command
        auto submit_info = init_cmd_buffer.queueSubmitInfo;     // submit the command buffer
        app.graphics_queue.vkQueueSubmit( 1, & submit_info, VK_NULL_HANDLE ).vkAssert;

    }


    // (re)create compute pipeline for runtime loop
    if( loop_pso ) {
        app.createBoltzmannPSO( app.sim.loop_pso, app.sim.loop_shader );    // putting responsibility to use the right double shader into users hand

        debug {
            app.setDebugName( app.sim.loop_pso.pipeline,        "Simulation Loop Pipeline" );
            app.setDebugName( app.sim.loop_pso.pipeline_layout, "Simulation Loop Pipeline Layout" );
        }
    }

    //

    // (re)create command buffers
    app.createComputeCommands;
}



/////////////////////////////////////////////////
// create two reusable compute command buffers //
/////////////////////////////////////////////////
void createComputeCommands( ref VDrive_State app ) nothrow {

    // reset the command pool to start recording drawing commands
    app.graphics_queue.vkQueueWaitIdle;     // equivalent using a fence per Spec v1.0.48
    app.device.vkResetCommandPool( app.sim.cmd_pool, 0 );   // second argument is VkCommandPoolResetFlags

    // two command buffers for compute loop, one ping and one pong buffer
    app.allocateCommandBuffers( app.sim.cmd_pool, app.sim.cmd_buffers );
    auto sim_cmd_buffers_bi = createCmdBufferBI;

    // work group count in X direction only
    uint32_t dispatch_x = app.sim.domain[0] * app.sim.domain[1] * app.sim.domain[2] / app.sim.work_group_size[0];

    // cper cell value count
    uint32_t values_per_cell = app.sim.layout_value_count[ app.sim.layout ];



    //
    // record simple commands in loop, if sim_step_size is 1
    //



    if( app.sim.step_size == 1 ) {

        foreach( i, ref cmd_buffer; app.sim.cmd_buffers ) {
            uint32_t[2] push_constant = [ i.toUint, values_per_cell ];   // push constant to specify either 0-1 ping-pong and pass in the sim layer count
            cmd_buffer.vkBeginCommandBuffer( & sim_cmd_buffers_bi );     // begin command buffer recording
            cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_COMPUTE, app.sim.loop_pso.pipeline );    // bind compute app.sim.loop_pso.pipeline
            cmd_buffer.vkCmdBindDescriptorSets(         // VkCommandBuffer              commandBuffer
                VK_PIPELINE_BIND_POINT_COMPUTE,         // VkPipelineBindPoint          pipelineBindPoint
                app.sim.loop_pso.pipeline_layout,       // VkPipelineLayout             layout
                0,                                      // uint32_t                     firstSet
                1,                                      // uint32_t                     descriptorSetCount
                & app.descriptor.descriptor_set,        // const( VkDescriptorSet )*    pDescriptorSets
                0,                                      // uint32_t                     dynamicOffsetCount
                null                                    // const( uint32_t )*           pDynamicOffsets
            );
            cmd_buffer.vkCmdPushConstants( app.sim.loop_pso.pipeline_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, 8, push_constant.ptr ); // push constant
        //  cmd_buffer.vdCmdDispatch( work_group_count );       // dispatch compute command, forwards to vkCmdDispatch( cmd_buffer, dispatch_group_count.x, dispatch_group_count.y, dispatch_group_count.z );
            cmd_buffer.vkCmdDispatch( dispatch_x, 1, 1 );       // dispatch compute command
            cmd_buffer.vkEndCommandBuffer;                      // finish recording
        }
        return;
    }


    // supposed to be more efficient than buffer or image barrier
    VkMemoryBarrier sim_memory_barrier = {
        srcAccessMask   : VK_ACCESS_SHADER_WRITE_BIT,
        dstAccessMask   : VK_ACCESS_SHADER_READ_BIT,
    };


    // buffer barrier for population invoked after each dispatch
    VkBufferMemoryBarrier sim_buffer_memory_barrier = {
        srcAccessMask       : VK_ACCESS_SHADER_WRITE_BIT,
        dstAccessMask       : VK_ACCESS_SHADER_READ_BIT,
        srcQueueFamilyIndex : VK_QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex : VK_QUEUE_FAMILY_IGNORED,
        buffer              : app.sim.popul_buffer.buffer,
        offset              : 0,
        size                : VK_WHOLE_SIZE,
    };



    //
    // otherwise record complex commands with memory barriers in loop
    //
    foreach( i, ref cmd_buffer; app.sim.cmd_buffers ) {
        cmd_buffer.vkBeginCommandBuffer( & sim_cmd_buffers_bi );  // begin command buffer recording
        cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_COMPUTE, app.sim.loop_pso.pipeline );    // bind compute app.sim.loop_pso.pipeline
        cmd_buffer.vkCmdBindDescriptorSets(             // VkCommandBuffer              commandBuffer
            VK_PIPELINE_BIND_POINT_COMPUTE,             // VkPipelineBindPoint          pipelineBindPoint
            app.sim.loop_pso.pipeline_layout,           // VkPipelineLayout             layout
            0,                                          // uint32_t                     firstSet
            1,                                          // uint32_t                     descriptorSetCount
            & app.descriptor.descriptor_set,            // const( VkDescriptorSet )*    pDescriptorSets
            0,                                          // uint32_t                     dynamicOffsetCount
            null                                        // const( uint32_t )*           pDynamicOffsets
        );


        //
        // Now do step_size count simulations
        //
        foreach( s; 0 .. app.sim.step_size ) {
            uint32_t[2] push_constant = [ s.toUint, values_per_cell ];   // push constant to specify dispatch invocation counter and pass in the sim layer count
            cmd_buffer.vkCmdPushConstants( app.sim.loop_pso.pipeline_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, 8, push_constant.ptr ); // push constant
            cmd_buffer.vkCmdDispatch( dispatch_x, 1, 1 );   // dispatch compute command

            // buffer barrier to wait for all populations being written to memory
            cmd_buffer.vkCmdPipelineBarrier(
                VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,   // VkPipelineStageFlags                 srcStageMask,
                VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,   // VkPipelineStageFlags                 dstStageMask,
                0,                                      // VkDependencyFlags                    dependencyFlags,

                //*

                1, & sim_memory_barrier,                // uint32_t memoryBarrierCount,         const VkMemoryBarrier* pMemoryBarriers,
                0, null,                                // uint32_t bufferMemoryBarrierCount,   const VkBufferMemoryBarrier* pBufferMemoryBarriers,

                /*/

                0, null,                                // uint32_t memoryBarrierCount,         const VkMemoryBarrier* pMemoryBarriers,
                1, & sim_buffer_memory_barrier,         // uint32_t bufferMemoryBarrierCount,   const VkBufferMemoryBarrier* pBufferMemoryBarriers,

                //*/

                0, null,                                // uint32_t imageMemoryBarrierCount,    const VkImageMemoryBarrier*  pImageMemoryBarriers,
            );
        }

        // finish recording current command buffer
        cmd_buffer.vkEndCommandBuffer;
    }
}



//////////////////////////////
// destroy vulkan resources //
//////////////////////////////
void destroySimResources( ref VDrive_State app ) {

    //app.sim.compute_ubo_buffer.destroyResources;
    app.destroy( app.sim.compute_ubo_buffer );

//  app.sim.macro_image.destroyResources;
    app.destroy( app.sim.macro_image );

    app.destroy( app.sim.popul_buffer );
    //app.sim.popul_buffer.destroyResources;
    //app.destroy( app.sim.popul_buffer_view );

    app.destroy( app.sim.cmd_pool );
    app.destroy( app.sim.init_pso );
    app.destroy( app.sim.loop_pso );
    app.destroy( app.sim.compute_cache );
}