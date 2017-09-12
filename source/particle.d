
import erupted;

import vdrive;
import appstate;




/*  // Todo(pp): Is this usefull ??
/// create general texel buffer
void createTexelBuffer(
    ref Meta_Buffer         buffer,
    ref VkBufferView        buffer_view,
    VkBufferUsageFlags      buffer_usage_flags,
    VkMemoryPropertyFlags   buffer_memory_flags,
    VkDeviceSize            buffer_mem_size,
    VkFormat                buffer_format
    ) {

    // (re)create buffer and buffer view
    if( buffer.buffer   != VK_NULL_HANDLE )
        buffer.destroyResources;          // destroy old buffer

    if( buffer_view     != VK_NULL_HANDLE )
        vd.destroy( buffer_view );        // destroy old buffer view

    buffer_view = buffer
        .create( buffer_usage_flags, buffer_mem_size )
        .createMemory( buffer_memory_flags );
        .createBufferView( buffer.buffer, buffer_format );

}
*/



/// create particle resources
void createParticleResources( ref VDrive_State vd ) {

    vd.createParticleDrawPSO;
    vd.createParticleCompPSO( true, true );

}

/// create particle buffer
void createParticleBuffer( ref VDrive_State vd ) {

    // (re)create buffer and buffer view
    if( vd.sim_particle_buffer.buffer   != VK_NULL_HANDLE ) {
        vd.graphics_queue.vkQueueWaitIdle;
        vd.sim_particle_buffer.destroyResources;          // destroy old buffer
    }
    if( vd.sim_buffer_view     != VK_NULL_HANDLE ) {
        vd.graphics_queue.vkQueueWaitIdle;
        vd.destroy( vd.sim_particle_buffer_view );        // destroy old buffer view
    }

    uint32_t buffer_mem_size = vd.sim_particle_count * ( 3 * float.sizeof ).toUint;

    vd.sim_particle_buffer( vd )
        .create( VK_BUFFER_USAGE_STORAGE_TEXEL_BUFFER_BIT | VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, buffer_mem_size )
        .createMemory( VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT );

    vd.sim_particle_buffer_view =
        vd.createBufferView( vd.sim_particle_buffer.buffer, VK_FORMAT_R32G32B32A32_SFLOAT );

}






void createParticleCompPSO( ref VDrive_State vd, bool init_pso, bool loop_pso ) {

    // create Meta_Specialization struct with static data array
    Meta_SC!( 1 ) meta_sc;
    meta_sc
        .addMapEntry( MapEntry32( 0 ))  // default constantID is 0, next would be 1
        .construct;

    void createComputePSO( Core_Pipeline* pso, string shader_path ) {
        vd.graphics_queue.vkQueueWaitIdle;  // wait for queue idle as we need to destroy the pipeline
        Meta_Compute meta_compute;          // use temporary Meta_Compute struct to specify and create the pso
        auto old_pso = *pso;                // store old pipeline to improve new pipeline construction speed
        *pso = meta_compute( vd )           		// extracting the core items after construction with reset call
            .shaderStageCreateInfo( vd.createPipelineShaderStage( VK_SHADER_STAGE_COMPUTE_BIT, shader_path, & meta_sc.specialization_info ))

        //if( noise_path != "" )
        //	meta_compute.shaderStageCreateInfo( vd.createPipelineShaderStage( VK_SHADER_STAGE_COMPUTE_BIT, noise_path ));

            .addDescriptorSetLayout( vd.descriptor.descriptor_set_layout )
            .addPushConstantRange( VK_SHADER_STAGE_COMPUTE_BIT, 0, 8 )
            .construct( vd.compute_cache )  // construct using pipeline cache
            .destroyShaderModule
            .reset;

        // destroy old compute pipeline and layout
        if( old_pso.pipeline != VK_NULL_HANDLE )
            vd.destroy( old_pso );
    }

    // possibly initialize the populations with initialization compute shader
    if( init_pso ) {
    	Core_Pipeline init_part_pso;
        createComputePSO( & init_part_pso, "shader/particle.comp" );

        //////////////////////////////////////////////////
        // initialize populations with compute pipeline //
        //////////////////////////////////////////////////

        auto init_cmd_buffer = vd.allocateCommandBuffer( vd.cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY );
        auto init_cmd_buffer_bi = createCmdBufferBI( VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT );
        init_cmd_buffer.vkBeginCommandBuffer( &init_cmd_buffer_bi );


        init_cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_COMPUTE, init_part_pso.pipeline );   // bind compute vd.comp_loop_pso
        init_cmd_buffer.vkCmdBindDescriptorSets(// VkCommandBuffer              commandBuffer           // bind descriptor set
            VK_PIPELINE_BIND_POINT_COMPUTE,     // VkPipelineBindPoint          pipelineBindPoint
            init_part_pso.pipeline_layout,      // VkPipelineLayout             layout
            0,                                  // uint32_t                     firstSet
            1,                                  // uint32_t                     descriptorSetCount
            &vd.descriptor.descriptor_set,      // const( VkDescriptorSet )*    pDescriptorSets
            0,                                  // uint32_t                     dynamicOffsetCount
            null                                // const( uint32_t )*           pDynamicOffsets
        );

    //  init_cmd_buffer.vdCmdDispatch( work_group_count );      // dispatch compute command, forwards to vkCmdDispatch( cmd_buffer, dispatch_group_count.x, dispatch_group_count.y, dispatch_group_count.z );
        init_cmd_buffer.vkCmdDispatch( 16, 1, 1 );      		// dispatch compute command
        init_cmd_buffer.vkEndCommandBuffer;                     // finish recording and submit the command
        auto submit_info = init_cmd_buffer.queueSubmitInfo;     // submit the command buffer
        vd.graphics_queue.vkQueueSubmit( 1, &submit_info, VK_NULL_HANDLE ).vkAssert;
        vd.graphics_queue.vkQueueWaitIdle;
        vd.destroy( init_part_pso );

    }



    ////////////////////////////////////////////////
    // recreate compute pipeline for runtime loop //
    ////////////////////////////////////////////////

    if( loop_pso ) {
        // reuse meta_compute to create loop compute pso with collision algorithm specialization
        meta_sc.specialization_data[0] = MapEntry32( 1 );    // all settings higher 0 are loop algorithms
        createComputePSO( & vd.comp_part_pso, "shader/particle.comp" );    // reuse code from above
    }

    // reccord commands in gui and gui-less command buffers
}



void createParticleDrawPSO( ref VDrive_State vd ) {

    // if we are recreating an old pipeline exists already, destroy it first
    if( vd.draw_part_pso.pipeline != VK_NULL_HANDLE ) {
        vd.graphics_queue.vkQueueWaitIdle;
        vd.destroy( vd.draw_part_pso );
    }

    //////////////////////////////
    // create particle pipeline //
    //////////////////////////////

    Meta_Graphics meta_graphics;
    vd.draw_part_pso = meta_graphics( vd )
        .addShaderStageCreateInfo( vd.createPipelineShaderStage( "shader/particle.vert" ))
        .addShaderStageCreateInfo( vd.createPipelineShaderStage( "shader/particle.frag" ))
        .inputAssembly( VK_PRIMITIVE_TOPOLOGY_POINT_LIST )                          // set the inputAssembly
        .addBindingDescription( 0, 2 * float.sizeof, VK_VERTEX_INPUT_RATE_VERTEX )  // add vertex binding and attribute descriptions
        .addAttributeDescription( 0, 0, VK_FORMAT_R32G32_SFLOAT, 0 )                // interleaved attributes of ImDrawVert ...
        .addViewportAndScissors( VkOffset2D( 0, 0 ), vd.swapchain.imageExtent )     // add viewport and scissor state, necessary even if we use dynamic state
        .cullMode( VK_CULL_MODE_BACK_BIT )                                          // set rasterization state
        .depthState                                                                 // set depth state - enable depth test with default attributes
        .addColorBlendState( VK_FALSE )                                             // color blend state - append common (default) color blend attachment state
        .addDynamicState( VK_DYNAMIC_STATE_VIEWPORT )                               // add dynamic states viewport
        .addDynamicState( VK_DYNAMIC_STATE_SCISSOR )                                // add dynamic states scissor
        .addDescriptorSetLayout( vd.descriptor.descriptor_set_layout )              // describe pipeline layout
    //  .addPushConstantRange( VK_SHADER_STAGE_VERTEX_BIT , 0, 28 )                 // specify push constant range
        .renderPass( vd.render_pass.render_pass )                                   // describe compatible render pass
        .construct( vd.graphics_cache )                                             // construct the Pipleine Layout and Pipleine State Object (PSO) with a Pipeline Cache
        .destroyShaderModules                                                       // shader modules compiled into pipeline, not shared, can be deleted now
        .reset;                                                                     // extract core data into Core_Pipeline struct

}



void destroyParticles( ref VDrive_State vd ) {

    vd.destroy( vd.comp_part_pso );
    vd.destroy( vd.draw_part_pso );
    vd.destroy( vd.sim_particle_buffer_view );
    vd.sim_particle_buffer.destroyResources;

}