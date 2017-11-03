
import derelict.glfw3;
import dlsl.matrix;
import erupted;
import vdrive;
import input;



enum Transport : uint32_t { pause, play, step, profile };


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
    float                       projection_fovy =    60;    // Projection Field Of View in Y dimension
    float                       projection_near =   0.1;    // Projection near plane distance
    float                       projection_far  = 10000;    // Projection  far plane distance
    // Todo(pp): calculate best possible near and far clip planes when manipulating the trackball

    // surface and swapchain
    Meta_Swapchain              swapchain;
    VkSampleCountFlagBits       sample_count = VK_SAMPLE_COUNT_1_BIT;
    VkFormat                    depth_image_format = VK_FORMAT_D32_SFLOAT;

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
    VkPipelineCache             graphics_cache;
    Meta_FB!( MAX_FRAMES, 2 )   framebuffers;
    VkViewport                  viewport;               // dynamic state viewport
    VkRect2D                    scissors;               // dynamic state scissors


    // simulation resources
    VkCommandPool               sim_cmd_pool;           // we do not reset this on window resize events
    VkCommandBuffer[2]          sim_cmd_buffers;        // using ping pong approach for now
    Meta_Image                  sim_image;              // output macroscopic moments density and velocity
    VkSampler                   nearest_sampler;
    Meta_Buffer                 sim_buffer;             // mesoscopic velocity populations
    Meta_Memory                 sim_memory;             // memory backing image and buffer
    VkBufferView                sim_buffer_view;        // arbitrary count of buffer views, dynamic resizing is not that easy as we would have to recreate the descriptor set each time
    Core_Pipeline               comp_loop_pso;
    Core_Pipeline               comp_init_pso;
    VkPipelineCache             compute_cache;
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
    Core_Pipeline[2]            draw_line_pso;


    // export resources
    Core_Pipeline               comp_export_pso;
    Meta_Memory                 export_memory;
    Meta_Buffer[2]              export_buffer;
    VkBufferView[2]             export_buffer_view;
    Meta_Descriptor_Update      export_descriptor_update;  // update only the export descriptor
    VkDeviceSize                export_size;
    void*[2]                    export_data;
    VkMappedMemoryRange[2]      export_mapped_range;

    import exportstate;
    VDrive_Export_State         ve;

    // cpu resources
    import cpustate;
    VDrive_Cpu_State            vc;
    float*                      sim_image_ptr;             // pointer to the mapped image


    /////////////////////////////////////////////////
    // simulation configuration and auxiliary data //
    /////////////////////////////////////////////////

    // compute parameters
    uint32_t[3] sim_domain                  = [ 256, 256, 1 ]; //[ 256, 256, 1 ];   // [ 256, 64, 1 ];
    uint32_t    sim_layers                  = 17;
    uint32_t[3] sim_work_group_size         = [ 256,  1, 1 ];
    uint32_t    sim_ping_pong               = 1;
    uint32_t    sim_step_size               = 1;

    string      sim_init_shader             = "shader\\init_D2Q9.comp";
    string      sim_loop_shader             = "shader\\loop_D2Q9_ldc.comp";
    string      export_shader               = "shader\\export_from_image.comp";

    struct Compute_UBO {
        float       collision_frequency     = 1;    // sim param omega
        float       wall_velocity           = 0;    // sim param for lid driven cavity
        uint32_t    wall_thickness          = 1;
        uint32_t    comp_index              = 0;
    }

    // simulation parameters
    immutable float sim_unit_speed_of_sound = 0.5773502691896258; // 1 / sqrt( 3 );
    float           sim_speed_of_sound      = sim_unit_speed_of_sound;
    float           sim_unit_spatial        = 1;
    float           sim_unit_temporal       = 1;
    uint32_t        sim_algorithm           = 4; // Cascaded Drag //0;
    uint32_t        sim_index               = 0;

    struct Display_UBO {
        uint32_t    display_property        = 0;    // display param display
        float       amplify_property        = 1;    // display param amplify param
        uint32_t    color_layers            = 0;
        uint32_t    z_layer                 = 0;
    }

    Compute_UBO*    compute_ubo;
    Display_UBO*    display_ubo;


    // profile data
    uint32_t        sim_profile_step_size  = 1;
    uint32_t        sim_profile_step_count = 1000;
    uint32_t        sim_profile_step_index;


    version( LDC ) {
        import std.datetime; // ldc is behind and datetime is a module and not a package yet
        StopWatch stop_watch;
        nothrow {
            void resetStopWatch()       { try { stop_watch.reset; } catch( Exception ) {} }
            void startStopWatch()       { try { stop_watch.start; } catch( Exception ) {} }
            void stopStopWatch()        { try { stop_watch.stop;  } catch( Exception ) {} }
            long getStopWatch_nsecs()   { try { return stop_watch.peek.to!( "nsecs" , long ); } catch( Exception ) { return 0; } }
            long getStopWatch_hnsecs()  { try { return stop_watch.peek.to!( "hnsecs", long ); } catch( Exception ) { return 0; } }
            long getStopWatch_usecs()   { try { return stop_watch.peek.to!( "usecs" , long ); } catch( Exception ) { return 0; } }
            long getStopWatch_msecs()   { try { return stop_watch.peek.to!( "msecs" , long ); } catch( Exception ) { return 0; } }
        }
    } else {
        import std.datetime.stopwatch; // ldc is behind and datetime is a module and not a package yet
        StopWatch stop_watch;
        nothrow {
            void resetStopWatch()       { stop_watch.reset; }
            void startStopWatch()       { stop_watch.start; }
            void stopStopWatch()        { stop_watch.stop; }
            long getStopWatch_nsecs()   { return stop_watch.peek.total!"nsecs"; }
            long getStopWatch_hnsecs()  { return stop_watch.peek.total!"hnsecs"; }
            long getStopWatch_usecs()   { return stop_watch.peek.total!"usecs"; }
            long getStopWatch_msecs()   { return stop_watch.peek.total!"msecs"; }
        }
    }



    // flags Todo(pp): create a proper uint32_t flag structure
    bool            feature_shader_double   = false;
    bool            feature_large_points    = false;
    bool            feature_wide_lines      = false;
    bool            sim_draw_plane          = true;
    bool            sim_use_double          = false;
    bool            sim_use_3_dim           = false;
    bool            sim_use_cpu             = false;
    bool            export_as_vector        = true;


    // window resize callback result
    bool            window_resized          = false;



    // new members
    // count of command buffers to be drawn when in play mode
    uint32_t    sim_play_cmd_buffer_count;
    Transport   transport = Transport.pause;
    Transport   play_mode = Transport.play;

    nothrow:



    //
    // transport control funcs
    //

    bool isPlaying() @system {
        return transport != Transport.pause;
    }

    void simPause() @system {
        transport = Transport.pause;
        drawCmdBufferCount = 1;
    }

    void simPlay() @system {
        if( transport == Transport.profile && sim_profile_step_count <= sim_profile_step_index ) {
            sim_profile_step_index = 0;
            resetStopWatch;
        }
        transport = play_mode; // Transport.play or Transport.profile;
        drawCmdBufferCount = sim_play_cmd_buffer_count;
    }

    void simStep() @system {
        if( !isPlaying ) {
            transport = Transport.step;
        }
    }


    void simReset() @system {
        if( transport == Transport.profile ) {
            sim_profile_step_index = 0;
            resetStopWatch;
        }
        sim_index = compute_ubo.comp_index = 0;
        try {
            if( sim_use_cpu ) {
                import cpustate : cpuInit; 
                this.cpuInit;
            } else {
                import compute : createBoltzmannPSO;
                this.createBoltzmannPSO( false, false, true );  // rebuild init pipeline, rebuild loop pipeline, reset domain
            }
        } catch( Exception ) {}

    }


    // convenience functions for perspective computations in main
    auto windowWidth()  { return swapchain.imageExtent.width;  }
    auto windowHeight() { return swapchain.imageExtent.height; }


    void updateWVPM() {
        xform_ubo.wvpm = projection * tb.matrix;
        xform_ubo.eyep = tb.eye;
        vk.device.vkFlushMappedMemoryRanges( 1, &xform_ubo_flush );
        //vk.device.vkInvalidateMappedMemoryRanges( 1, &wvpm_ubo_flush );
    }


    void updateComputeUBO() {
        // data will be updated elsewhere
        vk.device.vkFlushMappedMemoryRanges( 1, &compute_ubo_flush );
    }


    void updateDisplayUBO() {
        // data will be updated elsewhere
        vk.device.vkFlushMappedMemoryRanges( 1, &display_ubo_flush );
    }


    /// Scale the display based on the aspect(s) of vd.sim_domain
    /// Parameter signals dimension count, 2D vs 3D
    /// Params:
    ///     vd = reference to this modules VDrive_State struct
    ///     dim = the current dimensions
    /// Returns: scale factor for the plane or box, in the fomer case result[2] should be ignored
    float[3] simDisplayScale( int dim ) {
        float scale =  sim_domain[0] < sim_domain[1] ?  sim_domain[0] : sim_domain[1];
        if( dim > 2 && sim_domain[2] < sim_domain[0] && sim_domain[2] < sim_domain[1] )
            scale = sim_domain[2];
        float[3] result;
        result[] = sim_domain[] / scale;
        return result;
    }


    void recreateSwapchain() {
        // swapchain might not have the same extent as the window dimension
        // the data we use for projection computation is the glfw window extent at this place
        updateProjection;            // compute projection matrix from new window extent
        updateWVPM;                  // multiplies projection trackball (view) matrix and uploads to uniform buffer

        // notify trackball manipulator about win height change, this has effect on panning speed
        tb.windowHeight( windowHeight );

        // wait till device is idle
        vk.device.vkDeviceWaitIdle;

        // recreate swapchain and other dependent resources
        try {
            //swapchain.create_info.imageExtent  = VkExtent2D( win_w, win_h );  // Set the desired swapchain extent, this might change at swapchain creation
            import resources : resizeRenderResources;
            this.resizeRenderResources;   // destroy old and recreate window size dependant resources

        } catch( Exception ) {}
    }


    // this is used in windowResizeCallback
    // there only a VDrive_State pointer is available and we avoid ugly dereferencing
    void swapchainExtent( uint32_t win_w, uint32_t win_h ) {
        swapchain.create_info.imageExtent = VkExtent2D( win_w, win_h );
    }


    // update projection matrix from member data _fovy, _near, _far
    // and the swapchain extent converted to aspect
    void updateProjection() {
        import dlsl.projection;
        projection = vkPerspective( projection_fovy, cast( float )windowWidth / windowHeight, projection_near, projection_far );
    }


    void drawCmdBufferCount( uint32_t count ) {
       submit_info.commandBufferCount = count;
    }

    uint32_t drawCmdBufferCount() {
       return submit_info.commandBufferCount;
    }


    void drawInit() {
        // check if window was resized and handle the case
        if( window_resized ) {
            window_resized = false;
            recreateSwapchain;
            import resources : createResizedCommands;
            this.createResizedCommands;
        } else if( tb.dirty ) {
            updateWVPM;  // this happens anyway in recreateSwapchain
        }

        
        // acquire next swapchain image
        vk.device.vkAcquireNextImageKHR( swapchain.swapchain, uint64_t.max, acquired_semaphore, VK_NULL_HANDLE, &next_image_index );

        // wait for finished drawing
        vk.device.vkWaitForFences( 1, &submit_fence[ next_image_index ], VK_TRUE, uint64_t.max );
        vk.device.vkResetFences( 1, &submit_fence[ next_image_index ] ).vkAssert;
        
    }


    void drawStep() @system {
        drawCmdBufferCount = sim_play_cmd_buffer_count;
        this.draw_func_play;
        drawCmdBufferCount = 1;
        transport = Transport.pause;
    }


    void drawProfile() @system {
        sim_profile_step_index += sim_profile_step_size;
        this.draw_func_profile;

        if( 0 < sim_profile_step_count && sim_profile_step_index >= sim_profile_step_count ) {
            simPause;
        }
    }


    void drawDisplay() @system {

        VkCommandBuffer[2] cmd_buffers = [ cmd_buffers[ next_image_index ], sim_cmd_buffers[ sim_ping_pong ]];
        submit_info.pCommandBuffers = cmd_buffers.ptr;
        graphics_queue.vkQueueSubmit( 1, &submit_info, submit_fence[ next_image_index ] );   // or VK_NULL_HANDLE, fence is only required if syncing to CPU for e.g. UBO updates per frame

        // exclude the compute buffer for the next sim step
        // module gui.draw might reenable it
        //submit_info.commandBufferCount = 1;


        // present rendered image
        present_info.pImageIndices = &next_image_index;
        swapchain.present_queue.vkQueuePresentKHR( &present_info );


        // check if window was resized and handle the case
        if( window_resized ) {
            window_resized = false;
            recreateSwapchain;
            import resources : createResizedCommands;
            this.createResizedCommands;
        } else if( tb.dirty ) {
            updateWVPM;  // this happens anyway in recreateSwapchain
            //import core.stdc.stdio : printf;
            //printf( "%d\n", (*( wvpm ))[0].y );
        }

        // acquire next swapchain image
        vk.device.vkAcquireNextImageKHR( swapchain.swapchain, uint64_t.max, acquired_semaphore, VK_NULL_HANDLE, &next_image_index );

        // wait for finished drawing
        vk.device.vkWaitForFences( 1, &submit_fence[ next_image_index ], VK_TRUE, uint64_t.max );
        vk.device.vkResetFences( 1, &submit_fence[ next_image_index ] ).vkAssert;
    }


    void draw() {

        final switch( transport ) {
            case Transport.pause    : drawDisplay;          break;
            case Transport.play     : this.draw_func_play;  break;
            case Transport.step     : drawStep;             break;
            case Transport.profile  : drawProfile;          break;
        }
    }
}


nothrow:

//////////////////////////////////////////////////////////
// Free functions called via function pointer mechanism //
//////////////////////////////////////////////////////////

void drawSim( ref VDrive_State vd ) @system {
    vd.sim_ping_pong = vd.sim_index % 2;                            // compute new ping_pong value
    vd.compute_ubo.comp_index += vd.sim_step_size;                  // increase shader compute counter
    if( vd.sim_step_size > 1 ) vd.updateComputeUBO;                 // we need this value in compute shader if its greater than 1
    ++vd.sim_index;                                                 // increment the compute buffer submission count
    vd.drawDisplay;                                                 // let vulkan dance
}


void profileCompute( ref VDrive_State vd ) @system {

    vd.sim_ping_pong = vd.sim_index % 2;                            // compute new ping_pong value
    vd.compute_ubo.comp_index += vd.sim_step_size;                  // increase shader compute counter
    if( vd.sim_step_size > 1 ) vd.updateComputeUBO;                 // we need this value in compute shader if its greater than 1
    ++vd.sim_index;                                                 // increment the compute buffer submission count

    // edit submmit info for compute work
    with( vd.submit_info ) {
        signalSemaphoreCount    = 0;
        pSignalSemaphores       = null;
        pCommandBuffers = & vd.sim_cmd_buffers[ vd.sim_ping_pong ];
    }

    // profile compute work
    vd.startStopWatch;
    vd.graphics_queue.vkQueueSubmit( 1, &vd.submit_info, vd.submit_fence[ vd.next_image_index ] );  // or VK_NULL_HANDLE, fence is only required if syncing to CPU for e.g. UBO updates per frame
    vd.device.vkWaitForFences( 1, &vd.submit_fence[ vd.next_image_index ], VK_TRUE, uint64_t.max ); // wait for finished compute
    vd.stopStopWatch;
    vd.device.vkResetFences( 1, &vd.submit_fence[ vd.next_image_index ] ).vkAssert;


    // edit submmit info for display work
    with( vd.submit_info ) {
        waitSemaphoreCount      = 0;
        pWaitSemaphores         = null;
        pWaitDstStageMask       = null;
        signalSemaphoreCount    = 1;
        pSignalSemaphores       = &vd.rendered_semaphore;
        pCommandBuffers         = & vd.cmd_buffers[ vd.next_image_index ];
    }

    vd.graphics_queue.vkQueueSubmit( 1, &vd.submit_info, vd.submit_fence[ vd.next_image_index ] );  // or VK_NULL_HANDLE, fence is only required if syncing to CPU for e.g. UBO updates per frame
    //vd.device.vkWaitForFences( 1, &vd.submit_fence[ vd.next_image_index ], VK_TRUE, uint64_t.max ); // wait for finished compute
    //vd.device.vkResetFences( 1, &vd.submit_fence[ vd.next_image_index ] ).vkAssert;

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

    // edit submmit info to default settings
    with( vd.submit_info ) {
        waitSemaphoreCount      = 1;
        pWaitSemaphores         = &vd.acquired_semaphore;
        pWaitDstStageMask       = &vd.submit_wait_stage_mask;   // configured before entering createResources func
    }
}




////////////////////////////////////////////////////
// Draw function pointer for sim play and profile //
////////////////////////////////////////////////////

alias   Draw_Func = void function( ref VDrive_State vd ) nothrow @system;
private Draw_Func draw_func_play;
private Draw_Func draw_func_profile;


void setDefaultSimFuncs( ref VDrive_State vd ) nothrow @system {
    draw_func_play      = & drawSim;
    draw_func_profile   = & profileCompute;
    vd.sim_play_cmd_buffer_count = 2;
}


void setSimFuncPlay( Draw_Func func ) nothrow @system {
    draw_func_play = func;
}

void setSimFuncProfile( Draw_Func func ) nothrow @system {
    draw_func_profile = func;
}
