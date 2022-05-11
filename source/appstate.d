
import bindbc.glfw;
import dlsl.matrix;
import erupted;
import vdrive;
import input;

import settings : setting;

debug import core.stdc.stdio : printf;

enum validate_vulkan = true;
enum verbose = false;

enum Transport : uint32_t { pause, play, step, profile };


nothrow:    // @nogc:


//////////////////////////////
// application state struct //
//////////////////////////////
struct VDrive_State {

    //nothrow @nogc:

    // count of maximum per frame resources, might be less dependent on swapchain image count
    enum                        MAX_FRAMES = 2;

    // initialize
    Vulkan                      vk;
    alias                       vk this;
    VkQueue                     graphics_queue;
    uint32_t                    graphics_queue_family_index; // required for command pool
    GLFWwindow*                 window;

    struct XForm_UBO {
        mat4        wvpm;
        float[3]    eyep = [ 0, 0, 0 ];
        float       time_step = 0.0;
    }

    // trackball and mouse
    TrackballButton             tbb;                        // Trackball manipulator updating View Matrix
    MouseMove                   mouse;
    XForm_UBO*                  xform_ubo;                  // World View Projection Matrix

    // return window width and height stored in Meta_Swapchain struct
    @setting auto windowWidth()  @nogc { return swapchain.image_extent.width;  }
    @setting auto windowHeight() @nogc { return swapchain.image_extent.height; }

    // set window width and hight before recreating swapchain
    @setting void windowWidth(  uint32_t w ) @nogc { swapchain.image_extent.width  = w; }
    @setting void windowHeight( uint32_t h ) @nogc { swapchain.image_extent.height = h; }

    alias win_w = windowWidth;
    alias win_h = windowHeight;

    mat4                        projection;                 // Projection Matrix
    @setting float              projection_fovy =    60;    // Projection Field Of View in Y dimension
    @setting float              projection_near =   0.1;    // Projection near plane distance
    @setting float              projection_far  =  1000;    // Projection  far plane distance
    float                       projection_aspect;          // Projection aspect, will be computed from window dim, when updateProjection is called

    @setting mat3               look_at() @nogc { return tbb.lookingAt; }
    @setting void               look_at( ref mat3 etu ) @nogc { tbb.lookAt( etu[0], etu[1], etu[2] ); }

    // Todo(pp): calculate best possible near and far clip planes when manipulating the trackball

    // surface and swapchain
    Core_Swapchain_Queue_Extent swapchain;
    @setting VkPresentModeKHR   present_mode = VK_PRESENT_MODE_MAX_ENUM_KHR;
    VkSampleCountFlagBits       sample_count = VK_SAMPLE_COUNT_1_BIT;

    // memory Resources
    alias                       Ubo_Buffer = Core_Buffer_T!( 0, BMC.Mem_Range );
    Ubo_Buffer                  xform_ubo_buffer;
    Core_Image_Memory_View      depth_image;
    VkDeviceMemory              host_visible_memory;


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


    // render setup
    VkRenderPassBeginInfo       render_pass_bi;
    VkFramebuffer[ MAX_FRAMES ] framebuffers;
    VkClearValue[ 2 ]           clear_values;
    VkViewport                  viewport;               // dynamic state viewport
    VkRect2D                    scissors;               // dynamic state scissors


    // simulate resources
    import simulate;
    @setting Sim_State          sim;


    // visualize resources
    import visualize;
    @setting Vis_State          vis;


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

    import std.datetime.stopwatch;
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



    //
    // transport control data
    //
    uint32_t sim_play_cmd_buffer_count;                // count of command buffers to be drawn when in play mode
    @setting Transport  transport = Transport.pause;   // current transport mode
    @setting Transport  play_mode = Transport.play;    // can be either play or profile


    // flags Todo(pp): create a proper uint32_t flag structure
    bool            feature_shader_double   = false;
    bool            feature_large_points    = false;
    bool            feature_wide_lines      = false;
    @setting bool   use_cpu                 = false;



    // window resize callback result
    bool            window_resized          = false;





    import initialize;
    VkResult initVulkan() {
        if( win_w == 0 ) win_w = 1600;
        if( win_h == 0 ) win_h =  900;
        return initialize.initVulkan( this, win_w, win_h ).vkAssert;
    }


    void destroyVulkan() {
        initialize.destroyVulkan( this );
    }


    nothrow:

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
                //import cpustate : cpuInit;
                //this.cpuInit;
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
    void updateWVPM() @nogc {
        xform_ubo.wvpm = projection * tbb.worldTransform;
        xform_ubo.eyep = tbb.eye;
        vk.flushMappedMemoryRange( xform_ubo_buffer.mem_range );
    }

    // update LBM compute UBO
    void updateComputeUBO() @nogc {
        // data will be updated elsewhere
        vk.flushMappedMemoryRange( sim.compute_ubo_buffer.mem_range );
    }

    // update display UBO of velocity and density data
    void updateDisplayUBO() @nogc {
        // data will be updated elsewhere
        vk.flushMappedMemoryRange( vis.display_ubo_buffer.mem_range );
    }

    // amplify display property by reciprocal sim steps
    void amplifyDisplayProperty() {
        vis.display_ubo.amplify_property = vis.amplify_prop_div_steps && sim.step_size > 1
            ? vis.amplify_property / sim.step_size
            : vis.amplify_property;
        updateDisplayUBO;
    }

    /// Scale the display based on the aspect(s) of sim.domain
    /// Parameter signals dimension count, 2D sim 3D
    /// Params:
    ///     app = reference to this modules VDrive_State struct
    ///     dim = the current dimensions
    /// Returns: scale factor for the plane or box, in the former case result[2] should be ignored
    float[3] simDisplayScale( int dim ) @nogc {
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
            this.resizeRenderResources( present_mode );   // destroy old and recreate window size dependent resources

        } catch( Exception ) {}
    }


    // this is used in windowResizeCallback
    // there only a VDrive_State pointer is available and we avoid ugly dereferencing
    void swapchainExtent( uint32_t win_w, uint32_t win_h ) {
        swapchain.image_extent = VkExtent2D( win_w, win_h );
    }


    // update projection matrix from member data _fovy, _near, _far
    // and the swapchain extent converted to aspect
    void updateProjection() {
        import dlsl.projection;
        projection_aspect = cast( float )windowWidth / windowHeight;
        projection = vkPerspective( projection_fovy, projection_aspect, projection_near, projection_far );
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

        // if the transport was set to play by settings or default, we must jump start it
        if( transport == Transport.play )
            simPlay;
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

        // select and draw command buffers
        VkCommandBuffer[2] cmd_buffers = [ cmd_buffers[ next_image_index ], sim.cmd_buffers[ sim.ping_pong ]];
        submit_info.pCommandBuffers = cmd_buffers.ptr;
        graphics_queue.vkQueueSubmit( 1, & submit_info, submit_fence[ next_image_index ] );   // or VK_NULL_HANDLE, fence is only required if syncing to CPU for e.g. UBO updates per frame

        // present rendered image
        present_info.pImageIndices = & next_image_index;
        swapchain.present_queue.vkQueuePresentKHR( & present_info );

        // edit semaphore attachment
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
        auto vkResult = vk.device.vkWaitForFences( 1, & submit_fence[ next_image_index ], VK_TRUE, uint64_t.max );
        debug if( vkResult != VK_SUCCESS )
            printf( "%s\n", vkResult.toCharPtr );
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
