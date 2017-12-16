module resources;

import erupted;

import vdrive;
import appstate;
import simulate;
import visualize;

import dlsl.matrix;





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
    foreach( i; 0 .. app.MAX_FRAMES ) {
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
    //  pResults                = null;                         // per swapchain prsentation results, redundant when using only one swapchain
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

    // create transformation ubo buffer withour memory backing
    import dlsl.matrix;
    app.xform_ubo_buffer( app )
        .create( VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, VDrive_State.XForm_UBO.sizeof );


    // create compute ubo buffer without memory backing
    app.sim.compute_ubo_buffer( app )
        .create( VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, VDrive_Simulate_State.Compute_UBO.sizeof );


    // create display ubo buffer without memory backing
    app.vis.display_ubo_buffer( app )
        .create( VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, VDrive_Visualize_State.Display_UBO.sizeof );


    // create host visible memory for ubo buffers and map it
    auto mapped_memory = app.host_visible_memory( app )
        .memoryType( VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT )
        .addRange( app.xform_ubo_buffer )
        .addRange( app.sim.compute_ubo_buffer )
        .addRange( app.vis.display_ubo_buffer )
        .allocate
        .bind( app.xform_ubo_buffer )
        .bind( app.sim.compute_ubo_buffer )
        .bind( app.vis.display_ubo_buffer )
        .mapMemory;                         // map the memory object persistently

    // cast the mapped memory pointer without offset into our transformation matrix
    app.xform_ubo = cast( VDrive_State.XForm_UBO* )mapped_memory;                       // cast to mat4
    app.xform_ubo_flush = app.xform_ubo_buffer.createMappedMemoryRange; // specify mapped memory range for the wvpm ubo
    app.updateProjection;   // update projection matrix from member data _fovy, _near, _far and aspect of the swapchain extent
    app.updateWVPM;         // multiply projection with trackball (view) matrix and upload to uniform buffer


    // cast the mapped memory pointer with its offset into the backing memory to our compute ubo struct and init_pso the memory
    app.sim.compute_ubo = cast( VDrive_Simulate_State.Compute_UBO* )( mapped_memory + app.sim.compute_ubo_buffer.memOffset );
    app.sim.compute_ubo_flush = app.sim.compute_ubo_buffer.createMappedMemoryRange; // specify mapped memory range for the compute ubo
    app.sim.compute_ubo.collision_frequency = 1 / 0.504;
    app.sim.compute_ubo.wall_velocity  = 0.005 * 3;     //0.25 * 3;// / app.sim.speed_of_sound / app.sim.speed_of_sound;
    app.sim.compute_ubo.wall_thickness = 3;
    app.sim.compute_ubo.comp_index = 0;
    app.updateComputeUBO;


    // cast the mapped memory pointer with its offset into the backing memory to our display ubo struct and init_pso the memory
    app.vis.display_ubo = cast( VDrive_Visualize_State.Display_UBO* )( mapped_memory + app.vis.display_ubo_buffer.memOffset );
    app.vis.display_ubo_flush = app.vis.display_ubo_buffer.createMappedMemoryRange; // specify mapped memory range for the display ubo
    app.vis.display_ubo.amplify_property = 1;
    app.vis.display_ubo.color_layers = 0;
    app.vis.display_ubo.z_layer = 0;
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
void createDescriptorSet( ref VDrive_State app, Meta_Descriptor* meta_descriptor_ptr = null ) {

    // configure descriptor set with required descriptors
    // the descriptor set will be constructed in createRenderRecources
    // immediately before creating the first pipeline so that additional
    // descriptors can be added through other means before finalizing
    // maybe we even might overwrite it completely in a parent struct

    // this is required if no Meta Descriptor has been passed in from the outside
    Meta_Descriptor meta_descriptor = app;
    if( meta_descriptor_ptr is null ) {
        meta_descriptor_ptr = & meta_descriptor;
    }


    Meta_Sampler meta_sampler;
    app.sim.macro_image.sampler = meta_sampler( app )
    //  .addressMode( VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER, VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER, VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER )
        .unnormalizedCoordinates( VK_TRUE )
        .construct
        .sampler;

    // reuse Meta_sampler to construct a new nearest neighbor sampler
    app.sim.nearest_sampler = meta_sampler
        .filter( VK_FILTER_NEAREST, VK_FILTER_NEAREST )
    //  .addressMode( VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER, VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER, VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER )
    //  .unnormalizedCoordinates( VK_TRUE )     // not required to set as it is still set from edit before
        .construct
        .sampler;

    // Note(pp): immutable does not filter properly, either driver bug or module descriptor bug
    // Todo(pp): debug the issue
    ( *meta_descriptor_ptr )    // VDrive_State.descriptor is a Core_Descriptor

        // XForm_UBO
        .addLayoutBinding( 0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, VK_SHADER_STAGE_VERTEX_BIT )
        .addBufferInfo( app.xform_ubo_buffer.buffer )

        // Main Compute Buffer for populations
        .addLayoutBinding( 2, VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, VK_SHADER_STAGE_COMPUTE_BIT )
        .addTexelBufferView( app.sim.popul_buffer_view )

        // Image to store macroscopic variables ( velocity, density ) from simulation compute shader
        .addLayoutBinding( 3, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, VK_SHADER_STAGE_COMPUTE_BIT )
        .addImageInfo( app.sim.macro_image.image_view, VK_IMAGE_LAYOUT_GENERAL )

        // Sampler to read from macroscopic image in lines, display and export shader
        .addLayoutBinding/*Immutable*/( 4, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT | VK_SHADER_STAGE_COMPUTE_BIT )
        .addImageInfo( app.sim.macro_image.image_view, VK_IMAGE_LAYOUT_GENERAL, app.sim.macro_image.sampler )
        .addImageInfo( app.sim.macro_image.image_view, VK_IMAGE_LAYOUT_GENERAL, app.sim.nearest_sampler )        // additional sampler if we want to examine each node

        // Compute UBO for compute parameter
        .addLayoutBinding( 5, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, VK_SHADER_STAGE_COMPUTE_BIT | VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT )
        .addBufferInfo( app.sim.compute_ubo_buffer.buffer )

        // Display UBO for display parameter
        .addLayoutBinding( 6, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT )
        .addBufferInfo( app.vis.display_ubo_buffer.buffer )

        // Particle Buffer
        .addLayoutBinding( 7, VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, VK_SHADER_STAGE_VERTEX_BIT )
        .addTexelBufferView( app.vis.particle_buffer_view )

        // Export Buffer views will be set and written when export is activated
        .addLayoutBinding( 8, VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, VK_SHADER_STAGE_COMPUTE_BIT, 2 );
        //.addTexelBufferView( app.export_buffer_view[0] );
        //.addTexelBufferView( app.export_buffer_view[1] );



    // The app crashes here in construct sometimes, and it is not clear why
    // In Debug mode we see that some undefined exception is thrown, which cannot be caught here
    // The error seems to be unrelated to this section, check all the steps taken before this occurs
    // Exit Code: -1073740940 (FFFFFFFFC0000374)
    // ---
    // New insight tells us that this is a memory corruption which only occurs when using immutable samplers

    app.descriptor = ( *meta_descriptor_ptr ).construct.reset;


    // prepare simulation data descriptor update
    // necessary when we recreate resources and have to rebind them to our descriptors
    app.sim_descriptor_update( app )
        .addBindingUpdate( 2, VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER )
        .addTexelBufferView( app.sim.popul_buffer_view )

        .addBindingUpdate( 3, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE )
        .addImageInfo( app.sim.macro_image.image_view, VK_IMAGE_LAYOUT_GENERAL )

        .addBindingUpdate/*Immutable*/( 4, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER ) // immutable does not filter properly, module descriptor bug
        .addImageInfo( app.sim.macro_image.image_view, VK_IMAGE_LAYOUT_GENERAL, app.sim.macro_image.sampler )
        .addImageInfo( app.sim.macro_image.image_view, VK_IMAGE_LAYOUT_GENERAL, app.sim.nearest_sampler )

        .addBindingUpdate( 7, VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER )
        .addTexelBufferView( app.vis.particle_buffer_view )

        .attachSet( app.descriptor.descriptor_set );

    // this one is solely for export data purpose to be absolute lazy about resource construction
    // which is only necessary if we export at all
    app.exp.export_descriptor_update( app )
    //  .addBindingUpdate( 8, VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, 2 )  // Todo(pp): This variant should work, but it doesn't, see exportstate line 221
        .addBindingUpdate( 8, VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER )
        .addTexelBufferView( app.exp.export_buffer_view[0] )
        .addTexelBufferView( app.exp.export_buffer_view[1] )
        .attachSet( app.descriptor.descriptor_set );
}



//////////////////////////////////
// create descriptor set update //
//////////////////////////////////
void updateDescriptorSet( ref VDrive_State app ) {

    // update the descriptor
    app.sim_descriptor_update.texel_buffer_views[0]     = app.sim.popul_buffer_view;        // populations buffer and optionally other data like temperature
    app.sim_descriptor_update.image_infos[0].imageView  = app.sim.macro_image.image_view;   // image view for writing from compute shader
    app.sim_descriptor_update.image_infos[1].imageView  = app.sim.macro_image.image_view;   // image view for reading in display fragment shader with linear  sampling
    app.sim_descriptor_update.image_infos[2].imageView  = app.sim.macro_image.image_view;   // image view for reading in display fragment shader with nearest sampling
    app.sim_descriptor_update.texel_buffer_views[1]     = app.vis.particle_buffer_view;     // particles to visualize LBM velocity
    app.sim_descriptor_update.update;

    // Note(pp):
    // it would be more efficient to create another descriptor update for the sim_buffer_particle_view
    // it will most likely not be updated with the other resources and vice versa
    // but ... what the heck ... for now ... we won't update both of them often enough
}



/////////////////////////////
// create render resources //
/////////////////////////////
void createRenderResources( ref VDrive_State app ) {

    //
    // select swapchain image format and presentation mode
    //

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
    VkPresentModeKHR[3] request_mode = [ VK_PRESENT_MODE_IMMEDIATE_KHR, VK_PRESENT_MODE_MAILBOX_KHR, VK_PRESENT_MODE_FIFO_KHR ];

    // parametrize swapchain but postpone construction
    app.swapchain( app )
        .selectSurfaceFormat( request_format )
        .selectPresentMode( request_mode )
        .minImageCount( 2 ) // MAX_FRAMES
        .imageArrayLayers( 1 )
        .imageUsage( VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT );
        // delay .construct; call to finalize in a later step



    //
    // create render pass
    //
    app.render_pass( app )
        .renderPassAttachment_Clear_None(  app.depth_image_format,    app.sample_count, VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL ).subpassRefDepthStencil
        .renderPassAttachment_Clear_Store( app.swapchain.imageFormat, app.sample_count, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR ).subpassRefColor( VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL )

        // Note: specify dependencies despite of only one subpass, as suggested by:
        // https://software.intel.com/en-us/articles/api-without-secrets-introduction-to-vulkan-part-4#
        .addDependencyByRegion
        .srcDependency( VK_SUBPASS_EXTERNAL, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT         , VK_ACCESS_MEMORY_READ_BIT )
        .dstDependency( 0                  , VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT )
        .addDependencyByRegion
        .srcDependency( 0                  , VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT )
        .dstDependency( VK_SUBPASS_EXTERNAL, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT         , VK_ACCESS_MEMORY_READ_BIT )
        .construct;


    //
    // create simulate and visualize resources
    //
    app.createSimResources;      // create all resources for the simulate compute pipeline
    app.createVisResources;      // create all resources for the visualize graphics pipelines
}



////////////////////////////////////////////////
// (re)create window size dependent resources //
////////////////////////////////////////////////
void resizeRenderResources( ref VDrive_State app ) {

    //
    // (re)construct the already parametrized swapchain
    //
    app.swapchain.construct;

    // set the corresponding present info member to the (re)constructed swapchain
    app.present_info.pSwapchains = & app.swapchain.swapchain;



    //
    // create depth image
    //

    // prefer getting the depth image into a device local heap
    // first we need to find out if such a heap exist on the current device
    // we do not check the size of the heap, the depth image will probably fit if such heap exists
    // Todo(pp): the assumption above is NOT guaranteed, add additional functions to memory module
    // which consider a minimum heap size for the memory type, heap as well as memory cretaion functions
    // Todo(pp): this should be a member of VDrive_State and figured out only once
    // including the proper memory heap index
    auto depth_image_memory_property = app.memory_properties.hasMemoryHeapType( VK_MEMORY_HEAP_DEVICE_LOCAL_BIT )
        ? VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT
        : VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT;

    // app.depth_image_format can be set before this function gets called
    app.depth_image( app )
        .create( app.depth_image_format, app.windowWidth, app.windowHeight, VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT, app.sample_count )
        .createMemory( depth_image_memory_property )
        .createView( VK_IMAGE_ASPECT_DEPTH_BIT );



    //
    // record transition of depth image from VK_IMAGE_LAYOUT_UNDEFINED to VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
    //

    // Note: allocate one command buffer
    // cmd_buffer is an Array!VkCommandBuffer
    // the array itself will be destroyed after this scope
    auto cmd_buffer = app.allocateCommandBuffer( app.cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY );

    VkCommandBufferBeginInfo cmd_buffer_begin_info = {
        flags : VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, };
    vkBeginCommandBuffer( cmd_buffer, & cmd_buffer_begin_info );

    cmd_buffer.recordTransition(
        app.depth_image.image,
        app.depth_image.image_view_create_info.subresourceRange,
        VK_IMAGE_LAYOUT_UNDEFINED,
        VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        0,  // no access mask required here
        VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
        VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,     // this has been caught by the recent validation layers of vulkan spec v1.0.57
    );

    // finish recording
    cmd_buffer.vkEndCommandBuffer;

    // submit the command buffer
    auto submit_info = cmd_buffer.queueSubmitInfo;
    app.graphics_queue.vkQueueSubmit( 1, & submit_info, VK_NULL_HANDLE ).vkAssert;



    //
    // create framebuffers
    //
    VkImageView[1] render_targets = [ app.depth_image.image_view ];  // compose render targets into an array
    app.framebuffers( app )
        .initFramebuffers!(
            typeof( app.framebuffers ),
            app.framebuffers.fb_count + render_targets.length.toUint
            )(
            app.render_pass.render_pass,                // specify render pass COMPATIBILITY
            app.swapchain.imageExtent,                  // extent of the framebuffer
            render_targets,                             // first ( static ) attachments which will not change ( here only )
            app.swapchain.present_image_views.data,     // next one dynamic attachment ( swapchain ) which changes per command buffer
            [], false );                                // if we are recreating we do not want to destroy clear values ...

    // ... we should keep the clear values, they might have been edited by the gui
    if( app.framebuffers.clear_values.empty )
        app.framebuffers
            .addClearValue( 1.0f )                      // add depth clear value
            .addClearValue( 0.0f, 0.0f, 0.0f, 1.0f );   // add color clear value

    // attach one of the framebuffers, the render area and clear values to the render pass begin info
    // Note: attaching the framebuffer also sets the clear values and render area extent into the render pass begin info
    // setting clear values corresponding to framebuffer attachments and framebuffer extent could have happend before, e.g.:
    //      app.render_pass.clearValues( some_clear_values );
    //      app.render_pass.begin_info.renderArea = some_render_area;
    // but meta framebuffer(s) has a member for them, hence no need to create and manage extra storage/variables
    app.render_pass.attachFramebuffer( app.framebuffers, 0 );



    //
    // update dynamic viewport and scissor state
    //
    app.viewport = VkViewport( 0, 0, app.swapchain.imageExtent.width, app.swapchain.imageExtent.height, 0, 1 );
    app.scissors = VkRect2D( VkOffset2D( 0, 0 ), app.swapchain.imageExtent );
}



///////////////////////////////////
// (re)create draw loop commands //
///////////////////////////////////
void createResizedCommands( ref VDrive_State app ) nothrow {

    // we need to do this only if the gui is not displayed
    if( app.draw_gui ) return;

    // reset the command pool to start recording drawing commands
    app.graphics_queue.vkQueueWaitIdle;   // equivalent using a fence per Spec v1.0.48
    app.device.vkResetCommandPool( app.cmd_pool, 0 ); // second argument is VkCommandPoolResetFlags


    // if we know how many command buffers are required we can use this static array function
    app.allocateCommandBuffers( app.cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, app.cmd_buffers[ 0 .. app.swapchain.imageCount ] );


    // draw command buffer begin info for vkBeginCommandBuffer, can be used in any command buffer
    VkCommandBufferBeginInfo cmd_buffer_begin_info;


    // record command buffer for each swapchain image
    foreach( uint32_t i, ref cmd_buffer; app.cmd_buffers[ 0 .. app.swapchain.imageCount ] ) {    // remove .data if using static array

        // attach one of the framebuffers to the render pass
        app.render_pass.attachFramebuffer( app.framebuffers( i ));

        // begin command buffer recording
        cmd_buffer.vkBeginCommandBuffer( & cmd_buffer_begin_info );

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
        cmd_buffer.vkCmdBeginRenderPass( & app.render_pass.begin_info, VK_SUBPASS_CONTENTS_INLINE );

        // bind lbmd display plane pipeline and draw
        if( app.draw_display ) {

            cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_GRAPHICS, app.vis.display_pso.pipeline );

            // push constant the sim display scale
            cmd_buffer.vkCmdPushConstants( app.vis.display_pso.pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, 2 * uint32_t.sizeof, app.sim.domain.ptr );

            // buffer-less draw with build in gl_VertexIndex exclusively to generate position and tex_coord data
            cmd_buffer.vkCmdDraw( 4, 1, 0, 0 ); // vertex count, instance count, first vertex, first instance
        }

        // bind particle pipeline and draw
        if( app.draw_particles ) {
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
    app.swapchain.destroyResources;

    // memory Resources
    app.depth_image.destroyResources;
    app.xform_ubo_buffer.destroyResources;
    app.host_visible_memory.unmapMemory.destroyResources;

    // render setup
    app.render_pass.destroyResources;
    app.framebuffers.destroyResources;
    app.destroy( app.descriptor );

    // command and synchronize
    app.destroy( app.cmd_pool );
    foreach( ref f; app.submit_fence )       app.destroy( f );
    foreach( ref s; app.acquired_semaphore ) app.destroy( s );
    foreach( ref s; app.rendered_semaphore ) app.destroy( s );
}

