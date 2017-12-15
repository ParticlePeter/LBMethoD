
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
    VkCommandPool       sim_cmd_pool;           // we do not reset this on window resize events
    VkCommandBuffer[2]  sim_cmd_buffers;        // using ping pong approach for now
    Meta_Image          sim_image;              // output macroscopic moments density and velocity
    VkSampler           nearest_sampler;
    Meta_Buffer         sim_buffer;             // mesoscopic velocity populations
    VkBufferView        sim_buffer_view;        // arbitrary count of buffer views, dynamic resizing is not that easy as we would have to recreate the descriptor set each time
    VkPipelineCache     compute_cache;
    Core_Pipeline       loop_pso;
    Core_Pipeline       init_pso;

    // compute parameter
    uint32_t[3]         sim_domain          = [ 400, 225, 1 ]; //[ 256, 256, 1 ];   // [ 256, 64, 1 ];
    uint32_t            sim_layers          = 17;
    uint32_t[3]         sim_work_group_size = [ 400, 1, 1 ];
    uint32_t            sim_ping_pong       = 1;
    uint32_t            sim_step_size       = 1;
    string              init_shader         = "shader\\init_D2Q9.comp";
    string              loop_shader         = "shader\\loop_D2Q9_ldc.comp";

    // simulate parameter
    enum Collision      : uint32_t { SRT, TRT, MRT, CSC, CSC_DRAG };
    immutable float     unit_speed_of_sound = 0.5773502691896258; // 1 / sqrt( 3 );
    float               speed_of_sound      = unit_speed_of_sound;
    float               unit_spatial        = 1;
    float               unit_temporal       = 1;
    Collision           sim_collision       = Collision.CSC_DRAG;
    uint32_t            sim_index           = 0;
}



//////////////////////////////////////////
// create or recreate simulation buffer //
//////////////////////////////////////////
void createSimBuffer( ref VDrive_State vd ) {

    // (re)create buffer and buffer view
    if( vd.vs.sim_buffer.buffer   != VK_NULL_HANDLE ) {
        vd.graphics_queue.vkQueueWaitIdle;
        vd.vs.sim_buffer.destroyResources;          // destroy old buffer
    }
    if( vd.vs.sim_buffer_view     != VK_NULL_HANDLE ) {
        vd.graphics_queue.vkQueueWaitIdle;
        vd.destroy( vd.vs.sim_buffer_view );        // destroy old buffer view
    }


    // For D2Q9 we need 1 + 2 * 8 Shader Storage Buffers with sim_dim.x * sim_dim.y cells,
    // for 512 ^ 2 cells this means ( 1 + 2 * 8 ) * 4 * 512 * 512 = 17_825_792 bytes
    // create one buffer 1 + 2 * 8 buffer views into that buffer
    uint32_t buffer_size = vd.vs.sim_layers * vd.vs.sim_domain[0] * vd.vs.sim_domain[1] * ( vd.use_3_dim ? vd.vs.sim_domain[2] : 1 );
    uint32_t buffer_mem_size = buffer_size * ( vd.use_double ? double.sizeof : float.sizeof ).toUint;

    vd.vs.sim_buffer( vd )
        .create( VK_BUFFER_USAGE_STORAGE_TEXEL_BUFFER_BIT, buffer_mem_size )
        .createMemory( VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT );

    vd.vs.sim_buffer_view =
        vd.createBufferView( vd.vs.sim_buffer.buffer,
            vd.use_double ? VK_FORMAT_R32G32_UINT : VK_FORMAT_R32_SFLOAT, 0, buffer_mem_size );

}



/////////////////////////////////////////////////////////////////////////////////////////
// create compute pipelines and compute command buffers to initialize and simulate LBM //
/////////////////////////////////////////////////////////////////////////////////////////
void createSimResources( ref VDrive_State vd ) {
    vd.vs.compute_cache = vd.createPipelineCache;
    vd.createBoltzmannPSO( true, true, true );
}



///////////////////////////////////////////////////
// create LBM init and loop PSOs helper function //
///////////////////////////////////////////////////
private void createBoltzmannPSO( ref VDrive_State vd, ref Core_Pipeline pso, string shader_path ) {

    // create meta_Specialization struct to specify shader local work group size and algorithm
    Meta_SC!( 4 ) meta_sc;
    meta_sc
        .addMapEntry( MapEntry32(  vd.vs.sim_work_group_size[0] ))                                     // default constantID is 0, next would be 1
        .addMapEntry( MapEntry32(  vd.vs.sim_work_group_size[1] ))                                     // default constantID is 1, next would be 2
        .addMapEntry( MapEntry32(  vd.vs.sim_work_group_size[2] ))                                     // default constantID is 2, next would be 3
        .addMapEntry( MapEntry32(( vd.vs.sim_step_size << 8 ) + cast( uint32_t )vd.vs.sim_collision ))    // upper 24 bits is the step_size, lower 8 bits the algorithm
        .construct;

    vd.graphics_queue.vkQueueWaitIdle;          // wait for queue idle as we need to destroy the pipeline
    if( pso.is_constructed )                    // possibly destroy old compute pipeline and layout
        vd.destroy( pso );

    Meta_Compute meta_compute;                  // use temporary Meta_Compute struct to specify and create the pso
    pso = meta_compute( vd )                    // extracting the core items after construction with reset call
        .shaderStageCreateInfo( vd.createPipelineShaderStage( shader_path, & meta_sc.specialization_info ))
        .addDescriptorSetLayout( vd.descriptor.descriptor_set_layout )
        .addPushConstantRange( VK_SHADER_STAGE_COMPUTE_BIT, 0, 8 )
        .construct( vd.vs.compute_cache )       // construct using pipeline cache
        .destroyShaderModule                    // destroy shader modules
        .reset;                                 // reset temporary Meta_Compute struct and extract core pipeline data
}



///////////////////////////////////
// create LBM init and loop PSOs //
///////////////////////////////////
void createBoltzmannPSO( ref VDrive_State vd, bool init_pso, bool loop_pso, bool reset_sim ) {

    // (re)create Boltzmann init PSO if required
    if( init_pso ) {
        vd.createBoltzmannPSO( vd.vs.init_pso, vd.vs.init_shader );
    }

    if( reset_sim ) {

        //////////////////////////////////////////////////
        // initialize populations with compute pipeline //
        //////////////////////////////////////////////////

        auto init_cmd_buffer = vd.allocateCommandBuffer( vd.cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY );
        auto init_cmd_buffer_bi = createCmdBufferBI( VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT );
        init_cmd_buffer.vkBeginCommandBuffer( &init_cmd_buffer_bi );


        init_cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_COMPUTE, vd.vs.init_pso.pipeline ); // bind compute vd.vs.loop_pso
        init_cmd_buffer.vkCmdBindDescriptorSets(// VkCommandBuffer              commandBuffer           // bind descriptor set
            VK_PIPELINE_BIND_POINT_COMPUTE,     // VkPipelineBindPoint          pipelineBindPoint
            vd.vs.init_pso.pipeline_layout,     // VkPipelineLayout             layout
            0,                                  // uint32_t                     firstSet
            1,                                  // uint32_t                     descriptorSetCount
            &vd.descriptor.descriptor_set,      // const( VkDescriptorSet )*    pDescriptorSets
            0,                                  // uint32_t                     dynamicOffsetCount
            null                                // const( uint32_t )*           pDynamicOffsets
        );

        // determine dispatch group X count from simulation domain vd.vs.sim_domain and compute work group size vd.vs.sim_work_group_size[0]
        uint32_t dispatch_x = vd.vs.sim_domain[0] * vd.vs.sim_domain[1] * vd.vs.sim_domain[2] / vd.vs.sim_work_group_size[0];
        init_cmd_buffer.vkCmdDispatch( dispatch_x, 1, 1 );      // dispatch compute command
        init_cmd_buffer.vkEndCommandBuffer;                     // finish recording and submit the command
        auto submit_info = init_cmd_buffer.queueSubmitInfo;     // submit the command buffer
        vd.graphics_queue.vkQueueSubmit( 1, &submit_info, VK_NULL_HANDLE ).vkAssert;

    }


    // (re)create compute pipeline for runtime loop
    if( loop_pso ) {
        vd.createBoltzmannPSO( vd.vs.loop_pso, vd.vs.loop_shader );      // putting responsibility to use the right double shader into users hand
    }

    // (re)create command buffers
    vd.createComputeCommands;
}



/////////////////////////////////////////////////
// create two reusable compute command buffers //
/////////////////////////////////////////////////
void createComputeCommands( ref VDrive_State vd ) nothrow {

    // reset the command pool to start recording drawing commands
    vd.graphics_queue.vkQueueWaitIdle;   // equivalent using a fence per Spec v1.0.48
    vd.device.vkResetCommandPool( vd.vs.sim_cmd_pool, 0 ); // second argument is VkCommandPoolResetFlags

    // two command buffers for compute loop, one ping and one pong buffer
    vd.allocateCommandBuffers( vd.vs.sim_cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, vd.vs.sim_cmd_buffers );
    auto sim_cmd_buffers_bi = createCmdBufferBI;

    // work group count in X direction only
    uint32_t dispatch_x = vd.vs.sim_domain[0] * vd.vs.sim_domain[1] * vd.vs.sim_domain[2] / vd.vs.sim_work_group_size[0];



    //
    // record simple commands in loop, if sim_step_size is 1
    //
    if( vd.vs.sim_step_size == 1 ) {
        foreach( i, ref cmd_buffer; vd.vs.sim_cmd_buffers ) {
            uint32_t[2] push_constant = [ i.toUint, vd.vs.sim_layers ];    // push constant to specify either 0-1 ping-pong and pass in the sim layer count
            cmd_buffer.vkBeginCommandBuffer( &sim_cmd_buffers_bi );     // begin command buffer recording
            cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_COMPUTE, vd.vs.loop_pso.pipeline );    // bind compute vd.vs.loop_pso.pipeline
            cmd_buffer.vkCmdBindDescriptorSets(     // VkCommandBuffer              commandBuffer
                VK_PIPELINE_BIND_POINT_COMPUTE,     // VkPipelineBindPoint          pipelineBindPoint
                vd.vs.loop_pso.pipeline_layout,     // VkPipelineLayout             layout
                0,                                  // uint32_t                     firstSet
                1,                                  // uint32_t                     descriptorSetCount
                &vd.descriptor.descriptor_set,      // const( VkDescriptorSet )*    pDescriptorSets
                0,                                  // uint32_t                     dynamicOffsetCount
                null                                // const( uint32_t )*           pDynamicOffsets
            );
            cmd_buffer.vkCmdPushConstants( vd.vs.loop_pso.pipeline_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, 8, push_constant.ptr ); // push constant
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
        buffer              : vd.vs.sim_buffer.buffer,
        offset              : 0,
        size                : VK_WHOLE_SIZE,
    };



    //
    // otherwise record complex commands with memory barriers in loop
    //
    foreach( i, ref cmd_buffer; vd.vs.sim_cmd_buffers ) {
        cmd_buffer.vkBeginCommandBuffer( &sim_cmd_buffers_bi );  // begin command buffer recording
        cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_COMPUTE, vd.vs.loop_pso.pipeline );    // bind compute vd.vs.loop_pso.pipeline
        cmd_buffer.vkCmdBindDescriptorSets(             // VkCommandBuffer              commandBuffer
            VK_PIPELINE_BIND_POINT_COMPUTE,             // VkPipelineBindPoint          pipelineBindPoint
            vd.vs.loop_pso.pipeline_layout,             // VkPipelineLayout             layout
            0,                                          // uint32_t                     firstSet
            1,                                          // uint32_t                     descriptorSetCount
            &vd.descriptor.descriptor_set,              // const( VkDescriptorSet )*    pDescriptorSets
            0,                                          // uint32_t                     dynamicOffsetCount
            null                                        // const( uint32_t )*           pDynamicOffsets
        );


        //
        // Now do step_size count simulations
        //
        foreach( s; 0 .. vd.vs.sim_step_size ) {
            uint32_t[2] push_constant = [ s.toUint, vd.vs.sim_layers ];    // push constant to specify dispatch invocation counter and pass in the sim layer count
            cmd_buffer.vkCmdPushConstants( vd.vs.loop_pso.pipeline_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, 8, push_constant.ptr ); // push constant
            cmd_buffer.vkCmdDispatch( dispatch_x, 1, 1 );   // dispatch compute command

            // buffer barrier to wait for all populations being written to memory
            cmd_buffer.vkCmdPipelineBarrier(
                VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,       // VkPipelineStageFlags                 srcStageMask,
                VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,       // VkPipelineStageFlags                 dstStageMask,
                0,                                          // VkDependencyFlags                    dependencyFlags,
                0, null,                                    // uint32_t memoryBarrierCount,         const VkMemoryBarrier* pMemoryBarriers,
                1, & sim_buffer_memory_barrier,             // uint32_t bufferMemoryBarrierCount,   const VkBufferMemoryBarrier* pBufferMemoryBarriers,
                0, null,                                    // uint32_t imageMemoryBarrierCount,    const VkImageMemoryBarrier*  pImageMemoryBarriers,
            );
        }

        // finish recording current command buffer
        cmd_buffer.vkEndCommandBuffer;
    }
}



//////////////////////////////
// destroy vulkan resources //
//////////////////////////////
void destroySimResources( ref VDrive_State vd ) {

    vd.vs.compute_ubo_buffer.destroyResources;

    vd.vs.sim_image.destroyResources;
    vd.destroy( vd.vs.nearest_sampler );

    vd.vs.sim_buffer.destroyResources;
    vd.destroy( vd.vs.sim_buffer_view );

    vd.destroy( vd.vs.sim_cmd_pool );
    vd.destroy( vd.vs.init_pso );
    vd.destroy( vd.vs.loop_pso );
    vd.destroy( vd.vs.compute_cache );
}