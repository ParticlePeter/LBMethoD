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
void createCommandObjects( ref VDrive_State vd, VkCommandPoolCreateFlags command_pool_create_flags = 0 ) {

    //
    // create command pools
    //

    // one to process and display graphics, this one is rest on window resize events
    vd.cmd_pool = vd.createCommandPool( vd.graphics_queue_family_index, command_pool_create_flags );

    // one for compute operations, not reset on window resize events
    vd.vs.sim_cmd_pool = vd.createCommandPool( vd.graphics_queue_family_index );



    //
    // create fence and semaphores
    //

    // must create all fences as we don't know the swapchain image count yet
    // but we also don't want to recreate fences in window resize events and keep track how many exist
    foreach( ref fence; vd.submit_fence )
        fence = vd.createFence( VK_FENCE_CREATE_SIGNALED_BIT ); // fence to sync CPU and GPU once per frame


    // rendering and presenting semaphores for VkSubmitInfo, VkPresentInfoKHR and vkAcquireNextImageKHR
    foreach( i; 0 .. vd.MAX_FRAMES ) {
        vd.acquired_semaphore[i] = vd.createSemaphore;    // signaled when a new swapchain image is acquired
        vd.rendered_semaphore[i] = vd.createSemaphore;    // signaled when submitted command buffer(s) complete execution
    }



    //
    // configure submit and present infos
    //

    // draw submit info for vkQueueSubmit
    with( vd.submit_info ) {
        waitSemaphoreCount      = 1;
        pWaitSemaphores         = & vd.acquired_semaphore[0];
        pWaitDstStageMask       = & vd.submit_wait_stage_mask;  // configured before entering createResources func
        commandBufferCount      = 1;
    //  pCommandBuffers         = & vd.cmd_buffers[ i ];        // set before submission, choosing cmd_buffers[0/1]
        signalSemaphoreCount    = 1;
        pSignalSemaphores       = & vd.rendered_semaphore[0];
    }

    // initialize present info for vkQueuePresentKHR
    with( vd.present_info ) {
        waitSemaphoreCount      = 1;
        pWaitSemaphores         = & vd.rendered_semaphore[0];
        swapchainCount          = 1;
        pSwapchains             = & vd.swapchain.swapchain;
    //  pImageIndices           = & next_image_index;           // set before presentation, using the acquired next_image_index
    //  pResults                = null;                         // per swapchain prsentation results, redundant when using only one swapchain
    }
}



//////////////////////////////////////////////
// create simulation related memory objects //
//////////////////////////////////////////////
void createMemoryObjects( ref VDrive_State vd ) {

    // create static memory resources which will be referenced in descriptor set
    // the corresponding createDescriptorSet function might be overwritten somewhere else

    //
    // create uniform buffers - called once
    //

    // create transformation ubo buffer withour memory backing
    import dlsl.matrix;
    vd.xform_ubo_buffer( vd )
        .create( VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, VDrive_State.XForm_UBO.sizeof );


    // create compute ubo buffer without memory backing
    vd.vs.compute_ubo_buffer( vd )
        .create( VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, VDrive_Simulate_State.Compute_UBO.sizeof );


    // create display ubo buffer without memory backing
    vd.vv.display_ubo_buffer( vd )
        .create( VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, VDrive_Visualize_State.Display_UBO.sizeof );


    // create host visible memory for ubo buffers and map it
    auto mapped_memory = vd.host_visible_memory( vd )
        .memoryType( VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT )
        .addRange( vd.xform_ubo_buffer )
        .addRange( vd.vs.compute_ubo_buffer )
        .addRange( vd.vv.display_ubo_buffer )
        .allocate
        .bind( vd.xform_ubo_buffer )
        .bind( vd.vs.compute_ubo_buffer )
        .bind( vd.vv.display_ubo_buffer )
        .mapMemory;                         // map the memory object persistently

    // cast the mapped memory pointer without offset into our transformation matrix
    vd.xform_ubo = cast( VDrive_State.XForm_UBO* )mapped_memory;                       // cast to mat4
    vd.xform_ubo_flush = vd.xform_ubo_buffer.createMappedMemoryRange; // specify mapped memory range for the wvpm ubo
    vd.updateProjection;    // update projection matrix from member data _fovy, _near, _far and aspect of the swapchain extent
    vd.updateWVPM;          // multiply projection with trackball (view) matrix and upload to uniform buffer


    // cast the mapped memory pointer with its offset into the backing memory to our compute ubo struct and init_pso the memory
    vd.vs.compute_ubo = cast( VDrive_Simulate_State.Compute_UBO* )( mapped_memory + vd.vs.compute_ubo_buffer.memOffset );
    vd.vs.compute_ubo_flush = vd.vs.compute_ubo_buffer.createMappedMemoryRange; // specify mapped memory range for the compute ubo
    vd.vs.compute_ubo.collision_frequency = 1 / 0.504;
    vd.vs.compute_ubo.wall_velocity  = 0.005 * 3; //0.25 * 3;// / vd.vs.speed_of_sound / vd.vs.speed_of_sound;
    vd.vs.compute_ubo.wall_thickness = 3;
    vd.vs.compute_ubo.comp_index = 0;
    vd.updateComputeUBO;


    // cast the mapped memory pointer with its offset into the backing memory to our display ubo struct and init_pso the memory
    vd.vv.display_ubo = cast( VDrive_Visualize_State.Display_UBO* )( mapped_memory + vd.vv.display_ubo_buffer.memOffset );
    vd.vv.display_ubo_flush = vd.vv.display_ubo_buffer.createMappedMemoryRange; // specify mapped memory range for the display ubo
    vd.vv.display_ubo.display_property = 3;
    vd.vv.display_ubo.amplify_property = 1;
    vd.vv.display_ubo.color_layers = 0;
    vd.vv.display_ubo.z_layer = 0;
    vd.updateDisplayUBO;



    //
    // create simulation memory objects - called several times
    //
    return vd.createSimMemoryObjects;
}



///////////////////////////////////////////
/// create or recreate simulation images //
///////////////////////////////////////////
void createSimImage( ref VDrive_State vd ) {

    // 1) (re)create Image
    if( vd.vs.sim_image.image != VK_NULL_HANDLE ) {
        vd.graphics_queue.vkQueueWaitIdle;
        vd.vs.sim_image.destroyResources( false );  // destroy old image and its view, keeping the sampler
    }

    // Todo(pp): the format should be choose-able
    // Todo(pp): here checks are required if this image format is available for VK_IMAGE_USAGE_STORAGE_BIT
    //import vdrive.util.info;
    //vd.imageFormatProperties(
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
        layerCount      : vd.vs.sim_domain[2],
    };
    vd.vs.sim_image( vd )
        .create(
            image_format,
            vd.vs.sim_domain[0], vd.vs.sim_domain[1], 0,      // through the 0 we request a VK_IMAGE_TYPE_2D
            1, vd.vs.sim_domain[2],                        // mip levels and array layers
            VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_STORAGE_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            VK_SAMPLE_COUNT_1_BIT,
            VK_IMAGE_TILING_OPTIMAL     // : VK_IMAGE_TILING_LINEAR
            )
        .createMemory( VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT )    // : VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT )   // Todo(pp): check which memory property is required for the image format
        .createView( subresource_range, VK_IMAGE_VIEW_TYPE_2D_ARRAY, image_format );


    // transition VkImage from layout VK_IMAGE_LAYOUT_UNDEFINED into layout VK_IMAGE_LAYOUT_GENERAL for compute shader access
    auto init_cmd_buffer = vd.allocateCommandBuffer( vd.cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY );
    auto init_cmd_buffer_bi = createCmdBufferBI( VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT );
    init_cmd_buffer.vkBeginCommandBuffer( & init_cmd_buffer_bi );

    // record image layout transition to VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
    init_cmd_buffer.recordTransition(
        vd.vs.sim_image.image,
        vd.vs.sim_image.subresourceRange,
        VK_IMAGE_LAYOUT_UNDEFINED,
        VK_IMAGE_LAYOUT_GENERAL,
        0,  // no access mask required here
        VK_ACCESS_SHADER_WRITE_BIT,
        VK_PIPELINE_STAGE_HOST_BIT,
        VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT );

    init_cmd_buffer.vkEndCommandBuffer;                     // finish recording and submit the command
    auto submit_info = init_cmd_buffer.queueSubmitInfo;     // submit the command buffer
    vd.graphics_queue.vkQueueSubmit( 1, & submit_info, VK_NULL_HANDLE ).vkAssert;

    // staging buffer for cpu computed velocity copy to the sim_image
    if( vd.vc.sim_stage_buffer.is_constructed ) {
        vd.graphics_queue.vkQueueWaitIdle;
        vd.vc.sim_stage_buffer.destroyResources;  // destroy old image and its view, keeping the sampler
    }

    uint32_t buffer_size = 4 * vd.vs.sim_domain[0] * vd.vs.sim_domain[1];     // only in 2D and with VK_FORMAT_R32G32B32A32_SFLOAT
    uint32_t buffer_mem_size = buffer_size * float.sizeof.toUint;

    vd.vc.sim_image_ptr = cast( float* )( vd.vc.sim_stage_buffer( vd )
        .create( VK_BUFFER_USAGE_TRANSFER_SRC_BIT, buffer_mem_size )
        .createMemory( VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT )
        .mapMemory );

}



//////////////////////////////////////////////////////////////
// create or recreate simulation memory, buffers and images //
//////////////////////////////////////////////////////////////
void createSimMemoryObjects( ref VDrive_State vd ) {
    vd.createSimBuffer;
    vd.createSimImage;
    vd.createParticleBuffer;
}



///////////////////////////
// create descriptor set //
///////////////////////////
void createDescriptorSet( ref VDrive_State vd, Meta_Descriptor* meta_descriptor_ptr = null ) {

    // configure descriptor set with required descriptors
    // the descriptor set will be constructed in createRenderRecources
    // immediately before creating the first pipeline so that additional
    // descriptors can be added through other means before finalizing
    // maybe we even might overwrite it completely in a parent struct

    // this is required if no Meta Descriptor has been passed in from the outside
    Meta_Descriptor meta_descriptor = vd;
    if( meta_descriptor_ptr is null ) {
        meta_descriptor_ptr = & meta_descriptor;
    }


    Meta_Sampler meta_sampler;
    vd.vs.sim_image.sampler = meta_sampler( vd )
    //  .addressMode( VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER, VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER, VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER )
        .unnormalizedCoordinates( VK_TRUE )
        .construct
        .sampler;

    // reuse Meta_sampler to construct a new nearest neighbor sampler
    vd.vs.nearest_sampler = meta_sampler
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
        .addBufferInfo( vd.xform_ubo_buffer.buffer )

        // Main Compute Buffer for populations
        .addLayoutBinding( 2, VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, VK_SHADER_STAGE_COMPUTE_BIT )
        .addTexelBufferView( vd.vs.sim_buffer_view )

        // Image to store macroscopic variables ( velocity, density ) from simulation compute shader
        .addLayoutBinding( 3, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, VK_SHADER_STAGE_COMPUTE_BIT )
        .addImageInfo( vd.vs.sim_image.image_view, VK_IMAGE_LAYOUT_GENERAL )

        // Sampler to read from macroscopic image in lines, display and export shader
        .addLayoutBinding/*Immutable*/( 4, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT | VK_SHADER_STAGE_COMPUTE_BIT )
        .addImageInfo( vd.vs.sim_image.image_view, VK_IMAGE_LAYOUT_GENERAL, vd.vs.sim_image.sampler )
        .addImageInfo( vd.vs.sim_image.image_view, VK_IMAGE_LAYOUT_GENERAL, vd.vs.nearest_sampler )        // additional sampler if we want to examine each node

        // Compute UBO for compute parameter
        .addLayoutBinding( 5, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, VK_SHADER_STAGE_COMPUTE_BIT | VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT )
        .addBufferInfo( vd.vs.compute_ubo_buffer.buffer )

        // Display UBO for display parameter
        .addLayoutBinding( 6, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT )
        .addBufferInfo( vd.vv.display_ubo_buffer.buffer )

        // Particle Buffer
        .addLayoutBinding( 7, VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, VK_SHADER_STAGE_VERTEX_BIT )
        .addTexelBufferView( vd.vv.particle_buffer_view )

        // Export Buffer views will be set and written when export is activated
        .addLayoutBinding( 8, VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, VK_SHADER_STAGE_COMPUTE_BIT, 2 );
        //.addTexelBufferView( vd.export_buffer_view[0] );
        //.addTexelBufferView( vd.export_buffer_view[1] );



    // The app crashes here in construct sometimes, and it is not clear why
    // In Debug mode we see that some undefined exception is thrown, which cannot be caught here
    // The error seems to be unrelated to this section, check all the steps taken before this occurs
    // Exit Code: -1073740940 (FFFFFFFFC0000374)
    // ---
    // New insight tells us that this is a memory corruption which only occurs when using immutable samplers

    vd.descriptor = ( *meta_descriptor_ptr ).construct.reset;


    // prepare simulation data descriptor update
    // necessary when we recreate resources and have to rebind them to our descriptors
    vd.sim_descriptor_update( vd )
        .addBindingUpdate( 2, VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER )
        .addTexelBufferView( vd.vs.sim_buffer_view )

        .addBindingUpdate( 3, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE )
        .addImageInfo( vd.vs.sim_image.image_view, VK_IMAGE_LAYOUT_GENERAL )

        .addBindingUpdate/*Immutable*/( 4, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER ) // immutable does not filter properly, module descriptor bug
        .addImageInfo( vd.vs.sim_image.image_view, VK_IMAGE_LAYOUT_GENERAL, vd.vs.sim_image.sampler )
        .addImageInfo( vd.vs.sim_image.image_view, VK_IMAGE_LAYOUT_GENERAL, vd.vs.nearest_sampler )

        .addBindingUpdate( 7, VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER )
        .addTexelBufferView( vd.vv.particle_buffer_view )

        .attachSet( vd.descriptor.descriptor_set );

    // this one is solely for export data purpose to be absolute lazy about resource construction
    // which is only necessary if we export at all
    vd.ve.export_descriptor_update( vd )
    //  .addBindingUpdate( 8, VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, 2 )  // Todo(pp): This variant should work, but it doesn't, see exportstate line 221
        .addBindingUpdate( 8, VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER )
        .addTexelBufferView( vd.ve.export_buffer_view[0] )
        .addTexelBufferView( vd.ve.export_buffer_view[1] )
        .attachSet( vd.descriptor.descriptor_set );
}



//////////////////////////////////
// create descriptor set update //
//////////////////////////////////
void updateDescriptorSet( ref VDrive_State vd ) {

    // update the descriptor
    vd.sim_descriptor_update.texel_buffer_views[0]    = vd.vs.sim_buffer_view;             // populations buffer and optionally other data like temperature
    vd.sim_descriptor_update.image_infos[0].imageView = vd.vs.sim_image.image_view;        // image view for writing from compute shader
    vd.sim_descriptor_update.image_infos[1].imageView = vd.vs.sim_image.image_view;        // image view for reading in display fragment shader with linear  sampling
    vd.sim_descriptor_update.image_infos[2].imageView = vd.vs.sim_image.image_view;        // image view for reading in display fragment shader with nearest sampling
    vd.sim_descriptor_update.texel_buffer_views[1] = vd.vv.particle_buffer_view;       // particles to visualize LBM velocity
    vd.sim_descriptor_update.update;

    // Note(pp):
    // it would be more efficient to create another descriptor update for the sim_buffer_particle_view
    // it will most likely not be updated with the other resources and vice versa
    // but ... what the heck ... for now ... we won't update both of them often enough
}



/////////////////////////////////
// create default graphics PSO //
/////////////////////////////////
void createGraphicsPSO( ref VDrive_State vd ) {

    // if we are recreating an old pipeline exists already, destroy it first
    if( vd.vv.display_pso.pipeline != VK_NULL_HANDLE ) {
        vd.graphics_queue.vkQueueWaitIdle;
        vd.destroy( vd.vv.display_pso );
    }

    // create the pso
    Meta_Graphics meta_graphics;
    vd.vv.display_pso = meta_graphics( vd )
        .addShaderStageCreateInfo( vd.createPipelineShaderStage( "shader/draw_display.vert" ))
        .addShaderStageCreateInfo( vd.createPipelineShaderStage( "shader/draw_display.frag" ))
        .inputAssembly( VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP )                      // set the inputAssembly
        .addViewportAndScissors( VkOffset2D( 0, 0 ), vd.swapchain.imageExtent )     // add viewport and scissor state, necessary even if we use dynamic state
        .cullMode( VK_CULL_MODE_BACK_BIT )                                          // set rasterization state
        .depthState                                                                 // set depth state - enable depth test with default attributes
        .addColorBlendState( VK_FALSE )                                             // color blend state - append common (default) color blend attachment state
        .addDynamicState( VK_DYNAMIC_STATE_VIEWPORT )                               // add dynamic states viewport
        .addDynamicState( VK_DYNAMIC_STATE_SCISSOR )                                // add dynamic states scissor
        .addDescriptorSetLayout( vd.descriptor.descriptor_set_layout )              // describe pipeline layout
        .addPushConstantRange( VK_SHADER_STAGE_VERTEX_BIT, 0, 8 )                   // specify push constant range
        .renderPass( vd.render_pass.render_pass )                                   // describe compatible render pass
        .construct( vd.vv.graphics_cache )                                             // construct the Pipleine Layout and Pipleine State Object (PSO) with a Pipeline Cache
        .destroyShaderModules                                                       // shader modules compiled into pipeline, not shared, can be deleted now
        .reset;                                                                     // extract core data into Core_Pipeline struct

}



/////////////////////////////
// create render resources //
/////////////////////////////
void createRenderResources( ref VDrive_State vd ) {

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
    vd.swapchain( vd )
        .selectSurfaceFormat( request_format )
        .selectPresentMode( request_mode )
        .minImageCount( 2 ) // MAX_FRAMES
        .imageArrayLayers( 1 )
        .imageUsage( VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT );
        // delay .construct; call to finalize in a later step



    //
    // create render pass
    //
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



    //
    // create pipeline cache for the graphics and compute pipelines
    //
    vd.vv.graphics_cache   = vd.createPipelineCache;   // create once, but will be used several times in createGraphicsPSO


    //
    // create pipelines and compute resources
    //
    vd.createGraphicsPSO;       // to draw the display plane
    vd.createParticlePSO;       // particle pso to visualize influnece of velocity field
    vd.createLinePSO;           // line /  PSO to draw velocity lines coordinate axis, grid and 3D bounding box
    vd.createComputeResources;  // create all resources for the compute pipeline
}



////////////////////////////////////////////////
// (re)create window size dependent resources //
////////////////////////////////////////////////
void resizeRenderResources( ref VDrive_State vd ) {

    //
    // (re)construct the already parametrized swapchain
    //
    vd.swapchain.construct;

    // set the corresponding present info member to the (re)constructed swapchain
    vd.present_info.pSwapchains = & vd.swapchain.swapchain;



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
    auto depth_image_memory_property = vd.memory_properties.hasMemoryHeapType( VK_MEMORY_HEAP_DEVICE_LOCAL_BIT )
        ? VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT
        : VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT;

    // vd.depth_image_format can be set before this function gets called
    vd.depth_image( vd )
        .create( vd.depth_image_format, vd.windowWidth, vd.windowHeight, VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT, vd.sample_count )
        .createMemory( depth_image_memory_property )
        .createView( VK_IMAGE_ASPECT_DEPTH_BIT );



    //
    // record transition of depth image from VK_IMAGE_LAYOUT_UNDEFINED to VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
    //

    // Note: allocate one command buffer
    // cmd_buffer is an Array!VkCommandBuffer
    // the array itself will be destroyed after this scope
    auto cmd_buffer = vd.allocateCommandBuffer( vd.cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY );

    VkCommandBufferBeginInfo cmd_buffer_begin_info = {
        flags : VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, };
    vkBeginCommandBuffer( cmd_buffer, & cmd_buffer_begin_info );

    cmd_buffer.recordTransition(
        vd.depth_image.image,
        vd.depth_image.image_view_create_info.subresourceRange,
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
    vd.graphics_queue.vkQueueSubmit( 1, & submit_info, VK_NULL_HANDLE ).vkAssert;



    //
    // create framebuffers
    //
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
            .addClearValue( 0.0f, 0.0f, 0.0f, 1.0f );   // add color clear value

    // attach one of the framebuffers, the render area and clear values to the render pass begin info
    // Note: attaching the framebuffer also sets the clear values and render area extent into the render pass begin info
    // setting clear values corresponding to framebuffer attachments and framebuffer extent could have happend before, e.g.:
    //      vd.render_pass.clearValues( some_clear_values );
    //      vd.render_pass.begin_info.renderArea = some_render_area;
    // but meta framebuffer(s) has a member for them, hence no need to create and manage extra storage/variables
    vd.render_pass.attachFramebuffer( vd.framebuffers, 0 );



    //
    // update dynamic viewport and scissor state
    //
    vd.viewport = VkViewport( 0, 0, vd.swapchain.imageExtent.width, vd.swapchain.imageExtent.height, 0, 1 );
    vd.scissors = VkRect2D( VkOffset2D( 0, 0 ), vd.swapchain.imageExtent );

}



///////////////////////////////////
// (re)create draw loop commands //
///////////////////////////////////
void createResizedCommands( ref VDrive_State vd ) nothrow {

    // we need to do this only if the gui is not displayed
    if( vd.draw_gui ) return;

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
        cmd_buffer.vkBeginCommandBuffer( & cmd_buffer_begin_info );

        // take care of dynamic state
        cmd_buffer.vkCmdSetViewport( 0, 1, & vd.viewport );
        cmd_buffer.vkCmdSetScissor(  0, 1, & vd.scissors );

        // bind descriptor set
        cmd_buffer.vkCmdBindDescriptorSets(     // VkCommandBuffer              commandBuffer
            VK_PIPELINE_BIND_POINT_GRAPHICS,    // VkPipelineBindPoint          pipelineBindPoint
            vd.vv.display_pso.pipeline_layout,     // VkPipelineLayout             layout
            0,                                  // uint32_t                     firstSet
            1,                                  // uint32_t                     descriptorSetCount
            & vd.descriptor.descriptor_set,     // const( VkDescriptorSet )*    pDescriptorSets
            0,                                  // uint32_t                     dynamicOffsetCount
            null                                // const( uint32_t )*           pDynamicOffsets
        );

        // begin the render pass
        cmd_buffer.vkCmdBeginRenderPass( & vd.render_pass.begin_info, VK_SUBPASS_CONTENTS_INLINE );

        // bind lbmd display plane pipeline and draw
        if( vd.draw_display ) {

            cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_GRAPHICS, vd.vv.display_pso.pipeline );

            // push constant the sim display scale
            float[2] sim_domain = [ vd.vs.sim_domain[0], vd.vs.sim_domain[1] ];
            cmd_buffer.vkCmdPushConstants( vd.vv.display_pso.pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, sim_domain.sizeof, sim_domain.ptr );

            // buffer-less draw with build in gl_VertexIndex exclusively to generate position and tex_coord data
            cmd_buffer.vkCmdDraw( 4, 1, 0, 0 ); // vertex count, instance count, first vertex, first instance
        }

        // bind particle pipeline and draw
        if( vd.draw_particles ) {
            cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_GRAPHICS, vd.vv.particle_pso.pipeline );
            cmd_buffer.vkCmdPushConstants( vd.vv.particle_pso.pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, vd.vv.particle_pc.sizeof, & vd.vv.particle_pc );
            cmd_buffer.vkCmdDraw( vd.vv.particle_count, 1, 0, 0 ); // vertex count, instance count, first vertex, first instance
        }

        // end the render pass
        cmd_buffer.vkCmdEndRenderPass;

        // end command buffer recording
        cmd_buffer.vkEndCommandBuffer;
    }


    // as we have reset the complete command pool, we must also recreate the particle reset command buffer
    import visualize : createParticleResetCmdBuffer;
    vd.createParticleResetCmdBuffer;
}



//////////////////////////////
// destroy vulkan resources //
//////////////////////////////
void destroyResources( ref VDrive_State vd ) {

    import erupted, vdrive, exportstate, cpustate;

    vd.device.vkDeviceWaitIdle;

    // destroy vulkan category resources
    vd.destroyVisResources; // Visualize
    vd.destroySimResources; // Simulate
    vd.destroyExpResources; // Export
    vd.destroyCpuResources; // Cpu

    // surface, swapchain and present image views
    vd.swapchain.destroyResources;

    // memory Resources
    vd.depth_image.destroyResources;
    vd.xform_ubo_buffer.destroyResources;
    vd.host_visible_memory.unmapMemory.destroyResources;

    // render setup
    vd.render_pass.destroyResources;
    vd.framebuffers.destroyResources;
    vd.destroy( vd.descriptor );

    // command and synchronize
    vd.destroy( vd.cmd_pool );
    foreach( ref f; vd.submit_fence )       vd.destroy( f );
    foreach( ref s; vd.acquired_semaphore ) vd.destroy( s );
    foreach( ref s; vd.rendered_semaphore ) vd.destroy( s );
    
}

