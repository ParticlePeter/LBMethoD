
import derelict.glfw3;
import dlsl.matrix;
import erupted;
import vdrive;
import input;



enum Transport : uint32_t { pause, play, step, profile };
enum Collision : uint32_t { SRT, TRT, MRT, CSC, CSC_DRAG };


//////////////////////////////
// application state struct //
//////////////////////////////
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
    Core_Pipeline               graphics_pso;
    VkPipelineCache             graphics_cache;
    Meta_FB!( MAX_FRAMES, 2 )   framebuffers;           // template count of ( VkFramebuffer, VkClearValue )
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
    uint32_t                    sim_particle_count = 400 * 225;
    Meta_Buffer                 sim_particle_buffer;
    VkBufferView                sim_particle_buffer_view;
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

    //
    // cpu resources
    //
    import cpustate;
    VDrive_Cpu_State            vc;
    float*                      sim_image_ptr;             // pointer to the mapped image


    /////////////////////////////////////////////////
    // simulation configuration and auxiliary data //
    /////////////////////////////////////////////////

    //
    // Compute Parameter
    //
    uint32_t[3] sim_domain                  = [ 400, 225, 1 ]; //[ 256, 256, 1 ];   // [ 256, 64, 1 ];
    uint32_t    sim_layers                  = 17;
    uint32_t[3] sim_work_group_size         = [ 400,  1, 1 ];
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
    Compute_UBO*    compute_ubo;


    //
    // Simulation Parameter
    //
    immutable float sim_unit_speed_of_sound = 0.5773502691896258; // 1 / sqrt( 3 );
    float           sim_speed_of_sound      = sim_unit_speed_of_sound;
    float           sim_unit_spatial        = 1;
    float           sim_unit_temporal       = 1;
    Collision       sim_collision           = Collision.CSC_DRAG;
    uint32_t        sim_index               = 0;


    //
    // Display Parameter
    //
    struct Display_UBO {
        uint32_t    display_property        = 0;    // display param display
        float       amplify_property        = 1;    // display param amplify param
        uint32_t    color_layers            = 0;
        uint32_t    z_layer                 = 0;
    }
    Display_UBO*    display_ubo;

    import visualize : Particle_PC;
    Particle_PC     particle_pc;
    VkCommandBuffer particle_reset_cmd_buffer;



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
    // Export Ensight
    //
    import exportstate;
    VDrive_Export_State ve;


    //
    // transport control data
    //
    uint32_t    sim_play_cmd_buffer_count;      // count of command buffers to be drawn when in play mode
    Transport   transport = Transport.pause;    // current transport mode
    Transport   play_mode = Transport.play;     // can be either play or profile


    // flags Todo(pp): create a proper uint32_t flag structure
    bool            feature_shader_double   = false;
    bool            feature_large_points    = false;
    bool            feature_wide_lines      = false;
    bool            draw_gui                = false;    // hidden by default in case we compile without gui
    bool            draw_display            = true;
    bool            draw_particles          = false;
    bool            additive_particle_blend = true;
    bool            sim_use_double          = false;
    bool            sim_use_3_dim           = false;
    bool            sim_use_cpu             = false;
    bool            export_as_vector        = true;



    // window resize callback result
    bool            window_resized          = false;



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


    //
    // UBO update functions
    //

    // update world view projection matrix UBO
    void updateWVPM() {
        xform_ubo.wvpm = projection * tb.matrix;
        xform_ubo.eyep = tb.eye;
        vk.device.vkFlushMappedMemoryRanges( 1, &xform_ubo_flush );
    }

    // update LBM compute UBO
    void updateComputeUBO() {
        // data will be updated elsewhere
        vk.device.vkFlushMappedMemoryRanges( 1, &compute_ubo_flush );
    }

    // update display UBO of velocity and density data
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


    // recreate swapchain, called initially and if window size changes
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
        } else if( tb.dirty ) {
            updateWVPM;  // this happens anyway in recreateSwapchain
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
        sim_profile_step_index += sim_step_size;
        this.draw_func_profile;

        if( 0 < sim_profile_step_count && sim_profile_step_limit <= sim_profile_step_index ) {
            simPause;
        }
    }


    // draw the simulation display and step ahead in the simulation itself (if in play or profile mode)
    void drawSim() @system {

        VkCommandBuffer[2] cmd_buffers = [ cmd_buffers[ next_image_index ], sim_cmd_buffers[ sim_ping_pong ]];
        submit_info.pCommandBuffers = cmd_buffers.ptr;
        graphics_queue.vkQueueSubmit( 1, &submit_info, submit_fence[ next_image_index ] );   // or VK_NULL_HANDLE, fence is only required if syncing to CPU for e.g. UBO updates per frame

        // present rendered image
        present_info.pImageIndices = &next_image_index;
        swapchain.present_queue.vkQueuePresentKHR( &present_info );
        submit_info.pWaitSemaphores     = & acquired_semaphore[ next_image_index ];
        submit_info.pSignalSemaphores   = & rendered_semaphore[ next_image_index ];
        present_info.pWaitSemaphores    = & rendered_semaphore[ next_image_index ];


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
        vk.device.vkAcquireNextImageKHR( swapchain.swapchain, uint64_t.max, acquired_semaphore[ next_image_index ], VK_NULL_HANDLE, & next_image_index );


        // wait for finished drawing
        vk.device.vkWaitForFences( 1, &submit_fence[ next_image_index ], VK_TRUE, uint64_t.max );
        vk.device.vkResetFences( 1, &submit_fence[ next_image_index ] ).vkAssert;
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
void playSim( ref VDrive_State vd ) @system {
    vd.sim_ping_pong = vd.sim_index % 2;                // compute new ping_pong value
    vd.compute_ubo.comp_index += vd.sim_step_size;      // increase shader compute counter
    if( vd.sim_step_size > 1 ) vd.updateComputeUBO;     // we need this value in compute shader if its greater than 1
    ++vd.sim_index;                                     // increment the compute buffer submission count
    vd.drawSim;                                         // let vulkan dance
}

// similar to playSim but with profiling facility for compute work
void profileSim( ref VDrive_State vd ) @system {

    vd.sim_ping_pong = vd.sim_index % 2;                // compute new ping_pong value
    vd.compute_ubo.comp_index += vd.sim_step_size;      // increase shader compute counter
    if( vd.sim_step_size > 1 ) vd.updateComputeUBO;     // we need this value in compute shader if its greater than 1
    ++vd.sim_index;                                     // increment the compute buffer submission count

    // edit submit info for compute work
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
        pSignalSemaphores       = & vd.rendered_semaphore[ vd.next_image_index ];
        pCommandBuffers         = & vd.cmd_buffers[ vd.next_image_index ];
    }

    vd.graphics_queue.vkQueueSubmit( 1, &vd.submit_info, vd.submit_fence[ vd.next_image_index ] );  // or VK_NULL_HANDLE, fence is only required if syncing to CPU for e.g. UBO updates per frame


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
    vd.device.vkAcquireNextImageKHR( vd.swapchain.swapchain, uint64_t.max, vd.acquired_semaphore[ vd.next_image_index ], VK_NULL_HANDLE, & vd.next_image_index );

    // edit submmit info to default settings
    with( vd.submit_info ) {
        waitSemaphoreCount  = 1;
        pWaitSemaphores     = & vd.acquired_semaphore[ vd.next_image_index ];
        pWaitDstStageMask   = & vd.submit_wait_stage_mask;   // configured before entering createResources func
    }
    vd.present_info.pWaitSemaphores = & vd.rendered_semaphore[ vd.next_image_index ];

    // wait for finished drawing
    vd.device.vkWaitForFences( 1, & vd.submit_fence[ vd.next_image_index ], VK_TRUE, uint64_t.max );
    vd.device.vkResetFences( 1, & vd.submit_fence[ vd.next_image_index ] ).vkAssert;


}




////////////////////////////////////////////////////
// Draw function pointer for sim play and profile //
////////////////////////////////////////////////////

alias   Draw_Func = void function( ref VDrive_State vd ) nothrow @system;
private Draw_Func draw_func_play;
private Draw_Func draw_func_profile;

// set the functions above as default sim funcs
void setDefaultSimFuncs( ref VDrive_State vd ) nothrow @system {
    draw_func_play      = & playSim;
    draw_func_profile   = & profileSim;
    vd.sim_play_cmd_buffer_count = 2;
}

// set some other play func
void setSimFuncPlay( Draw_Func func ) nothrow @system {
    draw_func_play = func;
}

// set some other profile func
void setSimFuncProfile( Draw_Func func ) nothrow @system {
    draw_func_profile = func;
}
