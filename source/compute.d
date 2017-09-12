module compute;

import erupted;

import vdrive;
import appstate;



//////////////////////////////////////////
// create or recreate simulation buffer //
//////////////////////////////////////////

void createSimBuffer( ref VDrive_State vd ) {

    // (re)create buffer and buffer view
    if( vd.sim_buffer.buffer   != VK_NULL_HANDLE ) {
        vd.graphics_queue.vkQueueWaitIdle;
        vd.sim_buffer.destroyResources;          // destroy old buffer
    }
    if( vd.sim_buffer_view     != VK_NULL_HANDLE ) {
        vd.graphics_queue.vkQueueWaitIdle;
        vd.destroy( vd.sim_buffer_view );        // destroy old buffer view
    }


    // For D2Q9 we need 1 + 2 * 8 Shader Storage Buffers with sim_dim.x * sim_dim.y cells,
    // for 512 ^ 2 cells this means ( 1 + 2 * 8 ) * 4 * 512 * 512 = 17_825_792 bytes
    // create one buffer 1 + 2 * 8 buffer views into that buffer
    uint32_t buffer_size = vd.sim_layers * vd.sim_domain[0] * vd.sim_domain[1] * ( vd.sim_use_3_dim ? vd.sim_domain[2] : 1 );
    uint32_t buffer_mem_size = buffer_size * ( vd.sim_use_double ? double.sizeof : float.sizeof ).toUint;

    vd.sim_buffer( vd )
        .create( VK_BUFFER_USAGE_STORAGE_TEXEL_BUFFER_BIT, buffer_mem_size )
        .createMemory( VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT );

    vd.sim_buffer_view =
        vd.createBufferView( vd.sim_buffer.buffer,
            vd.sim_use_double ? VK_FORMAT_R32G32_UINT : VK_FORMAT_R32_SFLOAT, 0, buffer_mem_size );

}



/////////////////////////////////////////////////////////////////////////////////////////
// create compute pipelines and compute command buffers to initialize and simulate LBM //
/////////////////////////////////////////////////////////////////////////////////////////

void createComputeResources( ref VDrive_State vd ) {

    vd.compute_cache = vd.createPipelineCache;
    vd.createBoltzmannPSO( true, true, true );

}



//////////////////////////////////////////////////////////////////
// create LBM init and loop PSOs as well as sim command buffers //
//////////////////////////////////////////////////////////////////

void createBoltzmannPSO( ref VDrive_State vd, bool init_pso, bool loop_pso, bool reset_sim ) {

    // create Meta_Specialization struct with static data array
    Meta_SC!( 4 ) meta_sc;
    meta_sc
        .addMapEntry( MapEntry32( vd.sim_work_group_size[0] ))  // default constantID is 0, next would be 1
        .addMapEntry( MapEntry32( vd.sim_work_group_size[1] ))  // default constantID is 1, next would be 2
        .addMapEntry( MapEntry32( vd.sim_work_group_size[2] ))  // default constantID is 2, next would be 3
        .addMapEntry( MapEntry32( vd.sim_algorithm ), 3 )       // latter is the constantID, must be passed in if the current constant id does not correspond
        .construct;

    void createComputePSO( Core_Pipeline* pso, string shader_path ) {
        vd.graphics_queue.vkQueueWaitIdle;  // wait for queue idle as we need to destroy the pipeline
        Meta_Compute meta_compute;          // use temporary Meta_Compute struct to specify and create the pso
        auto old_pso = *pso;                // store old pipeline to destroy after new pipeline is created
        *pso = meta_compute( vd )           // extracting the core items after construction with reset call
            //.basePipeline( old_pso.pipeline )
            .shaderStageCreateInfo( vd.createPipelineShaderStage( VK_SHADER_STAGE_COMPUTE_BIT, shader_path, & meta_sc.specialization_info ))
            .addDescriptorSetLayout( vd.descriptor.descriptor_set_layout )
            .addPushConstantRange( VK_SHADER_STAGE_COMPUTE_BIT, 0, 8 )
            .construct( vd.compute_cache )  // construct using pipeline cache
            .destroyShaderModule
            .reset;

        // destroy old compute pipeline and layout
        if( old_pso.pipeline != VK_NULL_HANDLE )
            vd.destroy( old_pso );
    }

    // determine dispatch group X count from simulation domain vd.sim_domain and compute work group size vd.sim_work_group_size[0]
    uint32_t dispatch_x = vd.sim_domain[0] * vd.sim_domain[1] * vd.sim_domain[2] / vd.sim_work_group_size[0];
    /*
    uint32_t[3] work_group_count = [
        vd.sim_domain[0] / vd.sim_work_group_size[0],
        vd.sim_domain[1] / vd.sim_work_group_size[1],
        vd.sim_use_3_dim ? vd.sim_domain[2] / vd.sim_work_group_size[2] : 1,
    ];
    */

    //import std.stdio;
    //writeln( "sim_domain: ", vd.sim_domain );
    //writeln( "group_size: ", vd.sim_work_group_size );
    //writeln( "dispatch_x: ", dispatch_x );

    // possibly initialize the populations with initialization compute shader
    if( init_pso ) {
        createComputePSO( & vd.comp_init_pso, vd.sim_init_shader ); // putting responsibility to use the right double shader into users hand
        //  vd.sim_use_double ? "shader/init_D2Q9_double.comp" : "shader/init_D2Q9.comp" );
        //reset_sim = true;
    }

    if( reset_sim ) {

        //////////////////////////////////////////////////
        // initialize populations with compute pipeline //
        //////////////////////////////////////////////////

        auto init_cmd_buffer = vd.allocateCommandBuffer( vd.cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY );
        auto init_cmd_buffer_bi = createCmdBufferBI( VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT );
        init_cmd_buffer.vkBeginCommandBuffer( &init_cmd_buffer_bi );


        init_cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_COMPUTE, vd.comp_init_pso.pipeline ); // bind compute vd.comp_loop_pso
        init_cmd_buffer.vkCmdBindDescriptorSets(// VkCommandBuffer              commandBuffer           // bind descriptor set
            VK_PIPELINE_BIND_POINT_COMPUTE,     // VkPipelineBindPoint          pipelineBindPoint
            vd.comp_init_pso.pipeline_layout,   // VkPipelineLayout             layout
            0,                                  // uint32_t                     firstSet
            1,                                  // uint32_t                     descriptorSetCount
            &vd.descriptor.descriptor_set,      // const( VkDescriptorSet )*    pDescriptorSets
            0,                                  // uint32_t                     dynamicOffsetCount
            null                                // const( uint32_t )*           pDynamicOffsets
        );

    //  init_cmd_buffer.vdCmdDispatch( work_group_count );      // dispatch compute command, forwards to vkCmdDispatch( cmd_buffer, dispatch_group_count.x, dispatch_group_count.y, dispatch_group_count.z );
        init_cmd_buffer.vkCmdDispatch( dispatch_x, 1, 1 );      // dispatch compute command
        init_cmd_buffer.vkEndCommandBuffer;                     // finish recording and submit the command
        auto submit_info = init_cmd_buffer.queueSubmitInfo;     // submit the command buffer
        vd.graphics_queue.vkQueueSubmit( 1, &submit_info, VK_NULL_HANDLE ).vkAssert;

    }



    ////////////////////////////////////////////////
    // recreate compute pipeline for runtime loop //
    ////////////////////////////////////////////////

    if( loop_pso ) {
        // reuse meta_compute to create loop compute pso with collision algorithm specialization
        //meta_sc.specialization_data[3] = MapEntry32( vd.sim_algorithm );    // all settings higher 0 are loop algorithms
        createComputePSO( & vd.comp_loop_pso, vd.sim_loop_shader );         // putting responsibility to use the right double shader into users hand
        //  vd.sim_use_double ? "shader/loop_D2Q9_ldc_double.comp" : "shader/loop_D2Q9_channel_flow.comp" );
    }


    /////////////////////////////////////////////////
    // create two reusable compute command buffers //
    /////////////////////////////////////////////////

    // reset the command pool to start recording drawing commands
    vd.graphics_queue.vkQueueWaitIdle;   // equivalent using a fence per Spec v1.0.48
    vd.device.vkResetCommandPool( vd.sim_cmd_pool, 0 ); // second argument is VkCommandPoolResetFlags

    // two command buffers for compute loop, one ping and one pong buffer
    vd.allocateCommandBuffers( vd.sim_cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, vd.sim_cmd_buffers );
    auto sim_cmd_buffers_bi = createCmdBufferBI;

    // record commands in loop, only difference is the push constant
    foreach( i, ref cmd_buffer; vd.sim_cmd_buffers ) {
        uint32_t[2] push_constant = [ i.toUint, vd.sim_layers ];
        cmd_buffer.vkBeginCommandBuffer( &sim_cmd_buffers_bi );  // begin command buffer recording
        cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_COMPUTE, vd.comp_loop_pso.pipeline );    // bind compute vd.comp_loop_pso.pipeline
        cmd_buffer.vkCmdBindDescriptorSets(     // VkCommandBuffer              commandBuffer
            VK_PIPELINE_BIND_POINT_COMPUTE,     // VkPipelineBindPoint          pipelineBindPoint
            vd.comp_loop_pso.pipeline_layout,     // VkPipelineLayout             layout
            0,                                  // uint32_t                     firstSet
            1,                                  // uint32_t                     descriptorSetCount
            &vd.descriptor.descriptor_set,      // const( VkDescriptorSet )*    pDescriptorSets
            0,                                  // uint32_t                     dynamicOffsetCount
            null                                // const( uint32_t )*           pDynamicOffsets
        );
        cmd_buffer.vkCmdPushConstants( vd.comp_loop_pso.pipeline_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, 8, push_constant.ptr ); // push constant
    //  cmd_buffer.vdCmdDispatch( work_group_count );       // dispatch compute command, forwards to vkCmdDispatch( cmd_buffer, dispatch_group_count.x, dispatch_group_count.y, dispatch_group_count.z );
        cmd_buffer.vkCmdDispatch( dispatch_x, 1, 1 );       // dispatch compute command
        cmd_buffer.vkEndCommandBuffer;                      // finish recording and submit the command
    }

    // init_pso ping pong variable to 1
    // it will be switched to 0 ( pp = 1 - pp ) befor submitting compute commands
    //vd.sim_ping_pong = 1;

}



void createComputeCommands( ref VDrive_State vd ) nothrow {

    ///////////////////////////////////////////////////////////////////////////
    // create two reusable compute command buffers with export functionality //
    ///////////////////////////////////////////////////////////////////////////

    // Wait till queue is drained, reset the command buffers individually with vkBeginCommandBuffer
    vd.graphics_queue.vkQueueWaitIdle;   // equivalent using a fence per Spec v1.0.48

    // common command buffer begin info
    auto sim_cmd_buffers_bi = createCmdBufferBI;

    // barrier for population access from export shader
    VkBufferMemoryBarrier sim_buffer_memory_barrier = {
        srcAccessMask       : VK_ACCESS_SHADER_WRITE_BIT,
        dstAccessMask       : VK_ACCESS_SHADER_READ_BIT,
        srcQueueFamilyIndex : VK_QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex : VK_QUEUE_FAMILY_IGNORED,
        buffer              : vd.sim_buffer.buffer,
        offset              : 0,
        size                : VK_WHOLE_SIZE,
    };

    uint32_t dispatch_x = vd.sim_domain[0] * vd.sim_domain[1] * vd.sim_domain[2] / vd.sim_work_group_size[0];



    // record commands in loop, only difference is the push constant
    foreach( i, ref cmd_buffer; vd.sim_cmd_buffers ) {

        // - vd.ping_pong = ve.sim_index % 2;
        // - vd.sim_index = ve.start_index + ve.export_index * ve.step_size;

        //
        // First export the current frame!
        //

        cmd_buffer.vkBeginCommandBuffer( &sim_cmd_buffers_bi );  // begin command buffer recording

        cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_COMPUTE, vd.comp_loop_pso.pipeline );    // bind compute vd.comp_export_pso.pipeline

        cmd_buffer.vkCmdBindDescriptorSets(             // VkCommandBuffer              commandBuffer
            VK_PIPELINE_BIND_POINT_COMPUTE,             // VkPipelineBindPoint          pipelineBindPoint
            vd.comp_loop_pso.pipeline_layout,           // VkPipelineLayout             layout
            0,                                          // uint32_t                     firstSet
            1,                                          // uint32_t                     descriptorSetCount
            &vd.descriptor.descriptor_set,              // const( VkDescriptorSet )*    pDescriptorSets
            0,                                          // uint32_t                     dynamicOffsetCount
            null                                        // const( uint32_t )*           pDynamicOffsets
        );

        // with this approach we are able to export sim step zero, initial settings, where no simulation took place
        // we export from the pong buffer, for any other case, after simulation took place
        // hence we use ( i + 1 ) % 2 instead of i % 2
        // to get proper results, the pong range of the population buffer and the macroscopic property image
        // must be properly initialized

        uint32_t[2] push_constant = [ ( i + 1 ).toUint % 2, vd.sim_layers ];
        cmd_buffer.vkCmdPushConstants( vd.comp_loop_pso.pipeline_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, 8, push_constant.ptr );    // push constant

        cmd_buffer.vkCmdDispatch( dispatch_x, 1, 1 );   // dispatch compute command
        /*
        export_buffer_memory_barrier.buffer = vd.export_buffer[i].buffer;
        cmd_buffer.vkCmdPipelineBarrier(
            VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,       // VkPipelineStageFlags                 srcStageMask,
            VK_PIPELINE_STAGE_HOST_BIT,                 // VkPipelineStageFlags                 dstStageMask,
            0,                                          // VkDependencyFlags                    dependencyFlags,
            0, null,                                    // uint32_t memoryBarrierCount,         const VkMemoryBarrier*  pMemoryBarriers,
            1, & export_buffer_memory_barrier,          // uint32_t bufferMemoryBarrierCount,   const VkBufferMemoryBarrier* pBufferMemoryBarriers,
            0, null,                                    // uint32_t imageMemoryBarrierCount,    const VkImageMemoryBarrier*  pImageMemoryBarriers,
        );
        */

        //
        // Now do step_size count simulations
        //
        auto step_size = 10;
        foreach( s; 0 .. step_size ) {   // vd.ve.step_size

            //push_constant[0] = (( ve.sim_index + i + s ) % 2 ).toUint;
            push_constant[0] = (( i + s ) % 2 ).toUint;

            cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_COMPUTE, vd.comp_loop_pso.pipeline );    // bind compute vd.comp_loop_pso.pipeline

            cmd_buffer.vkCmdBindDescriptorSets(             // VkCommandBuffer              commandBuffer
                VK_PIPELINE_BIND_POINT_COMPUTE,             // VkPipelineBindPoint          pipelineBindPoint
                vd.comp_loop_pso.pipeline_layout,           // VkPipelineLayout             layout
                0,                                          // uint32_t                     firstSet
                1,                                          // uint32_t                     descriptorSetCount
                &vd.descriptor.descriptor_set,              // const( VkDescriptorSet )*    pDescriptorSets
                0,                                          // uint32_t                     dynamicOffsetCount
                null                                        // const( uint32_t )*           pDynamicOffsets
            );

            cmd_buffer.vkCmdPushConstants( vd.comp_loop_pso.pipeline_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, 8, push_constant.ptr ); // push constant

            cmd_buffer.vkCmdDispatch( dispatch_x, 1, 1 );   // dispatch compute command

            cmd_buffer.vkCmdPipelineBarrier(
                VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,       // VkPipelineStageFlags                 srcStageMask,
                VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,       // VkPipelineStageFlags                 dstStageMask,
                0,                                          // VkDependencyFlags                    dependencyFlags,
                0, null,                                    // uint32_t memoryBarrierCount,         const VkMemoryBarrier* pMemoryBarriers,
                1, & sim_buffer_memory_barrier,             // uint32_t bufferMemoryBarrierCount,   const VkBufferMemoryBarrier* pBufferMemoryBarriers,
                0, null,                                    // uint32_t imageMemoryBarrierCount,    const VkImageMemoryBarrier*  pImageMemoryBarriers,
            );
        }

        cmd_buffer.vkEndCommandBuffer;                  // finish recording and submit the command
    }

    // init_pso ping pong variable to 1
    // it will be switched to 0 ( pp = 1 - pp ) befor submitting compute commands
    //vd.sim_ping_pong = 1;
}