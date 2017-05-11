module resources;

import erupted;
import derelict.glfw3;

//import std.stdio;

import appstate;

import vdrive.util.info;
import vdrive.util.util;
import vdrive.util.array;



// Todo(pp): @nogc nothrow:

auto ref createSwapchain( ref VDrive_State vd ) {

    //////////////////////////////////////////////////
    // create a swapchain for render result display //
    //////////////////////////////////////////////////

    import vdrive.surface;
    vd.surface.construct;

    // set the corresponding present info member to the (re)constructed swapchain
    vd.present_info.pSwapchains = &vd.surface.swapchain;

    return vd;
}



// create resources and vulkan objects for rendering
auto ref createCommandObjects( ref VDrive_State vd, VkCommandPoolCreateFlags command_pool_create_flags = 0 ) {

    //////////////////////////
    // create command pools //
    //////////////////////////

    import vdrive.command;
    // one to process and display graphics, this one is rest on window resize events
    vd.cmd_pool = vd.createCommandPool( vd.graphics_queue_family_index, command_pool_create_flags );

    // one for compute operations, not reset on window resize events
    vd.compute_cmd_pool = vd.createCommandPool( vd.graphics_queue_family_index );



    /////////////////////////////////
    // create fence and semaphores //
    /////////////////////////////////

    // must create all fences as we don't know the swapchain image count yet
    // but we also don't want to recreate fences in window resize events and keep track how many exist
    import vdrive.synchronize;
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
        waitSemaphoreCount  = 1;
        pWaitSemaphores     = &vd.rendered_semaphore;
        swapchainCount      = 1;
        pSwapchains         = &vd.surface.swapchain;
    //  pImageIndices       = &next_image_index;            // set before presentation, using the acquired next_image_index
    //  pResults            = null;                         // per swapchain prsentation results, redundant when using only one swapchain
    }

    return vd;
}



// create static memory resources which referenced in descriptor set
// the corresponding createDescriptorSet function might be overwritten somewhere else
auto ref createMemoryObjects( ref VDrive_State vd ) {

    //////////////////////////////////
    // create matrix uniform buffer //
    //////////////////////////////////

    import vdrive.memory;
    vd.wvpm_buffer( vd )
        .create( VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, 2 * 16 * float.sizeof )
        .createMemory( VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT );

    // map the uniform buffer memory persistently
    import dlsl.matrix;
    vd.wvpm = cast( mat4* )vd.wvpm_buffer.mapMemory;

    // specify mapped memory range for the matrix uniform buffer
    vd.wvpm_flush.memory    = vd.wvpm_buffer.memory;
    vd.wvpm_flush.size      = vd.wvpm_buffer.memSize;

    // update projection matrix from member data _fovy, _near, _far and aspect of
    // the swapchain extent, initialized once, resized by the input.windowSizeCallback
    // however we can set _fovy, _near, _far to desired values before calling updateProjection
    vd.updateProjection;

    // multiply projection with trackball (view) matrix and upload to uniform buffer
    vd.updateWVPM;


    // For D2Q9 we need 1 + 2 * 8 Shader Storage Buffers with DIM_X * DIM_Y floats each
    // for 512 ^ 2 cells this means ( 1 + 2 * 8 ) * 4 * 512 * 512 = 17_825_792 bytes
    // create one buffer 1 + 2 * 8 buffer views into that buffer
    uint32_t population_mem_size = vd.sim_dim.x * vd.sim_dim.y * float.sizeof.toUint;
    uint32_t buffer_size = ( 1 + 2 * 8 ) * population_mem_size;

    // Todo(pp): here checks are required if this image format is available for VK_IMAGE_USAGE_STORAGE_BIT 
    vd.lbmd_image( vd )
        .create( VK_FORMAT_R16G16B16A16_SFLOAT, vd.sim_dim.x, vd.sim_dim.y, VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_STORAGE_BIT );
        //.createMemory( VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT )
        //.createView;

    vd.lbmd_buffer( vd )
        .create( VK_BUFFER_USAGE_STORAGE_TEXEL_BUFFER_BIT, buffer_size );
        //.createMemory( VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT );

    // share memory
    vd.lbmd_memory( vd )
        .memoryType( VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT )
        .addRange( vd.lbmd_buffer )
        .addRange( vd.lbmd_image )
        .allocate
        .bind( vd.lbmd_buffer )
        .bind( vd.lbmd_image );

    // After we created memory for the image we can create the view
    vd.lbmd_image.createView;

    import vdrive.descriptor : createBufferView;
    foreach( i, ref view; vd.lbmd_buffer_views )
        view = vd.createBufferView(
            vd.lbmd_buffer.buffer,
            VK_FORMAT_R32_SFLOAT,
            i.toUint * population_mem_size,
            population_mem_size );




}



// configure descriptor set with required descriptors
// the descriptor set will be constructed in createRenderRecources
// immediatelly before creating the first pipeline so that additional
// descriptors can be added through other means befor finalizing
// maybe we even might overwrite it completely in a parent struct
import vdrive.descriptor : Meta_Descriptor;
auto ref createDescriptorSet( ref VDrive_State vd, Meta_Descriptor* meta_descriptor_ptr = null ) {

    ///////////////////////////
    // create descriptor set //
    ///////////////////////////

    import vdrive.descriptor;

    // this is required if no Meta Descriptor has been passed in from the outside
    Meta_Descriptor meta_descriptor = vd;
    if( meta_descriptor_ptr is null ) {
        meta_descriptor_ptr = & meta_descriptor;
    }

    vd.lbmd_sampler = vd.createSampler( VK_FILTER_NEAREST, VK_FILTER_NEAREST );

    vd.descriptor = ( *meta_descriptor_ptr )    // VDrive_State.descriptor is a Core_Descriptor
        .addLayoutBinding( 0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, VK_SHADER_STAGE_VERTEX_BIT )
            .addBufferInfo( vd.wvpm_buffer.buffer )
        .addLayoutBinding( 2, VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, VK_SHADER_STAGE_COMPUTE_BIT )
            .addTexelBufferViews( vd.lbmd_buffer_views )
        .addLayoutBinding( 3, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, VK_SHADER_STAGE_COMPUTE_BIT )
            .addImageInfo( vd.lbmd_image.image_view, VK_IMAGE_LAYOUT_GENERAL )
        .addLayoutBinding/*Immutable*/( 4, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, VK_SHADER_STAGE_FRAGMENT_BIT ) // immutable does not filter properly, either driver bug or module descriptor bug
            .addImageInfo( vd.lbmd_image.image_view, VK_IMAGE_LAYOUT_GENERAL, vd.lbmd_sampler )
        .construct
        .reset;
}



auto ref createRenderResources( ref VDrive_State vd ) {

    ////////////////////////////////////////////////////////
    // select swapchain image format and presntation mode //
    ////////////////////////////////////////////////////////

    // Note: to get GPU surface capabilities to check for possible image usages
    //VkSurfaceCapabilitiesKHR surface_capabilities;
    //vkGetPhysicalDeviceSurfaceCapabilitiesKHR( surface.gpu, surface.surface, &surface_capabilities );
    //surface_capabilities.printTypeInfo;

    // we need to know the swapchain image format before we create a render pass
    // to render into that swapcahin image. We don't have to create the swapchain itself
    // renderpass needs to be created only once in contrary to the swapchain, which must be
    // recreated if the window surface size changes
    // We set all required parameters here to avoid configuration at multiple locations
    // additionally configuration needs to happen only once

    // list of prefered formats and modes, the first found will be used, othervise the first available not in lists
    VkFormat[4] request_format = [ VK_FORMAT_R8G8B8_UNORM, VK_FORMAT_B8G8R8_UNORM, VK_FORMAT_R8G8B8A8_UNORM, VK_FORMAT_B8G8R8A8_UNORM ];
    VkPresentModeKHR[3] request_mode = [ VK_PRESENT_MODE_IMMEDIATE_KHR, VK_PRESENT_MODE_MAILBOX_KHR, VK_PRESENT_MODE_FIFO_KHR ];
    //VkPresentModeKHR[2] request_mode = [ VK_PRESENT_MODE_MAILBOX_KHR, VK_PRESENT_MODE_FIFO_KHR ];

    import vdrive.surface;

    vd.surface( vd )
        .selectSurfaceFormat( request_format )
        .selectPresentMode( request_mode )
        .minImageCount( 2 ) // MAX_FRAMES
        .imageArrayLayers( 1 )
        .imageUsage( VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT );
        // delay .construct; call to finalize in a later step




    ////////////////////////
    // create render pass //
    ////////////////////////

    import vdrive.renderbuffer, vdrive.surface;
    vd.render_pass( vd )
        .renderPassAttachment_Clear_None(  vd.depth_image_format,  vd.sample_count, VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL ).subpassRefDepthStencil
        .renderPassAttachment_Clear_Store( vd.surface.imageFormat, vd.sample_count, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR ).subpassRefColor( VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL )

        // Note: specify dependencies despite of only one subpass, as suggested by:
        // https://software.intel.com/en-us/articles/api-without-secrets-introduction-to-vulkan-part-4#
        .addDependencyByRegion
        .srcDependency( VK_SUBPASS_EXTERNAL, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT         , VK_ACCESS_MEMORY_READ_BIT )
        .dstDependency( 0                  , VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT )

        .addDependencyByRegion
        .srcDependency( 0                  , VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT )
        .dstDependency( VK_SUBPASS_EXTERNAL, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT         , VK_ACCESS_MEMORY_READ_BIT )

        .construct;





    //////////////////////////////
    // create graphics pipeline //
    //////////////////////////////

    // add shader stages - git repo needs only to keep track of the shader sources,
    // vdrive will compile them into spir-v with glslangValidator (must be in path!)
    import vdrive.pipeline, vdrive.surface, vdrive.shader;
    Meta_Graphics meta_graphics;
    vd.graphics_pso = meta_graphics( vd )
        .addShaderStageCreateInfo( vd.createPipelineShaderStage( VK_SHADER_STAGE_VERTEX_BIT,   "shader/lbmd_draw.vert" ))
        .addShaderStageCreateInfo( vd.createPipelineShaderStage( VK_SHADER_STAGE_FRAGMENT_BIT, "shader/lbmd_draw.frag" ))
//        .addBindingDescription( 0, 2 * float.sizeof, VK_VERTEX_INPUT_RATE_VERTEX )  // add vertex binding and attribute descriptions
//        .addAttributeDescription( 0, 0, VK_FORMAT_R32G32_SFLOAT, 0 )                // location (per shader), binding (per buffer), type, offset in struct/buffer
        .inputAssembly( VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP )                      // set the inputAssembly
        .addViewportAndScissors( VkOffset2D( 0, 0 ), vd.surface.imageExtent )       // add viewport and scissor state, necessary even if we use dynamic state
        .cullMode( VK_CULL_MODE_BACK_BIT )                                          // set rasterization state
        .depthState                                                                 // set depth state - enable depth test with default attributes
        .addColorBlendState( VK_FALSE )                                             // color blend state - append common (default) color blend attachment state
        .addDynamicState( VK_DYNAMIC_STATE_VIEWPORT )                               // add dynamic states viewport
        .addDynamicState( VK_DYNAMIC_STATE_SCISSOR )                                // add dynamic states scissor
        .addDescriptorSetLayout( vd.descriptor.descriptor_set_layout )              // describe pipeline layout
        .addPushConstantRange( VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 0, 4 )    // specify push constant range
        .renderPass( vd.render_pass.render_pass )                                   // describe compatible render pass
        .construct                                                                  // construct the Pipleine Layout and Pipleine State Object (PSO)
        .destroyShaderModules                                                       // shader modules compiled into pipeline, not shared, can be deleted now
        .reset;                                                                     // extract core data into Core_Pipeline struct


    // specify spetialization constants of compute shader
    VkSpecializationMapEntry specialization_map_entry = {
        constantID  : 0,
        offset      : 0,
        size        : uint32_t.sizeof,
    };

    //uint comp_x = 256;
    VkSpecializationInfo specialization_info = {
        mapEntryCount   : 1,
        pMapEntries     : & specialization_map_entry,
        dataSize        : vd.sim_dim.x.sizeof,
        pData           : vd.sim_dim.ptr,
    };

    // create initial compute pso with specialization
    Meta_Compute meta_compute;
    vd.compute_pso = meta_compute( vd )
        .shaderStageCreateInfo(
            vd.createPipelineShaderStage(
                VK_SHADER_STAGE_COMPUTE_BIT,
                "shader/lbmd_init.comp",
                & specialization_info ))
        .addDescriptorSetLayout( vd.descriptor.descriptor_set_layout )
        .construct
        .destroyShaderModule
        .reset;

    //////////////////////////////////////////////////////////////////////////////////////////////
    // record ransition of lbmd image from VK_IMAGE_LAYOUT_UNDEFINED to VK_IMAGE_LAYOUT_GENERAL //
    //////////////////////////////////////////////////////////////////////////////////////////////


    // use one command buffer for device resource initialization
    import vdrive.command : allocateCommandBuffer, commandBufferBeginInfo;
    auto init_cmd_buffer = vd.allocateCommandBuffer( vd.cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY );
    auto init_cmd_buffer_bi = commandBufferBeginInfo( VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT );
    init_cmd_buffer.vkBeginCommandBuffer( &init_cmd_buffer_bi );

    // record image layout transition to VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
    import vdrive.memory : recordTransition;
    init_cmd_buffer.recordTransition(
        vd.lbmd_image.image,
        vd.lbmd_image.subresourceRange,
        VK_IMAGE_LAYOUT_UNDEFINED,
        VK_IMAGE_LAYOUT_GENERAL,
        0,  // no access mask required here
        VK_ACCESS_SHADER_WRITE_BIT,
        VK_PIPELINE_STAGE_HOST_BIT,
        VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT );



    //////////////////////////////////////////////////
    // initialize populations with compute pipeline //
    //////////////////////////////////////////////////

    // bind compute vd.compute_pso
    init_cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_COMPUTE, vd.compute_pso.pipeline );

    // bind descriptor set
    init_cmd_buffer.vkCmdBindDescriptorSets(// VkCommandBuffer              commandBuffer
        VK_PIPELINE_BIND_POINT_COMPUTE,     // VkPipelineBindPoint          pipelineBindPoint
        vd.compute_pso.pipeline_layout,     // VkPipelineLayout             layout
        0,                                  // uint32_t                     firstSet
        1,                                  // uint32_t                     descriptorSetCount
        &vd.descriptor.descriptor_set,      // const( VkDescriptorSet )*    pDescriptorSets
        0,                                  // uint32_t                     dynamicOffsetCount
        null                                // const( uint32_t )*           pDynamicOffsets
    );

    // dispatch compute command
    init_cmd_buffer.vkCmdDispatch( 1, vd.sim_dim.y, 1 );

    // finish recording and submit the command
    init_cmd_buffer.vkEndCommandBuffer;

    // submit the command buffer and wait for queue idle as we need to destroy the pipeline
    import vdrive.command : queueSubmitInfo;
    auto submit_info = init_cmd_buffer.queueSubmitInfo;
    vd.graphics_queue.vkQueueSubmit( 1, &submit_info, VK_NULL_HANDLE ).vkAssert;
    vd.graphics_queue.vkQueueWaitIdle;



    ////////////////////////////////////////////////
    // recreate compute pipeline for runtime loop //
    ////////////////////////////////////////////////

    // reuse meta_compute to create loop compute pso with specialization
    auto old_pso = vd.compute_pso;
    vd.compute_pso = meta_compute( vd )
        .shaderStageCreateInfo(
            vd.createPipelineShaderStage(
                VK_SHADER_STAGE_COMPUTE_BIT,
                "shader/lbmd_loop.comp",
                & specialization_info ))
        .addDescriptorSetLayout( vd.descriptor.descriptor_set_layout )
        .addPushConstantRange( VK_SHADER_STAGE_COMPUTE_BIT, 0, 4 )
        .basePipeline( old_pso.pipeline )
        .construct
        .destroyShaderModule
        .reset;

    // destroy old compute pipeline and layout
    vd.destroy( old_pso );



    //////////////////////////////////////////////////
    // create two reusable commpute command buffers //
    //////////////////////////////////////////////////

    // two command buffers for compute loop, one ping and one pong buffer
    import vdrive.command : allocateCommandBuffers;
    vd.allocateCommandBuffers( vd.compute_cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, vd.compute_cmd_buffers );
    auto compute_cmd_buffers_bi = commandBufferBeginInfo;

    // record commands in loop, only difference is the push constant
    foreach( i, ref cmd_buffer; vd.compute_cmd_buffers ) {
        uint push_constant = ( i * 8 ).toUint;
        cmd_buffer.vkBeginCommandBuffer( &compute_cmd_buffers_bi );  // begin command buffer recording
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
        cmd_buffer.vkCmdDispatch( 1, vd.sim_dim.y, 1 );  // dispatch compute command
        cmd_buffer.vkEndCommandBuffer;          // finish recording and submit the command
    }

    // we will submit two command buffers now
    //vd.submit_info.commandBufferCount = 2;

    return vd;
}



auto ref resizeRenderResources( ref VDrive_State vd ) {

    //////////////////////////////////////////////////////
    // (re)construct the already parametrized swapchain //
    //////////////////////////////////////////////////////

    import vdrive.surface;
    vd.surface.construct;

    // set the corresponding present info member to the (re)constructed swapchain
    vd.present_info.pSwapchains = &vd.surface.swapchain;



    ////////////////////////
    // create depth image //
    ////////////////////////

    import vdrive.memory;

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

    import vdrive.command;
    // Note: allocate one command buffer
    // cmd_buffer is an Array!VkCommandBuffer
    // the array itself will be destroyd after this scope
    auto cmd_buffer = vd.allocateCommandBuffer( vd.cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY );

    VkCommandBufferBeginInfo cmd_buffer_begin_info = {
        flags : VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, };
    vkBeginCommandBuffer( cmd_buffer, &cmd_buffer_begin_info );

    import vdrive.memory;
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
    import vdrive.util.util : vkAssert;
    auto submit_info = cmd_buffer.queueSubmitInfo;
    vd.graphics_queue.vkQueueSubmit( 1, &submit_info, VK_NULL_HANDLE ).vkAssert;




    /////////////////////////
    // create framebuffers //
    /////////////////////////

    import vdrive.renderbuffer;
    VkImageView[1] render_targets = [ vd.depth_image.image_view ];  // compose render targets into an array
    vd.framebuffers( vd )
        .create(                                        // create the vulkan object directly with following params
            vd.render_pass.render_pass,                 // specify render pass COMPATIBILITY
            vd.surface.imageExtent,                     // extent of the framebuffer
            render_targets,                             // first ( static ) attachments which will not change ( here only )
            vd.surface.present_image_views.data )       // next one dynamic attachment ( swapchain ) which changes per command buffer
        .addClearValue( 1.0f )                          // add depth clear value
        .addClearValue( 0.3f, 0.3f, 0.3f, 1.0f );       // add color clear value

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

    vd.viewport = VkViewport( 0, 0, vd.surface.imageExtent.width, vd.surface.imageExtent.height, 0, 1 );
    vd.scissors = VkRect2D( VkOffset2D( 0, 0 ), vd.surface.imageExtent );

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
    import vdrive.command : allocateCommandBuffers;
    vd.allocateCommandBuffers( vd.cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, vd.cmd_buffers[ 0 .. vd.surface.imageCount ] );


    // draw command buffer begin info for vkBeginCommandBuffer, can be used in any command buffer
    VkCommandBufferBeginInfo cmd_buffer_begin_info;


    import vdrive.renderbuffer : attachFramebuffer;
    // record command buffer for each swapchain image
    foreach( uint32_t i, ref cmd_buffer; vd.cmd_buffers[ 0 .. vd.surface.imageCount ] ) {    // remove .data if using static array

        // attach one of the framebuffers to the render pass
        vd.render_pass.attachFramebuffer( vd.framebuffers( i ));


        // begin command buffer recording
        cmd_buffer.vkBeginCommandBuffer( &cmd_buffer_begin_info );


        // begin the render_pass
        cmd_buffer.vkCmdBeginRenderPass( &vd.render_pass.begin_info, VK_SUBPASS_CONTENTS_INLINE );


        // bind graphics vd.geom_pipeline
        cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_GRAPHICS, vd.graphics_pso.pipeline );


        // take care of dynamic state
        cmd_buffer.vkCmdSetViewport( 0, 1, &vd.viewport );
        cmd_buffer.vkCmdSetScissor(  0, 1, &vd.scissors );
        cmd_buffer.vkCmdBindDescriptorSets(     // VkCommandBuffer              commandBuffer
            VK_PIPELINE_BIND_POINT_GRAPHICS,    // VkPipelineBindPoint          pipelineBindPoint
            vd.graphics_pso.pipeline_layout,    // VkPipelineLayout             layout
            0,                                  // uint32_t                     firstSet
            1,                                  // uint32_t                     descriptorSetCount
            &vd.descriptor.descriptor_set,      // const( VkDescriptorSet )*    pDescriptorSets
            0,                                  // uint32_t                     dynamicOffsetCount
            null                                // const( uint32_t )*           pDynamicOffsets
        );


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

    // surface, swapchain and present image views
    vd.surface.destroyResources;

    // memory Resources
    vd.depth_image.destroyResources;
    vd.wvpm_buffer.unmapMemory.destroyResources;

    foreach( ref buffer_view; vd.lbmd_buffer_views ) vd.destroy( buffer_view );
    vd.lbmd_buffer.destroyResources;
    vd.lbmd_memory.destroyResources;
    vd.lbmd_image.destroyResources;
    vd.destroy( vd.lbmd_sampler );

    // render setup
    vd.render_pass.destroyResources;
    vd.framebuffers.destroyResources;
    vd.destroy( vd.descriptor );
    vd.destroy( vd.graphics_pso );
    vd.destroy( vd.compute_pso );

    // command and synchronize
    vd.destroy( vd.cmd_pool );
    vd.destroy( vd.compute_cmd_pool );
    vd.destroy( vd.acquired_semaphore );
    vd.destroy( vd.rendered_semaphore );
    foreach( ref fence; vd.submit_fence )
        vd.destroy( fence );

    return vd;
}

