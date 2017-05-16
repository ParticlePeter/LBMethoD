//module appstate;

import derelict.glfw3;
import dlsl.matrix;
import erupted;
import vdrive;
import input;





struct VDrive_State {

    enum                        MAX_FRAMES = 2;

    // initialize
    Vulkan                      vk;
    alias                       vk this;
    VkQueue                     graphics_queue;
    uint32_t                    graphics_queue_family_index; // required for command pool
    GLFWwindow*                 window;
    VkDebugReportCallbackEXT    debugReportCallback;

    // trackball
    TrackballButton             tb;                         // Trackball manipulator updating View Matrix
    mat4*                       wvpm;                       // World View Projection Matrix
    mat4                        projection;                 // Projection Matrix
    float                       projection_fovy =   60;     // Projection Field Of View in Y dimension
    float                       projection_near = 0.01;     // Projection near plane distance
    float                       projection_far  = 1000;     // Projection  far plane distance
    float                       eye_delta = 1;

    // surface and swapchain
    Meta_Surface                surface;
    VkSampleCountFlagBits       sample_count = VK_SAMPLE_COUNT_1_BIT;
    VkFormat                    depth_image_format = VK_FORMAT_D16_UNORM;

    // memory Resources
    Meta_Image                  depth_image;
    Meta_Buffer                 wvpm_buffer;
    VkMappedMemoryRange         wvpm_flush;

    // command and related
    VkCommandPool               cmd_pool;
    VkCommandBuffer[MAX_FRAMES] cmd_buffers;    // static array alternative, see usage in module commands
    VkPipelineStageFlags        submit_wait_stage_mask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;//VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT;
    VkPresentInfoKHR            present_info;
    VkSubmitInfo                submit_info;

    // synchronize
    VkFence[MAX_FRAMES]         submit_fence;
    VkSemaphore                 acquired_semaphore;
    VkSemaphore                 rendered_semaphore;
    uint32_t                    next_image_index;

    // render setup
    Meta_Renderpass             render_pass;
    Core_Descriptor             descriptor;
    Core_Pipeline               graphics_pso;
    Core_Pipeline               compute_pso;
    Meta_Framebuffers           framebuffers;

    // dynamic state
    import dlsl.vector;

    // simulation resources
    VkCommandPool               sim_cmd_pool;           // we do not reset this on window resize events
    VkCommandBuffer[2]          sim_cmd_buffers;        // using ping pong approach for now
    Meta_Image                  sim_image;              // output macroscopic moments density and velocity
    Meta_Buffer                 sim_buffer;             // mesoscopic velocity populations
    Meta_Memory                 sim_memory;             // memory backing image and buffer
    VkBufferView                sim_buffer_view;        // arbitrary count of buffer views, dynamic resizing is not that easy as we would have to recreate the descriptor set each time
    Meta_Descriptor_Update      sim_descriptor_update;  // updating the descriptor in the case of reconstructed sim resources
    VkSampler                   sim_sampler_nearest;
    Meta_Buffer                 sim_ubo_buffer;
    VkMappedMemoryRange         sim_ubo_flush;

    // simulation configuration and auxiliary data
    uvec3                       sim_domain          = uvec3( 256, 256, 1 );
    uint32_t                    sim_layers          = 17;
    uvec3                       sim_work_group_size = uvec3( 256, 1, 1 );
    vec3                        sim_display_scale   = vec3( 1 );
    float                       sim_unit_spatial    = 1;
    float                       sim_unit_temporal   = 1;

    struct Sim_UBO {
        float omega = 1;
        float speed = 1;
    }

    Sim_UBO*                    sim_ubo;

    ubyte                       sim_ping_pong       = 1;
    ubyte                       sim_ping_pong_scale = 8;

    VkViewport                  viewport;
    VkRect2D                    scissors;

    // window resize callback result
    bool                        window_resized = false;

    bool                        sim_step = false;
    bool                        sim_play = false;   

}

nothrow:


// convenience functions for perspective computations in main
auto windowWidth(  ref VDrive_State vd ) { return vd.surface.imageExtent.width;  }
auto windowHeight( ref VDrive_State vd ) { return vd.surface.imageExtent.height; }


void updateWVPM( ref VDrive_State vd ) {
    *( vd.wvpm ) = vd.projection * vd.tb.matrix;
    vd.device.vkFlushMappedMemoryRanges( 1, &vd.wvpm_flush );
    //vk.device.vkInvalidateMappedMemoryRanges( 1, &wvpm_flush );
}


void updateSimUBO( ref VDrive_State vd ) {
    // data will be updated elsewhere
    vd.device.vkFlushMappedMemoryRanges( 1, &vd.sim_ubo_flush );
}

void recreateSwapchain( ref VDrive_State vd ) {
    // swapchain might not have the same extent as the window dimension
    // the data we use for projection computation is the glfw window extent at this place
    vd.updateProjection;            // compute projection matrix from new window extent
    vd.updateWVPM;                  // multiplies projection trackball (view) matrix and uploads to uniform buffer

    // notify trackball manipulator about win height change, this has effect on panning speed
    vd.tb.windowHeight( vd.windowHeight );

    // wait till device is idle
    vd.device.vkDeviceWaitIdle;

    // recreate swapchain
    try {
        //surface.create_info.imageExtent  = VkExtent2D( win_w, win_h );  // Set the desired surface extent, this might change at swapchain creation
        import resources : resizeRenderResources;
        vd.resizeRenderResources;   // destroy old and recreate window size dependant resources

    } catch( Exception ) {}
}


// this is used in windowResizeCallback
// there only a VDrive_State pointer is available and we avoid ugly dereferencing
void swapchainExtent( VDrive_State* vd, uint32_t win_w, uint32_t win_h ) {
    vd.surface.create_info.imageExtent = VkExtent2D( win_w, win_h );
}


// update projection matrix from member data _fovy, _near, _far
// and the swapchain extent converted to aspect
void updateProjection( ref VDrive_State vd ) {
    import dlsl.projection;
    vd.projection = vkPerspective( vd.projection_fovy, cast( float )vd.windowWidth / vd.windowHeight, vd.projection_near, vd.projection_far );
}


void drawInit( ref VDrive_State vd ) {
    // check if window was resized and handle the case
    if( vd.window_resized ) {
        vd.window_resized = false;
        vd.recreateSwapchain;
        import resources : createResizedCommands;
        vd.createResizedCommands;
    } else if( vd.tb.dirty ) {
        vd.updateWVPM;  // this happens anyway in recreateSwapchain
    }

    // acquire next swapchain image
    vd.device.vkAcquireNextImageKHR( vd.surface.swapchain, uint64_t.max, vd.acquired_semaphore, VK_NULL_HANDLE, &vd.next_image_index );

    // wait for finished drawing
    vd.device.vkWaitForFences( 1, &vd.submit_fence[ vd.next_image_index ], VK_TRUE, uint64_t.max );
    vd.device.vkResetFences( 1, &vd.submit_fence[ vd.next_image_index ] ).vkAssert;
}



void draw( ref VDrive_State vd ) {

/*
    // submit the current lucien command buffer
    vd.submit_info.pCommandBuffers = &vd.cmd_buffers[ vd.next_image_index ]; //imgui_cmd_buffer;//&cmd_buffers[ next_image_index ];
    vd.graphics_queue.vkQueueSubmit( 1, &vd.submit_info, vd.submit_fence[ vd.next_image_index ] );   // or VK_NULL_HANDLE, fence is only required if syncing to CPU for e.g. UBO updates per frame
/*/
    // react to sim step event
    if( vd.sim_play || vd.sim_step ) {
        vd.sim_step = false;
        vd.submit_info.commandBufferCount = 2;
        vd.sim_ping_pong = cast( ubyte )( 1 - vd.sim_ping_pong );
    }

    VkCommandBuffer[2] cmd_buffers = [ vd.cmd_buffers[ vd.next_image_index ], vd.sim_cmd_buffers[ vd.sim_ping_pong ]];
    vd.submit_info.pCommandBuffers = cmd_buffers.ptr;
    vd.graphics_queue.vkQueueSubmit( 1, &vd.submit_info, vd.submit_fence[ vd.next_image_index ] );   // or VK_NULL_HANDLE, fence is only required if syncing to CPU for e.g. UBO updates per frame
    vd.submit_info.commandBufferCount = 1;
//*/


    // present rendered image
    vd.present_info.pImageIndices = &vd.next_image_index;
    vd.surface.present_queue.vkQueuePresentKHR( &vd.present_info );


    // check if window was resized and handle the case
    if( vd.window_resized ) {
        vd.window_resized = false;
        vd.recreateSwapchain;
        import resources : createResizedCommands;
        vd.createResizedCommands;
    } /*else if( vd.tb.dirty )*/ {
        vd.updateWVPM;  // this happens anyway in recreateSwapchain
        //import core.stdc.stdio : printf;
        //printf( "%d\n", (*( vd.wvpm ))[0].y );
    }

    // acquire next swapchain image
    vd.device.vkAcquireNextImageKHR( vd.surface.swapchain, uint64_t.max, vd.acquired_semaphore, VK_NULL_HANDLE, &vd.next_image_index );

    // wait for finished drawing
    vd.device.vkWaitForFences( 1, &vd.submit_fence[ vd.next_image_index ], VK_TRUE, uint64_t.max );
    vd.device.vkResetFences( 1, &vd.submit_fence[ vd.next_image_index ] ).vkAssert;


}

