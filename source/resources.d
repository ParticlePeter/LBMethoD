module resources;

import erupted;

import vdrive;
import appstate;
import simulate;
import visualize;

import dlsl.matrix;

debug import core.stdc.stdio : printf;



//nothrow @nogc:


////////////////////////////////////////////////////////////////////////
// create vulkan related command and synchronization objects and data //
////////////////////////////////////////////////////////////////////////
void createCommandObjects( ref VDrive_State app, VkCommandPoolCreateFlags command_pool_create_flags = 0 ) {

    //
    // create command pools
    //

    // one to process and display graphics, this one is rest on window resize events
    app.cmd_pool = app.createCommandPool( app.graphics_queue_family_index, command_pool_create_flags );

    // one for compute operations, not reset on window resize events
    app.sim.cmd_pool = app.createCommandPool( app.graphics_queue_family_index );



    //
    // create fence and semaphores
    //

    // must create all fences as we don't know the swapchain image count yet
    // but we also don't want to recreate fences in window resize events and keep track how many exist
    foreach( ref fence; app.submit_fence )
        fence = app.createFence( VK_FENCE_CREATE_SIGNALED_BIT ); // fence to sync CPU and GPU once per frame


    // rendering and presenting semaphores for VkSubmitInfo, VkPresentInfoKHR and vkAcquireNextImageKHR
    foreach( i; 0 .. VDrive_State.MAX_FRAMES ) {
        app.acquired_semaphore[i] = app.createSemaphore;        // signaled when a new swapchain image is acquired
        app.rendered_semaphore[i] = app.createSemaphore;        // signaled when submitted command buffer(s) complete execution
    }



    //
    // configure submit and present infos
    //

    // draw submit info for vkQueueSubmit
    with( app.submit_info ) {
        waitSemaphoreCount      = 1;
        pWaitSemaphores         = & app.acquired_semaphore[0];
        pWaitDstStageMask       = & app.submit_wait_stage_mask; // configured before entering createResources func
        commandBufferCount      = 1;
    //  pCommandBuffers         = & app.cmd_buffers[ i ];       // set before submission, choosing cmd_buffers[0/1]
        signalSemaphoreCount    = 1;
        pSignalSemaphores       = & app.rendered_semaphore[0];
    }

    // initialize present info for vkQueuePresentKHR
    with( app.present_info ) {
        waitSemaphoreCount      = 1;
        pWaitSemaphores         = & app.rendered_semaphore[0];
        swapchainCount          = 1;
        pSwapchains             = & app.swapchain.swapchain;
    //  pImageIndices           = & next_image_index;           // set before presentation, using the acquired next_image_index
    //  pResults                = null;                         // per swapchain presentation results, redundant when using only one swapchain
    }
}



//////////////////////////////////////////////
// create simulation related memory objects //
//////////////////////////////////////////////
void createMemoryObjects( ref VDrive_State app ) {

    // create static memory resources which will be referenced in descriptor set
    // the corresponding createDescriptorSet function might be overwritten somewhere else

    //
    // create uniform buffers - called once
    //

    // create transformation ubo buffer without memory backing
    import dlsl.matrix;
    auto xform_ubo_buffer = Meta_Buffer_T!( VDrive_State.Ubo_Buffer )( app )
        .usage( VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT )
        .bufferSize( VDrive_State.XForm_UBO.sizeof )
        .constructBuffer;

    // create compute ubo buffer without memory backing
    auto compute_ubo_buffer = Meta_Buffer_T!( VDrive_State.Ubo_Buffer )( app )
        .usage( VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT )
        .bufferSize( Sim_State.Compute_UBO.sizeof )
        .constructBuffer;

    // create display ubo buffer without memory backing
    auto display_ubo_buffer = Meta_Buffer_T!( VDrive_State.Ubo_Buffer )( app )
        .usage( VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT )
        .bufferSize( Vis_State.Display_UBO.sizeof )
        .constructBuffer;

    // Todo(pp): selective code path if DEVICE_LOCAL | HOST_VISIBLE is available (AMD), use memory : hasMemoryHeapType

    // create host visible memory for ubo buffers and map it
    void* mapped_memory;
    app.host_visible_memory = Meta_Memory( app )
        .memoryType( VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT )
        .allocateAndBind( xform_ubo_buffer, compute_ubo_buffer, display_ubo_buffer )
        .mapMemory( mapped_memory )                         // map the memory object persistently
        .memory;

    // cast the mapped memory pointer without offset into our transformation matrix
    app.xform_ubo = cast( VDrive_State.XForm_UBO* )mapped_memory;                       // cast to mat4

    // extract Core_Buffer data, including mapped memory range for memory flushing, from xform Meta_Buffer and update the underlying VkBuffer
    app.xform_ubo_buffer = xform_ubo_buffer.extractCore;    // extract Core_Buffer data, including mapped memory range for memory flushing, from Meta_Buffer
    app.updateProjection;   // update projection matrix from member data _fovy, _near, _far and aspect of the swapchain extent
    app.updateWVPM;         // multiply projection with trackball (view) matrix and upload to uniform buffer


    // cast the mapped memory pointer with its offset into the backing memory to our compute ubo struct and init_pso the memory
    if( app.sim.compute_ubo is null ) {
        app.sim.compute_ubo = cast( Sim_State.Compute_UBO* )( mapped_memory + compute_ubo_buffer.memOffset );
        app.sim.compute_ubo.collision_frequency = 1; //1 / 0.504;
        app.sim.compute_ubo.wall_velocity  = 3 * 0.1; //0.005;     //0.25 * 3;// / app.sim.speed_of_sound / app.sim.speed_of_sound;
        app.sim.compute_ubo.wall_thickness = 1; // 3;
        app.sim.compute_ubo.comp_index = 0;
    } else {
        auto compute_ubo = cast( Sim_State.Compute_UBO* )( mapped_memory + compute_ubo_buffer.memOffset );
        *compute_ubo = *app.sim.compute_ubo;    // copy data
        app.sim.compute_ubo = compute_ubo;      // copy pointer
    }
    // extract Core_Buffer data, including mapped memory range for memory flushing, from compute Meta_Buffer and update the underlying VkBuffer
    app.sim.compute_ubo_buffer = compute_ubo_buffer.extractCore;
    app.updateComputeUBO;


    // cast the mapped memory pointer with its offset into the backing memory to our display ubo struct and init_pso the memory
    if( app.vis.display_ubo is null ) {
        app.vis.display_ubo = cast( Vis_State.Display_UBO* )( mapped_memory + display_ubo_buffer.memOffset );
        app.vis.display_ubo.amplify_property = 1;
        app.vis.display_ubo.color_layers = 0;
        app.vis.display_ubo.z_layer = 0;
    } else {
        auto display_ubo = cast( Vis_State.Display_UBO* )( mapped_memory + display_ubo_buffer.memOffset );
        *display_ubo = *app.vis.display_ubo;    // copy data
        app.vis.display_ubo = display_ubo;      // copy pointer
    }
    // extract Core_Buffer data, including mapped memory range for memory flushing, from display Meta_Buffer and update the underlying VkBuffer
    app.vis.display_ubo_buffer = display_ubo_buffer.extractCore;
    app.amplifyDisplayProperty; // Calls updateDisplayUBO, after initializing visualization display property, possibly divided by sim steps.
    app.updateDisplayUBO;


    //
    // create simulate and visualize memory objects
    //
    app.createPopulBuffer;
    app.createMacroImage;
    app.createParticleBuffer;
}



///////////////////////////
// create descriptor set //
///////////////////////////
void createDescriptorSet( ref VDrive_State app ) {

    // this is required if no Meta Descriptor has been passed in from the outside
    Meta_Descriptor_T!(9,3,8,4,3,2) meta_descriptor = app;    // temporary
    //Meta_Descriptor meta_descriptor;    // temporary

    // call the real create function
    app.createDescriptorSet_T( meta_descriptor );
}

void createDescriptorSet_T( Descriptor_T )( ref VDrive_State app, ref Descriptor_T meta_descriptor ) {

    // configure descriptor set with required descriptors
    // the descriptor set will be constructed in createRenderRecources
    // immediately before creating the first pipeline so that additional
    // descriptors can be added through other means before finalizing
    // maybe we even might overwrite it completely in a parent struct

    app.descriptor = meta_descriptor     // VDrive_State.descriptor is a Core_Descriptor

        // XForm_UBO
        .addUniformBufferBinding( 0, VK_SHADER_STAGE_VERTEX_BIT )
        .addBufferInfo( app.xform_ubo_buffer.buffer )

        // Main Compute Buffer for populations
        .addStorageTexelBufferBinding( 2, VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_COMPUTE_BIT )
        .addTexelBufferView( app.sim.popul_buffer.view )

        // Image to store macroscopic variables ( velocity, density ) from simulation compute shader
        .addStorageImageBinding( 3, VK_SHADER_STAGE_COMPUTE_BIT )
        .addImage( app.sim.macro_image.view, VK_IMAGE_LAYOUT_GENERAL )

        // Sampler to read from macroscopic image in lines, display and export shader
        .addSamplerImageBinding( 4, VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT | VK_SHADER_STAGE_COMPUTE_BIT )
        .addSamplerImage( app.sim.macro_image.sampler[0], app.sim.macro_image.view, VK_IMAGE_LAYOUT_GENERAL )
        .addSamplerImage( app.sim.macro_image.sampler[1], app.sim.macro_image.view, VK_IMAGE_LAYOUT_GENERAL )       // additional sampler if we want to examine each node

        // Compute UBO for compute parameter
        .addUniformBufferBinding( 5, VK_SHADER_STAGE_COMPUTE_BIT | VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT )
        .addBufferInfo( app.sim.compute_ubo_buffer.buffer )

        // Display UBO for display parameter
        .addUniformBufferBinding( 6, VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT )
        .addBufferInfo( app.vis.display_ubo_buffer.buffer )

        // Particle Buffer
        .addStorageTexelBufferBinding( 7, VK_SHADER_STAGE_VERTEX_BIT )
        .addTexelBufferView( app.vis.particle_buffer.view )

        // Export Buffer views will be set and written when export is activated
        .addStorageTexelBufferBinding( 8, VK_SHADER_STAGE_COMPUTE_BIT, 2 )
        //.addTexelBufferView( app.export_buffer_view[0] );
        //.addTexelBufferView( app.export_buffer_view[1] );

        // build and reset, returning a Core_Descriptor
        .construct
        .reset;
}



//////////////////////////////////
// create descriptor set update //
//////////////////////////////////
void updateDescriptorSet( ref VDrive_State app ) {

    // update the descriptor
    Descriptor_Update_T!( 4, 3, 0, 2 )()
        .addStorageTexelBufferUpdate( 2 )
        .addTexelBufferView( app.sim.popul_buffer.view )

        .addStorageImageUpdate( 3 )
        .addImage( app.sim.macro_image.view, VK_IMAGE_LAYOUT_GENERAL )

        .addSamplerImageUpdate( 4 ) // immutable does not filter properly, module descriptor bug?
    //  .addImage( app.sim.macro_image.view, VK_IMAGE_LAYOUT_GENERAL )        // immutable sampler
    //  .addImage( app.sim.macro_image.view, VK_IMAGE_LAYOUT_GENERAL )        // immutable sampler
        .addSamplerImage( app.sim.macro_image.sampler[0], app.sim.macro_image.view, VK_IMAGE_LAYOUT_GENERAL ) // mutable sampler
        .addSamplerImage( app.sim.macro_image.sampler[1], app.sim.macro_image.view, VK_IMAGE_LAYOUT_GENERAL ) // mutable sampler

        .addStorageTexelBufferUpdate( 7 )
        .addTexelBufferView( app.vis.particle_buffer.view )

        .attachSet( app.descriptor.descriptor_set )
        .update( app );

    // Note(pp):
    // it would be more efficient to create another descriptor update for the app.vis.particle_buffer.view
    // it will most likely not be updated with the other resources and vice versa
    // but ... what the heck ... for now ... we won't update both of them often enough
}



/////////////////////////////
// create render resources //
/////////////////////////////
void createRenderResources( ref VDrive_State app ) {

    //
    // create simulate and visualize resources
    //
    app.createSimResources;      // create all resources for the simulate compute pipeline
    app.createVisResources;      // create all resources for the visualize graphics pipelines
}



////////////////////////////////////////////////
// (re)create window size dependent resources //
////////////////////////////////////////////////
void resizeRenderResources( ref VDrive_State app, VkPresentModeKHR request_present_mode = VK_PRESENT_MODE_MAX_ENUM_KHR ) {

    //
    // destroy possibly existing swapchain and image views, but keep the surface.
    //
    if(!app.swapchain.is_null ) {
        app.device.vkDeviceWaitIdle;             // wait till device is idle
        app.destroy( app.swapchain, false );
    }



    //
    // select swapchain image format and presentation mode
    //

    // Optionally, we can pass in a request present mode, which will be preferred. It will not be checked for availability.
    // If VK_PRESENT_MODE_MAX_ENUM_KHR is passed in we check VDrive_State.present_mode is valid and available (it's a setting, it will be set by ini file).
    // If it's value is set to VK_PRESENT_MODE_MAX_ENUM_KHR, or is not valid for the current implementation the present mode will be set
    // to VK_PRESENT_MODE_FIFO_KHR, which is mandatory for every swapchain supporting implementation.

    // Note: to get GPU swapchain capabilities to check for possible image usages
    //VkSurfaceCapabilitiesKHR surface_capabilities;
    //vkGetPhysicalDeviceSurfaceCapabilitiesKHR( swapchain.gpu, swapchain.swapchain, & surface_capabilities );
    //surface_capabilities.printTypeInfo;

    // we need to know the swapchain image format before we create a render pass
    // to render into that swapchain image. We don't have to create the swapchain itself
    // renderpass needs to be created only once in contrary to the swapchain, which must be
    // recreated if the window swapchain size changes
    // We set all required parameters here to avoid configuration at multiple locations
    // additionally configuration needs to happen only once

    // list of preferred formats and modes, the first found will be used, otherwise the first available not in lists
    VkFormat[4] request_format = [ VK_FORMAT_R8G8B8_UNORM, VK_FORMAT_B8G8R8_UNORM, VK_FORMAT_R8G8B8A8_UNORM, VK_FORMAT_B8G8R8A8_UNORM ];

    // set present mode to the passed in value and trust that
    if( request_present_mode != VK_PRESENT_MODE_MAX_ENUM_KHR )
        app.present_mode = request_present_mode;

    else if( app.present_mode == VK_PRESENT_MODE_MAX_ENUM_KHR || !app.hasPresentMode( app.swapchain.surface, app.present_mode ))
        app.present_mode = VK_PRESENT_MODE_FIFO_KHR;

    // parametrize swapchain and keep Meta_Swapchain around to access extended data
    auto swapchain = Meta_Swapchain_T!( typeof( app.swapchain ))( app )
        .surface( app.swapchain.surface )
        .oldSwapchain( app.swapchain.swapchain )
        .selectSurfaceFormat( request_format )
        .presentMode( app.present_mode )
        .minImageCount( 2 )
        .imageArrayLayers( 1 )
        .imageUsage( VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT )
        .construct
        .reset( app.swapchain );

    // assign pointer of our new swapchain to the app.present_info
    app.present_info.pSwapchains = & app.swapchain.swapchain;



    //
    // create depth image
    //

    // first destroy old image and view
    if(!app.depth_image.image.is_null )
        app.destroy(  app.depth_image );

    // depth image format is also required for the renderpass
    VkFormat depth_image_format = VK_FORMAT_D32_SFLOAT; // VK_FORMAT_D16_UNORM

    // prefer getting the depth image into a device local heap
    // first we need to find out if such a heap exist on the current device
    // we do not check the size of the heap, the depth image will probably fit if such heap exists
    // Todo(pp): the assumption above is NOT guaranteed, add additional functions to memory module
    // which consider a minimum heap size for the memory type, heap as well as memory creation functions
    auto depth_image_memory_property = app.memory_properties.hasMemoryHeapType( VK_MEMORY_HEAP_DEVICE_LOCAL_BIT )
        ? VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT
        : VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT;

    // depth_image_format can be set before this function gets called
    auto depth_image = Meta_Image_T!Core_Image_Memory_View( app )
        .format( depth_image_format )
        .extent( app.windowWidth, app.windowHeight )
        .usage( VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT )
        .sampleCount( app.sample_count )
        .constructImage
        .allocateMemory( depth_image_memory_property )
        .viewAspect( VK_IMAGE_ASPECT_DEPTH_BIT )
        .constructView
        .extractCore( app.depth_image );


    //
    // record transition of depth image from VK_IMAGE_LAYOUT_UNDEFINED to VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
    //

    // Note: allocate one command buffer
    auto cmd_buffer = app.allocateCommandBuffer( app.cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY );

    VkCommandBufferBeginInfo cmd_buffer_bi = { flags : VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    vkBeginCommandBuffer( cmd_buffer, & cmd_buffer_bi );

    cmd_buffer.recordTransition(
        depth_image.image,
        depth_image.image_view_ci.subresourceRange,
        VK_IMAGE_LAYOUT_UNDEFINED,
        VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        0,  // no access mask required here
        VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
        VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,     // this has been caught by the recent validation layers of vulkan spec v1.0.57
    );

    // finish recording
    cmd_buffer.vkEndCommandBuffer;

    // submit info stays local in this function scope
    auto submit_info = cmd_buffer.queueSubmitInfo;

    // submit the command buffer, we do not need to wait for the result here.
    app.graphics_queue.vkQueueSubmit( 1, & submit_info, VK_NULL_HANDLE ).vkAssert;



    //
    // create render pass and clear values
    //

    // clear values, stored in VDrive_State
    app.clear_values
        .set( 0, 1.0f )                             // add depth clear value
        .set( 1, 0.0f, 0.0f, 0.0f, 1.0f );          // add color clear value
    //  .set( 1, 0.9922f, 0.9647f, 0.8902f, 1.0f ); // solarize

    // destroy possibly previously created render pass
    if( !app.render_pass_bi.renderPass.is_null )
        app.destroy( app.render_pass_bi.renderPass );


    //Meta_Render_Pass_T!( 2,2,1,0,1,0,0 ) render_pass;
    app.render_pass_bi = Meta_Render_Pass_T!( 2,2,1,0,1,0,0 )( app )
        .renderPassAttachment_Clear_None(  depth_image_format,    app.sample_count, VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL           ).subpassRefDepthStencil
        .renderPassAttachment_Clear_Store( swapchain.imageFormat, app.sample_count, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR ).subpassRefColor( VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL )

        // Note: specify dependencies despite of only one subpass, as suggested by:
        // https://software.intel.com/en-us/articles/api-without-secrets-introduction-to-vulkan-part-4#
        //.addDependency( VK_DEPENDENCY_BY_REGION_BIT )
        //.srcDependency( VK_SUBPASS_EXTERNAL, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT         , VK_ACCESS_MEMORY_READ_BIT )
        //.dstDependency( 0                  , VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT )
        //.addDependency( VK_DEPENDENCY_BY_REGION_BIT )
        //.srcDependency( 0                  , VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT )
        //.dstDependency( VK_SUBPASS_EXTERNAL, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT         , VK_ACCESS_MEMORY_READ_BIT )

        // Note: specify dependencies despite of only one subpass, as suggested by:
        // https://github.com/KhronosGroup/Vulkan-Docs/wiki/Synchronization-Examples#swapchain-image-acquire-and-present
        .addDependency( VK_DEPENDENCY_BY_REGION_BIT )
        .srcDependency( VK_SUBPASS_EXTERNAL, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0 )
        .dstDependency( 0                  , VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT )

        .clearValues( app.clear_values )
        .construct
        .beginInfo;


    //import std.stdio;
    //writeln( render_pass.static_config );


    //
    // create framebuffers
    //
    VkImageView[1] render_targets = [ app.depth_image.view ];     // compose render targets into an array
    app.createFramebuffers(
        app.framebuffers,
        app.render_pass_bi.renderPass,              // specify render pass COMPATIBILITY
        app.swapchain.image_extent.width,           // framebuffer width
        app.swapchain.image_extent.height,          // framebuffer height
        render_targets,                             // first ( static ) attachments which will not change ( here only )
        app.swapchain.image_views.data              // next one dynamic attachment ( swapchain ) which changes per command buffer
    );

    app.render_pass_bi.renderAreaExtent( app.swapchain.image_extent );  // specify the render area extent of our render pass begin info



    //
    // update dynamic viewport and scissor state
    //
    app.viewport = VkViewport( 0, 0, app.swapchain.image_extent.width, app.swapchain.image_extent.height, 0, 1 );
    app.scissors = VkRect2D( VkOffset2D( 0, 0 ), app.swapchain.image_extent );
}



///////////////////////////////////
// (re)create draw loop commands //
///////////////////////////////////
void createResizedCommands( ref VDrive_State app ) nothrow {

    // we need to do this only if the gui is not displayed
//    if( app.draw_gui )
//        return;

    // reset the command pool to start recording drawing commands
    app.graphics_queue.vkQueueWaitIdle;   // equivalent using a fence per Spec v1.0.48
    app.device.vkResetCommandPool( app.cmd_pool, 0 ); // second argument is VkCommandPoolResetFlags


    // if we know how many command buffers are required we can use this static array function
    app.allocateCommandBuffers( app.cmd_pool, app.cmd_buffers[ 0 .. app.swapchain.image_count ] );


    // draw command buffer begin info for vkBeginCommandBuffer, can be used in any command buffer
    VkCommandBufferBeginInfo cmd_buffer_bi;


    // record command buffer for each swapchain image
    foreach( i, ref cmd_buffer; app.cmd_buffers[ 0 .. app.swapchain.image_count ] ) {    // remove .data if using static array

        // attach one of the framebuffers to the render pass
        app.render_pass_bi.framebuffer = app.framebuffers[ i ];

        // begin command buffer recording
        cmd_buffer.vkBeginCommandBuffer( & cmd_buffer_bi );

        // take care of dynamic state
        cmd_buffer.vkCmdSetViewport( 0, 1, & app.viewport );
        cmd_buffer.vkCmdSetScissor(  0, 1, & app.scissors );

        // bind descriptor set
        cmd_buffer.vkCmdBindDescriptorSets(         // VkCommandBuffer              commandBuffer
            VK_PIPELINE_BIND_POINT_GRAPHICS,        // VkPipelineBindPoint          pipelineBindPoint
            app.vis.display_pso.pipeline_layout,    // VkPipelineLayout             layout
            0,                                      // uint32_t                     firstSet
            1,                                      // uint32_t                     descriptorSetCount
            & app.descriptor.descriptor_set,        // const( VkDescriptorSet )*    pDescriptorSets
            0,                                      // uint32_t                     dynamicOffsetCount
            null                                    // const( uint32_t )*           pDynamicOffsets
        );

        // begin the render pass
        cmd_buffer.vkCmdBeginRenderPass( & app.render_pass_bi, VK_SUBPASS_CONTENTS_INLINE );

        // bind lbmd display plane pipeline and draw
        if( app.vis.draw_display ) {

            cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_GRAPHICS, app.vis.display_pso.pipeline );

            // push constant the sim display scale
            cmd_buffer.vkCmdPushConstants( app.vis.display_pso.pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, 2 * uint32_t.sizeof, app.sim.domain.ptr );

            // buffer-less draw with build in gl_VertexIndex exclusively to generate position and tex_coord data
            cmd_buffer.vkCmdDraw( 4, 1, 0, 0 ); // vertex count, instance count, first vertex, first instance
        }

        // bind particle pipeline and draw
        if( app.vis.draw_particles ) {
            cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_GRAPHICS, app.vis.particle_pso.pipeline );
            cmd_buffer.vkCmdPushConstants( app.vis.particle_pso.pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, app.vis.particle_pc.sizeof, & app.vis.particle_pc );
            cmd_buffer.vkCmdDraw( app.vis.particle_count, 1, 0, 0 );    // vertex count, instance count, first vertex, first instance
        }

        // end the render pass
        cmd_buffer.vkCmdEndRenderPass;

        // end command buffer recording
        cmd_buffer.vkEndCommandBuffer;
    }


    // as we have reset the complete command pool, we must also recreate the particle reset command buffer
    import visualize : createParticleResetCmdBuffer;
    app.createParticleResetCmdBuffer;
}



//////////////////////////////
// destroy vulkan resources //
//////////////////////////////
void destroyResources( ref VDrive_State app ) {

    import erupted, vdrive, exportstate, cpustate;

    app.device.vkDeviceWaitIdle;

    // destroy vulkan category resources
    app.destroyVisResources;    // Visualize
    app.destroySimResources;    // Simulate
    app.destroyExpResources;    // Export
    app.destroyCpuResources;    // Cpu

    // surface, swapchain and present image views
    app.destroy( app.swapchain );

    // memory Resources
    app.destroy( app.depth_image );
    app.destroy( app.xform_ubo_buffer );
    app.unmapMemory( app.host_visible_memory ).destroy( app.host_visible_memory );

    // render setup
    foreach( ref f; app.framebuffers )  app.destroy( f );
    app.destroy( app.render_pass_bi.renderPass );
    app.destroy( app.descriptor );

    // command and synchronize
    app.destroy( app.cmd_pool );
    foreach( ref f; app.submit_fence )       app.destroy( f );
    foreach( ref s; app.acquired_semaphore ) app.destroy( s );
    foreach( ref s; app.rendered_semaphore ) app.destroy( s );
}

