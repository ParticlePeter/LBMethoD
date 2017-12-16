
import erupted;

import vdrive;
import appstate;



//////////////////////////////////////////
// simulation state and resource struct //
//////////////////////////////////////////
struct VDrive_Simulate_State {

    // simulation resources
    struct Compute_UBO {
        float               collision_frequency = 1;    // sim param omega
        float               wall_velocity       = 0;    // sim param for lid driven cavity
        uint32_t            wall_thickness      = 1;
        uint32_t            comp_index          = 0;
    } Compute_UBO*      compute_ubo;
    Meta_Buffer         compute_ubo_buffer;
    VkMappedMemoryRange compute_ubo_flush;
    VkCommandPool       cmd_pool;               // we do not reset this on window resize events
    VkCommandBuffer[2]  cmd_buffers;            // using ping pong approach for now
    Meta_Image          macro_image;            // output macroscopic moments density and velocity
    VkSampler           nearest_sampler;
    Meta_Buffer         popul_buffer;           // mesoscopic velocity populations
    VkBufferView        popul_buffer_view;      // arbitrary count of buffer views, dynamic resizing is not that easy as we would have to recreate the descriptor set each time
    VkPipelineCache     compute_cache;
    Core_Pipeline       loop_pso;
    Core_Pipeline       init_pso;

    // compute parameter
    uint32_t[3]         domain              = [ 400, 225, 1 ]; //[ 256, 256, 1 ];   // [ 256, 64, 1 ];
    uint32_t            layers              = 17;
    uint32_t[3]         work_group_size     = [ 400, 1, 1 ];
    uint32_t            ping_pong           = 1;
    uint32_t            step_size           = 1;
    string              init_shader         = "shader\\init_D2Q9.comp";
    string              loop_shader         = "shader\\loop_D2Q9_ldc.comp";

    // simulate parameter
    immutable float     unit_speed_of_sound = 0.5773502691896258; // 1 / sqrt( 3 );
    float               speed_of_sound      = unit_speed_of_sound;
    float               unit_spatial        = 1;
    float               unit_temporal       = 1;
    enum Collision      : uint32_t {SRT, TRT, MRT, CSC, CSC_DRAG };
    Collision           collision           = Collision.CSC_DRAG;
    uint32_t            index               = 0;
}



//////////////////////////////////////////
// create or recreate simulation buffer //
//////////////////////////////////////////
void createSimBuffer( ref VDrive_State app ) {

    // (re)create buffer and buffer view
    if( app.sim.popul_buffer.buffer   != VK_NULL_HANDLE ) {
        app.graphics_queue.vkQueueWaitIdle;
        app.sim.popul_buffer.destroyResources;          // destroy old buffer
    }
    if( app.sim.popul_buffer_view     != VK_NULL_HANDLE ) {
        app.graphics_queue.vkQueueWaitIdle;
        app.destroy( app.sim.popul_buffer_view );       // destroy old buffer view
    }


    // For D2Q9 we need 1 + 2 * 8 Shader Storage Buffers with sim_dim.x * sim_dim.y cells,
    // for 512 ^ 2 cells this means ( 1 + 2 * 8 ) * 4 * 512 * 512 = 17_825_792 bytes
    // create one buffer 1 + 2 * 8 buffer views into that buffer
    uint32_t buffer_size = app.sim.layers * app.sim.domain[0] * app.sim.domain[1] * ( app.use_3_dim ? app.sim.domain[2] : 1 );
    uint32_t buffer_mem_size = buffer_size * ( app.use_double ? double.sizeof : float.sizeof ).toUint;

    app.sim.popul_buffer( app )
        .create( VK_BUFFER_USAGE_STORAGE_TEXEL_BUFFER_BIT, buffer_mem_size )
        .createMemory( VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT );

    app.sim.popul_buffer_view =
        app.createBufferView( app.sim.popul_buffer.buffer,
            app.use_double ? VK_FORMAT_R32G32_UINT : VK_FORMAT_R32_SFLOAT, 0, buffer_mem_size );

}



////////////////////////////////////////////////
/// create or recreate simulation image array //
////////////////////////////////////////////////
void createSimImage( ref VDrive_State app ) {

    // 1) (re)create Image
    if( app.sim.macro_image.image != VK_NULL_HANDLE ) {
        app.graphics_queue.vkQueueWaitIdle;
        app.sim.macro_image.destroyResources( false );  // destroy old image and its view, keeping the sampler
    }

    // Todo(pp): the format should be choose-able
    // Todo(pp): here checks are required if this image format is available for VK_IMAGE_USAGE_STORAGE_BIT
    //import vdrive.util.info;
    //app.imageFormatProperties(
    //    VK_FORMAT_R32G32B32A32_SFLOAT,
    //    VK_IMAGE_TYPE_2D,
    //    VK_IMAGE_TILING_OPTIMAL,
    //    VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_STORAGE_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
    //).printTypeInfo;

    auto image_format = VK_FORMAT_R32G32B32A32_SFLOAT; //VK_FORMAT_R16G16B16A16_SFLOAT
    VkImageSubresourceRange subresource_range = {
        aspectMask      : VK_IMAGE_ASPECT_COLOR_BIT,
        baseMipLevel    : cast( uint32_t )0,
        levelCount      : 1,
        baseArrayLayer  : cast( uint32_t )0,
        layerCount      : app.sim.domain[2],
    };
    app.sim.macro_image( app )
        .create(
            image_format,
            app.sim.domain[0], app.sim.domain[1], 0,    // through the 0 we request a VK_IMAGE_TYPE_2D
            1, app.sim.domain[2],                       // mip levels and array layers
            VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_STORAGE_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            VK_SAMPLE_COUNT_1_BIT,
            VK_IMAGE_TILING_OPTIMAL     // : VK_IMAGE_TILING_LINEAR
            )
        .createMemory( VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT )    // : VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT )   // Todo(pp): check which memory property is required for the image format
        .createView( subresource_range, VK_IMAGE_VIEW_TYPE_2D_ARRAY, image_format );


    // transition VkImage from layout VK_IMAGE_LAYOUT_UNDEFINED into layout VK_IMAGE_LAYOUT_GENERAL for compute shader access
    auto init_cmd_buffer = app.allocateCommandBuffer( app.cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY );
    auto init_cmd_buffer_bi = createCmdBufferBI( VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT );
    init_cmd_buffer.vkBeginCommandBuffer( & init_cmd_buffer_bi );

    // record image layout transition to VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
    init_cmd_buffer.recordTransition(
        app.sim.macro_image.image,
        app.sim.macro_image.subresourceRange,
        VK_IMAGE_LAYOUT_UNDEFINED,
        VK_IMAGE_LAYOUT_GENERAL,
        0,  // no access mask required here
        VK_ACCESS_SHADER_WRITE_BIT,
        VK_PIPELINE_STAGE_HOST_BIT,
        VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT );

    init_cmd_buffer.vkEndCommandBuffer;                 // finish recording and submit the command
    auto submit_info = init_cmd_buffer.queueSubmitInfo; // submit the command buffer
    app.graphics_queue.vkQueueSubmit( 1, & submit_info, VK_NULL_HANDLE ).vkAssert;

    // staging buffer for cpu computed velocity copy to the sim_image
    if( app.cpu.sim_stage_buffer.is_constructed ) {
        app.graphics_queue.vkQueueWaitIdle;
        app.cpu.sim_stage_buffer.destroyResources;      // destroy old image and its view, keeping the sampler
    }

    uint32_t buffer_size = 4 * app.sim.domain[0] * app.sim.domain[1];   // only in 2D and with VK_FORMAT_R32G32B32A32_SFLOAT
    uint32_t buffer_mem_size = buffer_size * float.sizeof.toUint;

    app.cpu.sim_image_ptr = cast( float* )( app.cpu.sim_stage_buffer( app )
        .create( VK_BUFFER_USAGE_TRANSFER_SRC_BIT, buffer_mem_size )
        .createMemory( VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT )
        .mapMemory );
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
private void createBoltzmannPSO( ref VDrive_State app, ref Core_Pipeline pso, string shader_path ) {

    // create meta_Specialization struct to specify shader local work group size and algorithm
    Meta_SC!( 4 ) meta_sc;
    meta_sc
        .addMapEntry( MapEntry32(  app.sim.work_group_size[0] ))                                     // default constantID is 0, next would be 1
        .addMapEntry( MapEntry32(  app.sim.work_group_size[1] ))                                     // default constantID is 1, next would be 2
        .addMapEntry( MapEntry32(  app.sim.work_group_size[2] ))                                     // default constantID is 2, next would be 3
        .addMapEntry( MapEntry32(( app.sim.step_size << 8 ) + cast( uint32_t )app.sim.collision ))    // upper 24 bits is the step_size, lower 8 bits the algorithm
        .construct;

    if( pso.is_constructed ) {
        app.graphics_queue.vkQueueWaitIdle;     // wait for queue idle, we need to destroy the pipeline
        app.destroy( pso );                     // possibly destroy old compute pipeline and layout
    }

    Meta_Compute meta_compute;                  // use temporary Meta_Compute struct to specify and create the pso
    pso = meta_compute( app )                   // extracting the core items after construction with reset call
        .shaderStageCreateInfo( app.createPipelineShaderStage( shader_path, & meta_sc.specialization_info ))
        .addDescriptorSetLayout( app.descriptor.descriptor_set_layout )
        .addPushConstantRange( VK_SHADER_STAGE_COMPUTE_BIT, 0, 8 )
        .construct( app.sim.compute_cache )     // construct using pipeline cache
        .destroyShaderModule                    // destroy shader modules
        .reset;                                 // reset temporary Meta_Compute struct and extract core pipeline data
}



///////////////////////////////////
// create LBM init and loop PSOs //
///////////////////////////////////
void createBoltzmannPSO( ref VDrive_State app, bool init_pso, bool loop_pso, bool reset_sim ) {

    // (re)create Boltzmann init PSO if required
    if( init_pso ) {
        app.createBoltzmannPSO( app.sim.init_pso, app.sim.init_shader );
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
    }

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
    app.allocateCommandBuffers( app.sim.cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, app.sim.cmd_buffers );
    auto sim_cmd_buffers_bi = createCmdBufferBI;

    // work group count in X direction only
    uint32_t dispatch_x = app.sim.domain[0] * app.sim.domain[1] * app.sim.domain[2] / app.sim.work_group_size[0];



    //
    // record simple commands in loop, if sim_step_size is 1
    //
    if( app.sim.step_size == 1 ) {
        foreach( i, ref cmd_buffer; app.sim.cmd_buffers ) {
            uint32_t[2] push_constant = [ i.toUint, app.sim.layers ];    // push constant to specify either 0-1 ping-pong and pass in the sim layer count
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
            cmd_buffer.vkEndCommandBuffer;                      // finish recording and submit the command
        }
        return;
    }



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
            uint32_t[2] push_constant = [ s.toUint, app.sim.layers ];    // push constant to specify dispatch invocation counter and pass in the sim layer count
            cmd_buffer.vkCmdPushConstants( app.sim.loop_pso.pipeline_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, 8, push_constant.ptr ); // push constant
            cmd_buffer.vkCmdDispatch( dispatch_x, 1, 1 );   // dispatch compute command

            // buffer barrier to wait for all populations being written to memory
            cmd_buffer.vkCmdPipelineBarrier(
                VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,   // VkPipelineStageFlags                 srcStageMask,
                VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,   // VkPipelineStageFlags                 dstStageMask,
                0,                                      // VkDependencyFlags                    dependencyFlags,
                0, null,                                // uint32_t memoryBarrierCount,         const VkMemoryBarrier* pMemoryBarriers,
                1, & sim_buffer_memory_barrier,         // uint32_t bufferMemoryBarrierCount,   const VkBufferMemoryBarrier* pBufferMemoryBarriers,
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

    app.sim.compute_ubo_buffer.destroyResources;

    app.sim.macro_image.destroyResources;
    app.destroy( app.sim.nearest_sampler );

    app.sim.popul_buffer.destroyResources;
    app.destroy( app.sim.popul_buffer_view );

    app.destroy( app.sim.cmd_pool );
    app.destroy( app.sim.init_pso );
    app.destroy( app.sim.loop_pso );
    app.destroy( app.sim.compute_cache );
}