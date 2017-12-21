
import derelict.glfw3;
import dlsl.matrix;
import erupted;
import vdrive;
import input;



enum Transport : uint32_t { pause, play, step, profile };


//////////////////////////////
// application state struct //
//////////////////////////////
struct VDrive_State {

    // count of maximum per frame resources, might be less dependent on swachain image count
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
    TrackballButton             tbb;                        // Trackball manipulator updating View Matrix
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
    VkCommandBuffer[MAX_FRAMES] cmd_buffers;
    VkPipelineStageFlags        submit_wait_stage_mask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    VkPresentInfoKHR            present_info;
    VkSubmitInfo                submit_info;


    // synchronize
    VkFence[ MAX_FRAMES ]       submit_fence;
    VkSemaphore[ MAX_FRAMES ]   acquired_semaphore;
    VkSemaphore[ MAX_FRAMES ]   rendered_semaphore;
    uint32_t                    next_image_index;


    // one descriptor for all purposes
    Core_Descriptor             descriptor;
    Meta_Descriptor_Update      sim_descriptor_update;  // updating the descriptor in the case of reconstructed sim resources


    // render setup
    Meta_Renderpass             render_pass;
    Meta_FB!( MAX_FRAMES, 2 )   framebuffers;           // template count of ( VkFramebuffer, VkClearValue )
    VkViewport                  viewport;               // dynamic state viewport
    VkRect2D                    scissors;               // dynamic state scissors


    // simulate resources
    import simulate;
    VDrive_Simulate_State       sim;


    // visualize resources
    import visualize;
    VDrive_Visualize_State      vis;


    // cpu resources
    import cpustate;
    VDrive_Cpu_State            cpu;


    // export resources
    import exportstate;
    VDrive_Export_State         exp;



    //
    // Profile Simulation
    //
    uint32_t        sim_profile_step_limit = 0;
    uint32_t        sim_profile_step_count = 0;
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



    //
    // transport control data
    //
    uint32_t    sim_play_cmd_buffer_count;          // count of command buffers to be drawn when in play mode
    Transport   transport = Transport.pause;        // current transport mode
    Transport   play_mode = Transport.play;         // can be either play or profile


    // flags Todo(pp): create a proper uint32_t flag structure
    bool        feature_shader_double   = false;
    bool        feature_large_points    = false;
    bool        feature_wide_lines      = false;
    bool        draw_gui                = false;    // hidden by default in case we compile without gui
    bool        draw_scale              = true;
    bool        draw_display            = true;
    bool        draw_particles          = false;
    bool        additive_particle_blend = true;
    bool        use_double              = false;
    bool        use_3_dim               = false;
    bool        use_cpu                 = false;



    // window resize callback result
    bool        window_resized          = false;



    nothrow:

    // return window width and height stored in Meta_Swapchain struct
    auto windowWidth()  { return swapchain.imageExtent.width;  }
    auto windowHeight() { return swapchain.imageExtent.height; }


    //
    // transport control funcs
    //

    // returns whether we are paused or not
    bool isPlaying() @system {
        return transport != Transport.pause;
    }

    // pause simulation
    void simPause() @system {
        transport = Transport.pause;
        drawCmdBufferCount = 1;
    }

    // start or continue simulation
    void simPlay() @system {
        if( play_mode == Transport.profile && sim_profile_step_limit <= sim_profile_step_index ) {
            sim_profile_step_limit += sim_profile_step_count;
        }
        transport = play_mode; // Transport.play or Transport.profile;
        drawCmdBufferCount = sim_play_cmd_buffer_count;
    }

    // step with sim_step_size count of sim steps in the following draw loop step
    void simStep() @system {
        if( !isPlaying ) {
            transport = Transport.step;
        }
    }

    // reset the simulation
    void simReset() @system {
        if( play_mode == Transport.profile ) {
            sim_profile_step_index = sim_profile_step_limit = 0;
        }
        resetStopWatch;
        sim.index = sim.compute_ubo.comp_index = 0;
        try {
            if( use_cpu ) {
                import cpustate : cpuInit;
                this.cpuInit;
            } else {
                import simulate : createBoltzmannPSO;
                this.createBoltzmannPSO( false, false, true );  // rebuild init pipeline, rebuild loop pipeline, reset domain
            }
        } catch( Exception ) {}

    }


    //
    // UBO update functions
    //

    // update world view projection matrix UBO
    void updateWVPM() {
        xform_ubo.wvpm = projection * tbb.worldTransform;
        xform_ubo.eyep = tbb.eye;
        vk.device.vkFlushMappedMemoryRanges( 1, & xform_ubo_flush );
    }

    // update LBM compute UBO
    void updateComputeUBO() {
        // data will be updated elsewhere
        vk.device.vkFlushMappedMemoryRanges( 1, & sim.compute_ubo_flush );
    }

    // update display UBO of velocity and density data
    void updateDisplayUBO() {
        // data will be updated elsewhere
        vk.device.vkFlushMappedMemoryRanges( 1, & vis.display_ubo_flush );
    }


    /// Scale the display based on the aspect(s) of sim.domain
    /// Parameter signals dimension count, 2D sim 3D
    /// Params:
    ///     app = reference to this modules VDrive_State struct
    ///     dim = the current dimensions
    /// Returns: scale factor for the plane or box, in the fomer case result[2] should be ignored
    float[3] simDisplayScale( int dim ) {
        float scale =  sim.domain[0] < sim.domain[1] ?  sim.domain[0] : sim.domain[1];
        if( dim > 2 && sim.domain[2] < sim.domain[0] && sim.domain[2] < sim.domain[1] )
            scale = sim.domain[2];
        float[3] result;
        result[] = sim.domain[] / scale;
        return result;
    }


    // recreate swapchain, called initially and if window size changes
    void recreateSwapchain() {
        // swapchain might not have the same extent as the window dimension
        // the data we use for projection computation is the glfw window extent at this place
        updateProjection;            // compute projection matrix from new window extent
        updateWVPM;                  // multiplies projection trackball (view) matrix and uploads to uniform buffer

        // notify trackball manipulator about win height change, this has effect on panning speed
        tbb.windowHeight( windowHeight );

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

    //
    // set the count of command buffers which should be issued in one submission
    // this number can be 1 (draw compute result) or 2(draw compute result and simulate)
    //

    // setter
    void drawCmdBufferCount( uint32_t count ) {
       submit_info.commandBufferCount = count;
    }

    // getter
    uint32_t drawCmdBufferCount() {
       return submit_info.commandBufferCount;
    }



    // initial draw to overlap CPU recording and GPU drawing
    void drawInit() {

        // check if window was resized and handle the case
        if( window_resized ) {
            window_resized = false;
            recreateSwapchain;
            import resources : createResizedCommands;
            this.createResizedCommands;
        }

        // acquire next swapchain image, we use semaphore[0] which is also the first one on which we wait before our first real draw
        vk.device.vkAcquireNextImageKHR( swapchain.swapchain, uint64_t.max, acquired_semaphore[0], VK_NULL_HANDLE, & next_image_index );

        // reset the fence corresponding to the currently acquired image index, will be signal after next draw
        vk.device.vkResetFences( 1, & submit_fence[ next_image_index ] ).vkAssert;

    }


    // draw one simulation step with sim_step_size count of sim steps in the following draw loop step
    void drawStep() @system {
        drawCmdBufferCount = sim_play_cmd_buffer_count;
        if( play_mode == Transport.play )
            this.draw_func_play;
        else
            drawProfile;

        drawCmdBufferCount = 1;
        transport = Transport.pause;
    }


    // increments profile counter and calls draw_func_profile function pointer, which is setable
    void drawProfile() @system {
        sim_profile_step_index += sim.step_size;
        this.draw_func_profile;

        if( 0 < sim_profile_step_count && sim_profile_step_limit <= sim_profile_step_index ) {
            simPause;
        }
    }


    // draw the simulation display and step ahead in the simulation itself (if in play or profile mode)
    void drawSim() @system {

        // sellect and draw command buffers
        VkCommandBuffer[2] cmd_buffers = [ cmd_buffers[ next_image_index ], sim.cmd_buffers[ sim.ping_pong ]];
        submit_info.pCommandBuffers = cmd_buffers.ptr;
        graphics_queue.vkQueueSubmit( 1, & submit_info, submit_fence[ next_image_index ] );   // or VK_NULL_HANDLE, fence is only required if syncing to CPU for e.g. UBO updates per frame

        // present rendered image
        present_info.pImageIndices = & next_image_index;
        swapchain.present_queue.vkQueuePresentKHR( & present_info );

        // edit semaphore attachement
        submit_info.pWaitSemaphores     = & acquired_semaphore[ next_image_index ];
        submit_info.pSignalSemaphores   = & rendered_semaphore[ next_image_index ];
        present_info.pWaitSemaphores    = & rendered_semaphore[ next_image_index ];

        // check if window was resized and handle the case
        if( window_resized ) {
            window_resized = false;
            recreateSwapchain;
            import resources : createResizedCommands;
            this.createResizedCommands;
        }

        // acquire next swapchain image
        vk.device.vkAcquireNextImageKHR( swapchain.swapchain, uint64_t.max, acquired_semaphore[ next_image_index ], VK_NULL_HANDLE, & next_image_index );

        // wait for finished drawing
        vk.device.vkWaitForFences( 1, & submit_fence[ next_image_index ], VK_TRUE, uint64_t.max );
        vk.device.vkResetFences( 1, & submit_fence[ next_image_index ] ).vkAssert;
    }


    // dispatch function based on the transport mode
    void draw() {

        final switch( transport ) {
            case Transport.pause    : drawSim;              break;
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

// compute ping pong, increment sim counter and draw the sim result
void playSim( ref VDrive_State app ) @system {
    app.sim.ping_pong = app.sim.index % 2;                  // compute new ping_pong value
    app.sim.compute_ubo.comp_index += app.sim.step_size;    // increase shader compute counter
    if( app.sim.step_size > 1 ) app.updateComputeUBO;       // we need this value in compute shader if its greater than 1
    ++app.sim.index;                                        // increment the compute buffer submission count
    app.drawSim;                                            // let vulkan dance
}

// similar to playSim but with profiling facility for compute work
void profileSim( ref VDrive_State app ) @system {

    app.sim.ping_pong = app.sim.index % 2;                  // compute new ping_pong value
    app.sim.compute_ubo.comp_index += app.sim.step_size;    // increase shader compute counter
    if( app.sim.step_size > 1 ) app.updateComputeUBO;       // we need this value in compute shader if its greater than 1
    ++app.sim.index;                                        // increment the compute buffer submission count

    // edit submit info for compute work
    // we don't want to signal any semaphore
    // we use a fence to measure the time between submission and compleation on the cpu
    // however, we do wait for the swapchain image acquired semaphore
    app.submit_info.signalSemaphoreCount    = 0;
    app.submit_info.pCommandBuffers         = & app.sim.cmd_buffers[ app.sim.ping_pong ];

    // profile compute work
    app.startStopWatch;
    app.graphics_queue.vkQueueSubmit( 1, & app.submit_info, app.submit_fence[ app.next_image_index ] );     // or VK_NULL_HANDLE, fence is only required if syncing to CPU
    app.device.vkWaitForFences( 1, & app.submit_fence[ app.next_image_index ], VK_TRUE, uint64_t.max );    // wait for finished compute
    app.stopStopWatch;
    app.device.vkResetFences( 1, & app.submit_fence[ app.next_image_index ] ).vkAssert;

    // edit submmit info for display work
    // this time we do not wait for the acquired semaphore
    // as we did it in the previous step which is guarded by a fence
    // but we do signal the rendering finished semaphore, which is consumed by vkQueuePresentKHR 
    app.submit_info.waitSemaphoreCount      = 0;
    app.submit_info.signalSemaphoreCount    = 1;
    app.submit_info.pCommandBuffers         = & app.cmd_buffers[ app.next_image_index ];

    // submit graphics work
    app.graphics_queue.vkQueueSubmit( 1, & app.submit_info, app.submit_fence[ app.next_image_index ] );  // or VK_NULL_HANDLE, fence is only required if syncing to CPU for e.g. UBO updates per frame

    // present rendered image
    app.present_info.pImageIndices = & app.next_image_index;
    app.swapchain.present_queue.vkQueuePresentKHR( & app.present_info );

    // edit submmit info to default settings
    // as we multi-buffer semaphores (as well as fences) we need to patch the submit and present infos
    // with the new set of semaphores
    // wait and signal semaphore count must be set both to one, we might be leaving profile mode after any call
    app.submit_info.waitSemaphoreCount      = 1;
    app.submit_info.pWaitSemaphores         = & app.acquired_semaphore[ app.next_image_index ];
    app.submit_info.pSignalSemaphores       = & app.rendered_semaphore[ app.next_image_index ];
    app.present_info.pWaitSemaphores        = & app.rendered_semaphore[ app.next_image_index ];

    // check if window was resized and handle the case
    if( app.window_resized ) {
        app.window_resized = false;
        app.recreateSwapchain;
        import resources : createResizedCommands;
        app.createResizedCommands;
    }

    // acquire next swapchain image
    app.device.vkAcquireNextImageKHR( app.swapchain.swapchain, uint64_t.max, app.acquired_semaphore[ app.next_image_index ], VK_NULL_HANDLE, & app.next_image_index );

    // wait for finished drawing
    app.device.vkWaitForFences( 1, & app.submit_fence[ app.next_image_index ], VK_TRUE, uint64_t.max );
    app.device.vkResetFences( 1, & app.submit_fence[ app.next_image_index ] ).vkAssert;
}




////////////////////////////////////////////////////
// Draw function pointer for sim play and profile //
////////////////////////////////////////////////////

alias   Draw_Func = void function( ref VDrive_State app ) nothrow @system;
private Draw_Func draw_func_play;
private Draw_Func draw_func_profile;

// set the functions above as default sim funcs
void setDefaultSimFuncs( ref VDrive_State app ) nothrow @system {
    draw_func_play      = & playSim;
    draw_func_profile   = & profileSim;
    app.sim_play_cmd_buffer_count = 2;
}

// set some other play func
void setSimFuncPlay( Draw_Func func ) nothrow @system {
    draw_func_play = func;
}

// set some other profile func
void setSimFuncProfile( Draw_Func func ) nothrow @system {
    draw_func_profile = func;
}
