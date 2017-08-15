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

    struct XForm_UBO {
        mat4        wvpm;
        float[3]    eyep = [ 0, 0, 0 ];
        float       time_step = 0.0;
    }

    // trackball
    TrackballButton             tb;                         // Trackball manipulator updating View Matrix
    XForm_UBO*                  xform_ubo;                  // World View Projection Matrix
    mat4                        projection;                 // Projection Matrix
    float                       projection_fovy =   60;     // Projection Field Of View in Y dimension
    float                       projection_near = 0.01;     // Projection near plane distance
    float                       projection_far  = 1000;     // Projection  far plane distance
    float                       eye_delta = 1;

    // surface and swapchain
    Meta_Swapchain              swapchain;
    VkSampleCountFlagBits       sample_count = VK_SAMPLE_COUNT_1_BIT;
    VkFormat                    depth_image_format = VK_FORMAT_D16_UNORM;

    // memory Resources
    Meta_Image                  depth_image;
    Meta_Buffer                 xform_ubo_buffer;
    VkMappedMemoryRange         xform_ubo_flush;
    Meta_Memory                 host_visible_memory;


    // command and related
    VkCommandPool               cmd_pool;
    VkCommandBuffer[MAX_FRAMES] cmd_buffers;    // static array alternative, see usage in module commands
    VkPipelineStageFlags        submit_wait_stage_mask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;//VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT;
    VkPresentInfoKHR            present_info;
    VkSubmitInfo                submit_info;


    // synchronize
    VkFence[ MAX_FRAMES ]       submit_fence;
    VkSemaphore                 acquired_semaphore;
    VkSemaphore                 rendered_semaphore;
    uint32_t                    next_image_index;


    // one descriptor for all purposes
    Core_Descriptor             descriptor;
    Meta_Descriptor_Update      sim_descriptor_update;  // updating the descriptor in the case of reconstructed sim resources


    // render setup
    Meta_Renderpass             render_pass;
    Core_Pipeline               graphics_pso;
    Core_Pipeline               comp_loop_pso;
    Core_Pipeline               comp_init_pso;
    VkPipelineCache             graphics_cache;
    VkPipelineCache             compute_cache;
    Meta_FB!( 4, 2 )            framebuffers;
    VkViewport                  viewport;               // dynamic state viewport
    VkRect2D                    scissors;               // dynamic state scissors


    // simulation resources
    VkCommandPool               sim_cmd_pool;           // we do not reset this on window resize events
    VkCommandBuffer[2]          sim_cmd_buffers;        // using ping pong approach for now
    Meta_Image                  sim_image;              // output macroscopic moments density and velocity
    float*                      sim_image_ptr;          // pointer to the mapped image
    Meta_Buffer                 sim_buffer;             // mesoscopic velocity populations
    Meta_Memory                 sim_memory;             // memory backing image and buffer
    VkBufferView                sim_buffer_view;        // arbitrary count of buffer views, dynamic resizing is not that easy as we would have to recreate the descriptor set each time
    Meta_Buffer                 compute_ubo_buffer;
    VkMappedMemoryRange         compute_ubo_flush;

    Meta_Buffer                 sim_stage_buffer;



    // visualization resources
    Meta_Buffer                 display_ubo_buffer;
    VkMappedMemoryRange         display_ubo_flush;
    uint32_t                    sim_particle_count = 16 * 1024;
    Meta_Buffer                 sim_particle_buffer;
    VkBufferView                sim_particle_buffer_view;
    Core_Pipeline               comp_part_pso;
    Core_Pipeline               draw_part_pso;
    Core_Pipeline               draw_line_pso;


    // export resources
    Core_Pipeline               comp_export_pso;
    Meta_Memory                 export_memory;
    Meta_Buffer                 export_buffer;
    VkBufferView                export_buffer_view;
    Meta_Descriptor_Update      export_descriptor_update;  // update only the export descriptor
    void*                       export_data;


    /////////////////////////////////////////////////
    // simulation configuration and auxiliary data //
    /////////////////////////////////////////////////

    // compute parameters
    uint32_t[3] sim_domain                  = [ 256, 25, 1 ];   // [ 256, 64, 1 ];
    uint32_t    sim_layers                  = 17;
    uint32_t[3] sim_work_group_size         = [ 256, 1, 1 ];
    uint32_t    sim_ping_pong               = 1;

    string      sim_init_shader             = "shader\\init_D2Q9.comp";
    string      sim_loop_shader             = "shader\\loop_D2Q9_channel_flow.comp";
    string      export_shader               = "shader\\export_from_image.comp";

    struct Compute_UBO {
        float       collision_frequency     = 1;    // sim param omega
        float       wall_velocity           = 0;    // sim param for lid driven cavity
    }

    // simulation parameters
    immutable float sim_unit_speed_of_sound = 0.5773502691896258; // 1 / sqrt( 3 );
    float           sim_speed_of_sound      = sim_unit_speed_of_sound;
    float           sim_unit_spatial        = 1;
    float           sim_unit_temporal       = 1;
    uint32_t        sim_algorithm           = 0; //3;
    uint32_t        sim_index               = 0;

    struct Display_UBO {
        uint32_t    display_property        = 0;    // display param display
        float       amplify_property        = 1;    // display param amplify param
        uint32_t    color_layers            = 0;
    }

    Compute_UBO*    compute_ubo;
    Display_UBO*    display_ubo;


    // flags Todo(pp): create a proper uint32_t flag structure
    bool            sim_shader_double       = false;
    bool            sim_use_double          = false;
    bool            sim_use_3_dim           = false;
    bool            sim_use_cpu             = false;

    bool            export_as_vector        = true;


    // window resize callback result
    bool            window_resized          = false;
}





nothrow:


// convenience functions for perspective computations in main
auto windowWidth(  ref VDrive_State vd ) { return vd.swapchain.imageExtent.width;  }
auto windowHeight( ref VDrive_State vd ) { return vd.swapchain.imageExtent.height; }


void updateWVPM( ref VDrive_State vd ) {
    vd.xform_ubo.wvpm = vd.projection * vd.tb.matrix;
    vd.xform_ubo.eyep = vd.tb.eye;
    vd.device.vkFlushMappedMemoryRanges( 1, &vd.xform_ubo_flush );
    //vk.device.vkInvalidateMappedMemoryRanges( 1, &wvpm_ubo_flush );
}


void updateComputeUBO( ref VDrive_State vd ) {
    // data will be updated elsewhere
    vd.device.vkFlushMappedMemoryRanges( 1, &vd.compute_ubo_flush );
}


void updateDisplayUBO( ref VDrive_State vd ) {
    // data will be updated elsewhere
    vd.device.vkFlushMappedMemoryRanges( 1, &vd.display_ubo_flush );
}


/// Scale the display based on the aspect(s) of vd.sim_domain
/// Parameter signals dimension count, 2D vs 3D
/// Params:
///     vd = reference to this modules VDrive_State struct
///     dim = the current dimensions
/// Returns: scale factor for the plane or box, in the fomer case result[2] should be ignored
float[3] simDisplayScale( ref VDrive_State vd, int dim ) {
    float scale = vd.sim_domain[0] < vd.sim_domain[1] ? vd.sim_domain[0] : vd.sim_domain[1];
    if( dim > 2 && vd.sim_domain[2] < vd.sim_domain[0] && vd.sim_domain[2] < vd.sim_domain[1] )
        scale = vd.sim_domain[2];
    float[3] result;
    result[] = vd.sim_domain[] / scale;
    return result;
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

    // recreate swapchain and other dependent resources
    try {
        //swapchain.create_info.imageExtent  = VkExtent2D( win_w, win_h );  // Set the desired swapchain extent, this might change at swapchain creation
        import resources : resizeRenderResources;
        vd.resizeRenderResources;   // destroy old and recreate window size dependant resources

    } catch( Exception ) {}
}


// this is used in windowResizeCallback
// there only a VDrive_State pointer is available and we avoid ugly dereferencing
void swapchainExtent( VDrive_State* vd, uint32_t win_w, uint32_t win_h ) {
    vd.swapchain.create_info.imageExtent = VkExtent2D( win_w, win_h );
}


// update projection matrix from member data _fovy, _near, _far
// and the swapchain extent converted to aspect
void updateProjection( ref VDrive_State vd ) {
    import dlsl.projection;
    vd.projection = vkPerspective( vd.projection_fovy, cast( float )vd.windowWidth / vd.windowHeight, vd.projection_near, vd.projection_far );
}


void drawCmdBufferCount( ref VDrive_State vd, uint32_t count ) {
   vd.submit_info.commandBufferCount = count;
}

uint32_t drawCmdBufferCount( ref VDrive_State vd ) {
   return vd.submit_info.commandBufferCount;
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
    vd.device.vkAcquireNextImageKHR( vd.swapchain.swapchain, uint64_t.max, vd.acquired_semaphore, VK_NULL_HANDLE, &vd.next_image_index );

    // wait for finished drawing
    vd.device.vkWaitForFences( 1, &vd.submit_fence[ vd.next_image_index ], VK_TRUE, uint64_t.max );
    vd.device.vkResetFences( 1, &vd.submit_fence[ vd.next_image_index ] ).vkAssert;
}


void drawSim( ref VDrive_State vd ) @system {
    vd.sim_ping_pong = vd.sim_index % 2;    // compute new ping_pong value
    ++vd.sim_index;                         // increase the counter
    vd.draw;                                // let vulkan dance
}



void draw( ref VDrive_State vd ) @system {

    VkCommandBuffer[2] cmd_buffers = [ vd.cmd_buffers[ vd.next_image_index ], vd.sim_cmd_buffers[ vd.sim_ping_pong ]];
    vd.submit_info.pCommandBuffers = cmd_buffers.ptr;
    vd.graphics_queue.vkQueueSubmit( 1, &vd.submit_info, vd.submit_fence[ vd.next_image_index ] );   // or VK_NULL_HANDLE, fence is only required if syncing to CPU for e.g. UBO updates per frame

    // exclude the compute buffer for the next sim step
    // module gui.draw might reenable it
    //vd.submit_info.commandBufferCount = 1;


    // present rendered image
    vd.present_info.pImageIndices = &vd.next_image_index;
    vd.swapchain.present_queue.vkQueuePresentKHR( &vd.present_info );


    // check if window was resized and handle the case
    if( vd.window_resized ) {
        vd.window_resized = false;
        vd.recreateSwapchain;
        import resources : createResizedCommands;
        vd.createResizedCommands;
    } else if( vd.tb.dirty ) {
        vd.updateWVPM;  // this happens anyway in recreateSwapchain
        //import core.stdc.stdio : printf;
        //printf( "%d\n", (*( vd.wvpm ))[0].y );
    }

    // acquire next swapchain image
    vd.device.vkAcquireNextImageKHR( vd.swapchain.swapchain, uint64_t.max, vd.acquired_semaphore, VK_NULL_HANDLE, &vd.next_image_index );

    // wait for finished drawing
    vd.device.vkWaitForFences( 1, &vd.submit_fence[ vd.next_image_index ], VK_TRUE, uint64_t.max );
    vd.device.vkResetFences( 1, &vd.submit_fence[ vd.next_image_index ] ).vkAssert;


}

