module resources;

import erupted;

import vdrive;
import appstate;

import dlsl.matrix;




/// create resources and vulkan objects for rendering
auto ref createCommandObjects( ref VDrive_State vd, VkCommandPoolCreateFlags command_pool_create_flags = 0 ) {

    //////////////////////////
    // create command pools //
    //////////////////////////

    // one to process and display graphics, this one is rest on window resize events
    vd.cmd_pool = vd.createCommandPool( vd.graphics_queue_family_index, command_pool_create_flags );

    // one for compute operations, not reset on window resize events
    vd.sim_cmd_pool = vd.createCommandPool( vd.graphics_queue_family_index );



    /////////////////////////////////
    // create fence and semaphores //
    /////////////////////////////////

    // must create all fences as we don't know the swapchain image count yet
    // but we also don't want to recreate fences in window resize events and keep track how many exist
    foreach( ref fence; vd.submit_fence )
        fence = vd.createFence( VK_FENCE_CREATE_SIGNALED_BIT ); // fence to sync CPU and GPU once per frame


    // rendering and presenting semaphores for VkSubmitInfo, VkPresentInfoKHR and vkAcquireNextImageKHR
    vd.acquired_semaphore = vd.createSemaphore;    // signaled when a new swapchain image is acquired
    vd.rendered_semaphore = vd.createSemaphore;    // signaled when submitted command buffer(s) complete execution



    /////////////////////////////////////
    // configure submit and present infos
    /////////////////////////////////////

    // draw submit info for vkQueueSubmit
    with( vd.submit_info ) {
        waitSemaphoreCount      = 1;
        pWaitSemaphores         = &vd.acquired_semaphore;
        pWaitDstStageMask       = &vd.submit_wait_stage_mask;   // configured before entering createResources func
        commandBufferCount      = 1;
    //  pCommandBuffers         = &vd.cmd_buffers[ i ];         // set before submission, choosing cmd_buffers[0/1]
        signalSemaphoreCount    = 1;
        pSignalSemaphores       = &vd.rendered_semaphore;
    }

    // initialize present info for vkQueuePresentKHR
    with( vd.present_info ) {
        waitSemaphoreCount      = 1;
        pWaitSemaphores         = &vd.rendered_semaphore;
        swapchainCount          = 1;
        pSwapchains             = &vd.swapchain.swapchain;
    //  pImageIndices           = &next_image_index;            // set before presentation, using the acquired next_image_index
    //  pResults                = null;                         // per swapchain prsentation results, redundant when using only one swapchain
    }

    return vd;
}



/// create static memory resources which will be referenced in descriptor set
/// the corresponding createDescriptorSet function might be overwritten somewhere else
auto ref createMemoryObjects( ref VDrive_State vd ) {

    //////////////////////////////////////////
    // create uniform buffers - called once //
    //////////////////////////////////////////

    // create transformation ubo buffer withour memory backing
    import dlsl.matrix;
    vd.xform_ubo_buffer( vd )
        .create( VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, VDrive_State.XForm_UBO.sizeof );


    // create compute ubo buffer without memory backing
    vd.compute_ubo_buffer( vd )
        .create( VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, VDrive_State.Compute_UBO.sizeof );


    // create display ubo buffer without memory backing
    vd.display_ubo_buffer( vd )
        .create( VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, VDrive_State.Display_UBO.sizeof );


    // create host visible memory for ubo buffers and map it
    auto mapped_memory = vd.host_visible_memory( vd )
        .memoryType( VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT )
        .addRange( vd.xform_ubo_buffer )
        .addRange( vd.compute_ubo_buffer )
        .addRange( vd.display_ubo_buffer )
        .allocate
        .bind( vd.xform_ubo_buffer )
        .bind( vd.compute_ubo_buffer )
        .bind( vd.display_ubo_buffer )
        .mapMemory;                         // map the memory object persistently


    // cast the mapped memory pointer without offset into our transformation matrix
    vd.xform_ubo = cast( VDrive_State.XForm_UBO* )mapped_memory;                       // cast to mat4
    vd.xform_ubo_flush = vd.xform_ubo_buffer.createMappedMemoryRange; // specify mapped memory range for the wvpm ubo
    vd.updateProjection;    // update projection matrix from member data _fovy, _near, _far and aspect of the swapchain extent
    vd.updateWVPM;          // multiply projection with trackball (view) matrix and upload to uniform buffer


    // cast the mapped memory pointer with its offset into the backing memory to our compute ubo struct and init_pso the memory
    vd.compute_ubo = cast( VDrive_State.Compute_UBO* )( mapped_memory + vd.compute_ubo_buffer.memOffset );
    vd.compute_ubo_flush = vd.compute_ubo_buffer.createMappedMemoryRange; // specify mapped memory range for the compute ubo
    vd.compute_ubo.collision_frequency = 0.8; //2;
    vd.compute_ubo.wall_velocity = /*0.001*/ 0.02 * 3;// / vd.sim_speed_of_sound / vd.sim_speed_of_sound;
    vd.updateComputeUBO;


    // cast the mapped memory pointer with its offset into the backing memory to our display ubo struct and init_pso the memory
    vd.display_ubo = cast( VDrive_State.Display_UBO* )( mapped_memory + vd.display_ubo_buffer.memOffset );
    vd.display_ubo_flush = vd.display_ubo_buffer.createMappedMemoryRange; // specify mapped memory range for the display ubo
    vd.display_ubo.display_property = 3;
    vd.display_ubo.amplify_property = 1;
    vd.display_ubo.color_layers = 0;
    vd.updateDisplayUBO;



    /////////////////////////////////////////////////////////////
    // create simulation memory objects - called several times //
    /////////////////////////////////////////////////////////////

    return vd.createSimMemoryObjects;
}



/// create or recreate simulation buffer
auto ref createSimBuffer( ref VDrive_State vd ) {

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

    return vd;
}



/// create or recreate simulation images
auto ref createSimImage( ref VDrive_State vd ) {

    // 1) (re)create Image
    if( vd.sim_image.image != VK_NULL_HANDLE ) {
        vd.graphics_queue.vkQueueWaitIdle;
        vd.sim_image.destroyResources( false );  // destroy old image and its view, keeping the sampler
    }

    // Todo(pp): the format should be choose-able
    // Todo(pp): here checks are required if this image format is available for VK_IMAGE_USAGE_STORAGE_BIT
    auto image_format = VK_FORMAT_R32G32_SFLOAT; //VK_FORMAT_R16G16B16A16_SFLOAT
    vd.sim_image( vd )
        .create(
            image_format,
            vd.sim_domain[0], vd.sim_domain[1], vd.sim_use_3_dim ? vd.sim_domain[1] : 0,    // through the 0 we request a VK_IMAGE_TYPE_2D
            1, 1, // mip levels and array layers
            VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_STORAGE_BIT,
            VK_SAMPLE_COUNT_1_BIT,
            GREG ? VK_IMAGE_TILING_OPTIMAL : VK_IMAGE_TILING_LINEAR
            )
        .createMemory( GREG ? VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT : VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT )   // Todo(pp): check which memory property is required for the image format
        .createView;


    // 6.) transition VkImage from layout VK_IMAGE_LAYOUT_UNDEFINED into layout VK_IMAGE_LAYOUT_GENERAL for compute shader access
    auto init_cmd_buffer = vd.allocateCommandBuffer( vd.cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY );
    auto init_cmd_buffer_bi = createCmdBufferBI( VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT );
    init_cmd_buffer.vkBeginCommandBuffer( &init_cmd_buffer_bi );

    // record image layout transition to VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
    init_cmd_buffer.recordTransition(
        vd.sim_image.image,
        vd.sim_image.subresourceRange,
        VK_IMAGE_LAYOUT_UNDEFINED,
        VK_IMAGE_LAYOUT_GENERAL,
        0,  // no access mask required here
        VK_ACCESS_SHADER_WRITE_BIT,
        VK_PIPELINE_STAGE_HOST_BIT,
        VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT );

    init_cmd_buffer.vkEndCommandBuffer;                     // finish recording and submit the command
    auto submit_info = init_cmd_buffer.queueSubmitInfo;     // submit the command buffer
    vd.graphics_queue.vkQueueSubmit( 1, &submit_info, VK_NULL_HANDLE ).vkAssert;

    // map the image after the layout transition, according to validation layers
    // only GENERAL or PREINITIALIZED layouts should be used for memory mapping
    if( !GREG )
        vd.sim_image_ptr = cast( float* )vd.sim_image.mapMemory;


    return vd;
}



enum GREG = false;

/// create or recreate simulation memory, buffers and images
auto ref createSimMemoryObjects( ref VDrive_State vd ) {

    // 1.) (re)create Image, Buffer (and the buffer view) without memory backing
    // 2.) check if the memory requirement for the objects above has increased, if not goto 4.) - this does not work currently ...
    // 3.) if it has recreate the memory object - ... as memory can be bound only once, skipping step 2.) but delete memory if it exist
    // 4.) (re)register resources
    // 5.) (re)create VkImageView and VkBufferView(s)
    // 6.) transition VkImage from layout VK_IMAGE_LAYOUT_UNDEFINED into layout VK_IMAGE_LAYOUT_GENERAL for compute shader access

    return vd
        .createParticleBuffer
        .createSimBuffer
        .createSimImage;

}



// configure descriptor set with required descriptors
// the descriptor set will be constructed in createRenderRecources
// immediately before creating the first pipeline so that additional
// descriptors can be added through other means before finalizing
// maybe we even might overwrite it completely in a parent struct
auto ref createDescriptorSet( ref VDrive_State vd, Meta_Descriptor* meta_descriptor_ptr = null ) {

    ///////////////////////////
    // create descriptor set //
    ///////////////////////////


    // this is required if no Meta Descriptor has been passed in from the outside
    Meta_Descriptor meta_descriptor = vd;
    if( meta_descriptor_ptr is null ) {
        meta_descriptor_ptr = & meta_descriptor;
    }


    vd.sim_image.sampler = vd.createSampler; //( VK_FILTER_LINEAR, VK_FILTER_LINEAR, VK_SAMPLER_MIPMAP_MODE_NEAREST, VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT, VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT );

    // Note(pp): immutable does not filter properly, either driver bug or module descriptor bug
    // Todo(pp): debug the issue
    vd.descriptor = ( *meta_descriptor_ptr )    // VDrive_State.descriptor is a Core_Descriptor
        .addLayoutBinding( 0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, VK_SHADER_STAGE_VERTEX_BIT )
        .addBufferInfo( vd.xform_ubo_buffer.buffer )

        .addLayoutBinding( 2, VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, VK_SHADER_STAGE_COMPUTE_BIT )
        .addTexelBufferView( vd.sim_buffer_view )

        .addLayoutBinding( 3, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, VK_SHADER_STAGE_COMPUTE_BIT )
        .addImageInfo( vd.sim_image.image_view, VK_IMAGE_LAYOUT_GENERAL )

        .addLayoutBinding/*Immutable*/( 4, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT | VK_SHADER_STAGE_COMPUTE_BIT )
        .addImageInfo( vd.sim_image.image_view, VK_IMAGE_LAYOUT_GENERAL, vd.sim_image.sampler )

        .addLayoutBinding( 5, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, VK_SHADER_STAGE_COMPUTE_BIT )
        .addBufferInfo( vd.compute_ubo_buffer.buffer )

        .addLayoutBinding( 6, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, VK_SHADER_STAGE_FRAGMENT_BIT )
        .addBufferInfo( vd.display_ubo_buffer.buffer )

        .construct
        .reset;

    // prepare simulation data descriptor update
    // necessary when we recreate resources and have to rebind them to our descriptors
    vd.sim_descriptor_update( vd )
        .addBindingUpdate( 2, VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER )
        .addTexelBufferView( vd.sim_buffer_view )

        .addBindingUpdate( 3, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE )
        .addImageInfo( vd.sim_image.image_view, VK_IMAGE_LAYOUT_GENERAL )

        .addBindingUpdate/*Immutable*/( 4, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER ) // immutable does not filter properly, either driver bug or module descriptor bug
        .addImageInfo( vd.sim_image.image_view, VK_IMAGE_LAYOUT_GENERAL, vd.sim_image.sampler )


        .attachSet( vd.descriptor.descriptor_set );



}


auto ref updateDescriptorSet( ref VDrive_State vd ) {

    //vd.graphics_queue.vkQueueWaitIdle;

    // update the descriptor
    vd.sim_descriptor_update.texel_buffer_views[0]    = vd.sim_buffer_view;             // populations buffer and optionally other data like temperature
    vd.sim_descriptor_update.texel_buffer_views[1]    = vd.sim_particle_buffer_view;    // particles to visualize LBM velocity
    vd.sim_descriptor_update.image_infos[0].imageView = vd.sim_image.image_view;        // image view for writing from compute shader
    vd.sim_descriptor_update.image_infos[1].imageView = vd.sim_image.image_view;        // image view for reading in display fragment shader with linear sampling
    vd.sim_descriptor_update.update;

    // Note(pp):
    // it would be more efficient to create another descriptor update for the sim_buffer_particle_view
    // it will most likely not be updated with the other resources and vice versa
    // but ... what the heck ... for now ... we won't update both of them often enough

    return vd;
}




auto ref createGraphicsPipeline( ref VDrive_State vd ) {

    // if we are recreating an old pipeline exists already, destroy it first
    if( vd.graphics_pso.pipeline != VK_NULL_HANDLE ) {
        vd.graphics_queue.vkQueueWaitIdle;
        vd.destroy( vd.graphics_pso );
    }



    //////////////////////////////
    // create graphics pipeline //
    //////////////////////////////

    Meta_Graphics meta_graphics;
    vd.graphics_pso = meta_graphics( vd )
        .addShaderStageCreateInfo( vd.createPipelineShaderStage( VK_SHADER_STAGE_VERTEX_BIT,   "shader/lbmd_draw.vert" ))
        .addShaderStageCreateInfo( vd.createPipelineShaderStage( VK_SHADER_STAGE_FRAGMENT_BIT, "shader/lbmd_draw.frag" ))
        .inputAssembly( VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP )                      // set the inputAssembly
        .addViewportAndScissors( VkOffset2D( 0, 0 ), vd.swapchain.imageExtent )     // add viewport and scissor state, necessary even if we use dynamic state
        .cullMode( VK_CULL_MODE_BACK_BIT )                                          // set rasterization state
        .depthState                                                                 // set depth state - enable depth test with default attributes
        .addColorBlendState( VK_FALSE )                                             // color blend state - append common (default) color blend attachment state
        .addDynamicState( VK_DYNAMIC_STATE_VIEWPORT )                               // add dynamic states viewport
        .addDynamicState( VK_DYNAMIC_STATE_SCISSOR )                                // add dynamic states scissor
        .addDescriptorSetLayout( vd.descriptor.descriptor_set_layout )              // describe pipeline layout
        .addPushConstantRange( VK_SHADER_STAGE_VERTEX_BIT , 0, 8 )                  // specify push constant range
        .renderPass( vd.render_pass.render_pass )                                   // describe compatible render pass
        .construct( vd.graphics_cache )                                             // construct the Pipleine Layout and Pipleine State Object (PSO) with a Pipeline Cache
        .destroyShaderModules                                                       // shader modules compiled into pipeline, not shared, can be deleted now
        .reset;                                                                     // extract core data into Core_Pipeline struct

    return vd;
}




auto ref createRenderResources( ref VDrive_State vd ) {

    /////////////////////////////////////////////////////////
    // select swapchain image format and presentation mode //
    /////////////////////////////////////////////////////////

    // Note: to get GPU swapchain capabilities to check for possible image usages
    //VkSurfaceCapabilitiesKHR surface_capabilities;
    //vkGetPhysicalDeviceSurfaceCapabilitiesKHR( swapchain.gpu, swapchain.swapchain, &surface_capabilities );
    //surface_capabilities.printTypeInfo;

    // we need to know the swapchain image format before we create a render pass
    // to render into that swapcahin image. We don't have to create the swapchain itself
    // renderpass needs to be created only once in contrary to the swapchain, which must be
    // recreated if the window swapchain size changes
    // We set all required parameters here to avoid configuration at multiple locations
    // additionally configuration needs to happen only once

    // list of prefered formats and modes, the first found will be used, otherwise the first available not in lists
    VkFormat[4] request_format = [ VK_FORMAT_R8G8B8_UNORM, VK_FORMAT_B8G8R8_UNORM, VK_FORMAT_R8G8B8A8_UNORM, VK_FORMAT_B8G8R8A8_UNORM ];
    VkPresentModeKHR[3] request_mode = [ VK_PRESENT_MODE_IMMEDIATE_KHR, VK_PRESENT_MODE_MAILBOX_KHR, VK_PRESENT_MODE_FIFO_KHR ];
    //VkPresentModeKHR[2] request_mode = [ VK_PRESENT_MODE_MAILBOX_KHR, VK_PRESENT_MODE_FIFO_KHR ];


    vd.swapchain( vd )
        .selectSurfaceFormat( request_format )
        .selectPresentMode( request_mode )
        .minImageCount( 2 ) // MAX_FRAMES
        .imageArrayLayers( 1 )
        .imageUsage( VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT );
        // delay .construct; call to finalize in a later step



    ////////////////////////
    // create render pass //
    ////////////////////////

    vd.render_pass( vd )
        .renderPassAttachment_Clear_None(  vd.depth_image_format,  vd.sample_count, VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL ).subpassRefDepthStencil
        .renderPassAttachment_Clear_Store( vd.swapchain.imageFormat, vd.sample_count, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR ).subpassRefColor( VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL )

        // Note: specify dependencies despite of only one subpass, as suggested by:
        // https://software.intel.com/en-us/articles/api-without-secrets-introduction-to-vulkan-part-4#
        .addDependencyByRegion
        .srcDependency( VK_SUBPASS_EXTERNAL, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT         , VK_ACCESS_MEMORY_READ_BIT )
        .dstDependency( 0                  , VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT )
        .addDependencyByRegion
        .srcDependency( 0                  , VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT )
        .dstDependency( VK_SUBPASS_EXTERNAL, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT         , VK_ACCESS_MEMORY_READ_BIT )
        .construct;



    //////////////////////////////////////////////////////////////////
    // create pipeline cache for the graphics and compute pipelines //
    //////////////////////////////////////////////////////////////////

    vd.graphics_cache   = vd.createPipelineCache;   // create once, but will be used several times in createGRaphicsPipeline
    vd.compute_cache    = vd.createPipelineCache;   // Todo(pp): move this into createComputeResources and extract createComputePipeline from it


    // create the graphics pipeline, can be called multiple time to parse shader at runtime
    vd.createGraphicsPipeline;

    // create all resources for the compute pipeline
    return vd.createComputeResources;
}



auto ref createComputeResources( ref VDrive_State vd ) {

    /////////////////////////////
    // create compute pipeline //
    /////////////////////////////

    //Meta_Specialization meta_sc;
    Meta_SC!( 2 ) meta_sc;
    meta_sc
        .addMapEntry( MapEntry32( vd.sim_work_group_size_x ))   // default constantID is 0, next would be 1
        .addMapEntry( MapEntry32( 1 + 255 ), 3 )                // latter is the constantID, must be passed in, otherwise its 1
        .construct;


    // create initial compute pso with specialization, if we are recreating we r
    Meta_Compute meta_compute;
    void createComputePSO() {
        vd.graphics_queue.vkQueueWaitIdle;  // wait for queue idle as we need to destroy the pipeline
        auto old_pso = vd.compute_pso;      // store old pipeline to improve new pipeline construction speed
        vd.compute_pso = meta_compute( vd )
            //.basePipeline( old_pso.pipeline )
            .shaderStageCreateInfo(
                vd.createPipelineShaderStage(
                    VK_SHADER_STAGE_COMPUTE_BIT,
                    USE_DOUBLE ? "shader/lbmd_loop_double.comp" : "shader/lbmd_loop.comp",
                    & meta_sc.specialization_info ))
            .addDescriptorSetLayout( vd.descriptor.descriptor_set_layout )
            .addPushConstantRange( VK_SHADER_STAGE_COMPUTE_BIT, 0, 4 )
            .construct( vd.compute_cache )  // construct using pipeline cache
            .destroyShaderModule
            .reset;

        // destroy old compute pipeline and layout
        if( old_pso.pipeline != VK_NULL_HANDLE )
            vd.destroy( old_pso );
    }

    createComputePSO();

    //////////////////////////////////////////////////
    // initialize populations with compute pipeline //
    //////////////////////////////////////////////////

    auto init_cmd_buffer = vd.allocateCommandBuffer( vd.cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY );
    auto init_cmd_buffer_bi = commandBufferBeginInfo( VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT );
    init_cmd_buffer.vkBeginCommandBuffer( &init_cmd_buffer_bi );
    // determine dispatch group X count from simulation domain vd.sim_domain and compute work group size vd.sim_work_group_size_x
    uint32_t dispatch_x = vd.sim_domain[0] * vd.sim_domain[1] * vd.sim_domain[2] / vd.sim_work_group_size_x;

    init_cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_COMPUTE, vd.compute_pso.pipeline );   // bind compute vd.compute_pso
    init_cmd_buffer.vkCmdBindDescriptorSets(// VkCommandBuffer              commandBuffer           // bind descriptor set
        VK_PIPELINE_BIND_POINT_COMPUTE,     // VkPipelineBindPoint          pipelineBindPoint
        vd.compute_pso.pipeline_layout,     // VkPipelineLayout             layout
        0,                                  // uint32_t                     firstSet
        1,                                  // uint32_t                     descriptorSetCount
        &vd.descriptor.descriptor_set,      // const( VkDescriptorSet )*    pDescriptorSets
        0,                                  // uint32_t                     dynamicOffsetCount
        null                                // const( uint32_t )*           pDynamicOffsets
    );

    init_cmd_buffer.vkCmdDispatch( dispatch_x, 1, 1 );      // dispatch compute command, forwards to vkCmdDispatch( cmd_buffer, dispatch_group_count.x, dispatch_group_count.y, dispatch_group_count.z );
    init_cmd_buffer.vkEndCommandBuffer;                     // finish recording and submit the command
    auto submit_info = init_cmd_buffer.queueSubmitInfo;     // submit the command buffer
    vd.graphics_queue.vkQueueSubmit( 1, &submit_info, VK_NULL_HANDLE ).vkAssert;



    ////////////////////////////////////////////////
    // recreate compute pipeline for runtime loop //
    ////////////////////////////////////////////////

    // reuse meta_compute to create loop compute pso with collision algorithm specialization
    meta_sc.specialization_data[1] = MapEntry32( vd.sim_algorithm );    // all settings higher 0 are loop algorithms
    createComputePSO;                                                   // reuse code from above



    /////////////////////////////////////////////////
    // create two reusable compute command buffers //
    /////////////////////////////////////////////////

    // two command buffers for compute loop, one ping and one pong buffer
    vd.allocateCommandBuffers( vd.sim_cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, vd.sim_cmd_buffers );
    auto sim_cmd_buffers_bi = commandBufferBeginInfo;

    // record commands in loop, only difference is the push constant
    foreach( i, ref cmd_buffer; vd.sim_cmd_buffers ) {
        uint push_constant = ( i * vd.sim_ping_pong_scale ).toUint;
        cmd_buffer.vkBeginCommandBuffer( &sim_cmd_buffers_bi );  // begin command buffer recording
        cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_COMPUTE, vd.compute_pso.pipeline );    // bind compute vd.compute_pso.pipeline
        cmd_buffer.vkCmdBindDescriptorSets(     // VkCommandBuffer              commandBuffer
            VK_PIPELINE_BIND_POINT_COMPUTE,     // VkPipelineBindPoint          pipelineBindPoint
            vd.compute_pso.pipeline_layout,     // VkPipelineLayout             layout
            0,                                  // uint32_t                     firstSet
            1,                                  // uint32_t                     descriptorSetCount
            &vd.descriptor.descriptor_set,      // const( VkDescriptorSet )*    pDescriptorSets
            0,                                  // uint32_t                     dynamicOffsetCount
            null                                // const( uint32_t )*           pDynamicOffsets
        );
        cmd_buffer.vkCmdPushConstants( vd.compute_pso.pipeline_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, 4, &push_constant ); // push constant
        cmd_buffer.vkCmdDispatch( dispatch_x, 1, 1 );       // dispatch compute command, forwards to vkCmdDispatch( cmd_buffer, dispatch_group_count.x, dispatch_group_count.y, dispatch_group_count.z );
        cmd_buffer.vkEndCommandBuffer;                      // finish recording and submit the command
    }

    // initialize ping pong variable to 1
    // it will be switched to 0 ( pp = 1 - pp ) befor submitting compute commands
    vd.sim_ping_pong = 1;

    return vd;
}




auto ref resizeRenderResources( ref VDrive_State vd ) {

    //////////////////////////////////////////////////////
    // (re)construct the already parametrized swapchain //
    //////////////////////////////////////////////////////

    vd.swapchain.construct;

    // set the corresponding present info member to the (re)constructed swapchain
    vd.present_info.pSwapchains = &vd.swapchain.swapchain;



    ////////////////////////
    // create depth image //
    ////////////////////////


    // prefer getting the depth image into a device local heap
    // first we need to find out if such a heap exist on the current device
    // we do not check the size of the heap, the depth image will probably fit if such heap exists
    // Todo(pp): the assumption above is NOT guaranteed, add additional functions to memory module
    // which consider a minimum heap size for the memory type, heap as well as memory cretaion functions
    // Todo(pp): this should be a member of VDrive_State and figured out only once
    // including the proper memory heap index
    auto depth_image_memory_property = vd.memory_properties.hasMemoryHeapType( VK_MEMORY_HEAP_DEVICE_LOCAL_BIT )
        ? VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT
        : VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT;

    // vd.depth_image_format can be set before this function gets called
    vd.depth_image( vd )
        .create( vd.depth_image_format, vd.windowWidth, vd.windowHeight, VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT, vd.sample_count )
        .createMemory( depth_image_memory_property )
        .createView( VK_IMAGE_ASPECT_DEPTH_BIT );



    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // record ransition of depth image from VK_IMAGE_LAYOUT_UNDEFINED to VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL //
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    // Note: allocate one command buffer
    // cmd_buffer is an Array!VkCommandBuffer
    // the array itself will be destroyd after this scope
    auto cmd_buffer = vd.allocateCommandBuffer( vd.cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY );

    VkCommandBufferBeginInfo cmd_buffer_begin_info = {
        flags : VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, };
    vkBeginCommandBuffer( cmd_buffer, &cmd_buffer_begin_info );

    cmd_buffer.recordTransition(
        vd.depth_image.image,
        vd.depth_image.image_view_create_info.subresourceRange,
        VK_IMAGE_LAYOUT_UNDEFINED,
        VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        0,  // no access mask required here
        VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
    );

    // finish recording
    cmd_buffer.vkEndCommandBuffer;

    // submit the command buffer
    auto submit_info = cmd_buffer.queueSubmitInfo;
    vd.graphics_queue.vkQueueSubmit( 1, &submit_info, VK_NULL_HANDLE ).vkAssert;




    /////////////////////////
    // create framebuffers //
    /////////////////////////

    VkImageView[1] render_targets = [ vd.depth_image.image_view ];  // compose render targets into an array
    vd.framebuffers( vd )
        .initFramebuffers!(
            typeof( vd.framebuffers ),
            vd.framebuffers.fb_count + render_targets.length.toUint
            )(
            vd.render_pass.render_pass,                 // specify render pass COMPATIBILITY
            vd.swapchain.imageExtent,                   // extent of the framebuffer
            render_targets,                             // first ( static ) attachments which will not change ( here only )
            vd.swapchain.present_image_views.data,      // next one dynamic attachment ( swapchain ) which changes per command buffer
            [], false );                                // if we are recreating we do not want to destroy clear values ...

    // ... we should keep the clear values, they might have been edited by the gui
    if( vd.framebuffers.clear_values.empty )
        vd.framebuffers
            .addClearValue( 1.0f )                      // add depth clear value
            .addClearValue( 0.3f, 0.3f, 0.3f, 1.0f );   // add color clear value

    // attach one of the framebuffers, the render area and clear values to the render pass begin info
    // Note: attaching the framebuffer also sets the clear values and render area extent into the render pass begin info
    // setting clear values corresponding to framebuffer attachments and framebuffer extent could have happend before, e.g.:
    //      vd.render_pass.clearValues( some_clear_values );
    //      vd.render_pass.begin_info.renderArea = some_render_area;
    // but meta framebuffer(s) has a member for them, hence no need to create and manage extra storage/variables
    vd.render_pass.attachFramebuffer( vd.framebuffers, 0 );



    ///////////////////////////////////////////////
    // update dynamic viewport and scissor state //
    ///////////////////////////////////////////////

    vd.viewport = VkViewport( 0, 0, vd.swapchain.imageExtent.width, vd.swapchain.imageExtent.height, 0, 1 );
    vd.scissors = VkRect2D( VkOffset2D( 0, 0 ), vd.swapchain.imageExtent );

    return vd;
}



///////////////////////////////////
// (re)create draw loop commands //
///////////////////////////////////
auto ref createResizedCommands( ref VDrive_State vd ) nothrow {

    // reset the command pool to start recording drawing commands
    vd.graphics_queue.vkQueueWaitIdle;   // equivalent using a fence per Spec v1.0.48
    vd.device.vkResetCommandPool( vd.cmd_pool, 0 ); // second argument is VkCommandPoolResetFlags


    // if we know how many command buffers are required we can use this static array function
    vd.allocateCommandBuffers( vd.cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, vd.cmd_buffers[ 0 .. vd.swapchain.imageCount ] );


    // draw command buffer begin info for vkBeginCommandBuffer, can be used in any command buffer
    VkCommandBufferBeginInfo cmd_buffer_begin_info;


    // record command buffer for each swapchain image
    foreach( uint32_t i, ref cmd_buffer; vd.cmd_buffers[ 0 .. vd.swapchain.imageCount ] ) {    // remove .data if using static array

        // attach one of the framebuffers to the render pass
        vd.render_pass.attachFramebuffer( vd.framebuffers( i ));

        // begin command buffer recording
        cmd_buffer.vkBeginCommandBuffer( &cmd_buffer_begin_info );

        // begin the render_pass
        cmd_buffer.vkCmdBeginRenderPass( &vd.render_pass.begin_info, VK_SUBPASS_CONTENTS_INLINE );

        // take care of dynamic state
        cmd_buffer.vkCmdSetViewport( 0, 1, &vd.viewport );
        cmd_buffer.vkCmdSetScissor(  0, 1, &vd.scissors );

        // bind descriptor set
        cmd_buffer.vkCmdBindDescriptorSets(     // VkCommandBuffer              commandBuffer
            VK_PIPELINE_BIND_POINT_GRAPHICS,    // VkPipelineBindPoint          pipelineBindPoint
            vd.graphics_pso.pipeline_layout,    // VkPipelineLayout             layout
            0,                                  // uint32_t                     firstSet
            1,                                  // uint32_t                     descriptorSetCount
            &vd.descriptor.descriptor_set,      // const( VkDescriptorSet )*    pDescriptorSets
            0,                                  // uint32_t                     dynamicOffsetCount
            null                                // const( uint32_t )*           pDynamicOffsets
        );

        // bind graphics vd.geom_pipeline
        cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_GRAPHICS, vd.graphics_pso.pipeline );

        // push constant the sim display scale
        auto sim_display_scale = vd.simDisplayScale( 2 ); 
        cmd_buffer.vkCmdPushConstants( vd.graphics_pso.pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, 2 * float.sizeof, sim_display_scale.ptr );

        // buffer-less draw with build in gl_VertexIndex exclusively to generate position and texcoord data
        cmd_buffer.vkCmdDraw( 4, 1, 0, 0 ); // vertex count ,instance count ,first vertex ,first instance

        // end the render pass
        cmd_buffer.vkCmdEndRenderPass;

        // end command buffer recording
        cmd_buffer.vkEndCommandBuffer;
    }

    return vd;
}




auto ref destroyResources( ref VDrive_State vd ) {

    import erupted, vdrive;

    vd.device.vkDeviceWaitIdle;

    // swapchain, swapchain and present image views
    vd.swapchain.destroyResources;

    // memory Resources
    vd.depth_image.destroyResources;
    vd.wvpm_ubo_buffer.destroyResources;
    vd.compute_ubo_buffer.destroyResources;
    vd.display_ubo_buffer.destroyResources;
    vd.host_visible_memory.unmapMemory.destroyResources;

    // compute resources
    vd.destroy( vd.sim_buffer_view );
    vd.sim_image.destroyResources;
    vd.sim_buffer.destroyResources;
    if( vd.sim_memory.memory != VK_NULL_HANDLE )
        vd.sim_memory.destroyResources;

    // render setup
    vd.render_pass.destroyResources;
    vd.framebuffers.destroyResources;
    vd.destroy( vd.descriptor );
    vd.destroy( vd.graphics_pso );
    vd.destroy( vd.compute_pso );
    vd.destroy( vd.graphics_cache );
    vd.destroy( vd.compute_cache );

    // command and synchronize
    vd.destroy( vd.cmd_pool );
    vd.destroy( vd.sim_cmd_pool );
    vd.destroy( vd.acquired_semaphore );
    vd.destroy( vd.rendered_semaphore );
    foreach( ref fence; vd.submit_fence )
        vd.destroy( fence );

    return vd;
}

