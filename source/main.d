//module main;


import input;
import appstate;


import initialize;




int main() {

    //import core.stdc.stdlib : malloc;
    //void* scratch = malloc( 1024 );

    import core.stdc.stdio : printf;
    printf( "\n" );

    // define if we want to use a GUI or not
    enum USE_GUI = true;


    // compile time branch if gui is used or not 
    static if( USE_GUI ) {
        import gui;
        VDrive_Gui_State app;                       // VDrive Gui state struct wrapping VDrive State struct
        app.initImgui;                              // initialize imgui first, we raster additional fonts but currently don't install its glfw callbacks, they should be treated
    } else {
        import resources;
        VDrive_State app;                           // VDrive state struct
    }


    // initialize vulkan
    auto vkResult = app.initVulkan( 1600, 900 );    // initialize instance and (physical) device
    if( vkResult ) return vkResult;                 // exit if initialization failed, VK_SUCCESS = 0

    app.initTrackball;                              // initialize trackball with window size and default perspective projection data in VDrive State
    app.registerCallbacks;                          // register glfw callback functions 
    app.createCommandObjects;                       // create command pool and sync primitives
    app.createMemoryObjects;                        // create memory objects once used through out program lifetime
    app.createDescriptorSet;                        // create descriptor set
    app.createRenderResources;                      // configure swapchain, create renderpass and pipeline state object
    app.resizeRenderResources;                      // construct swapchain, create depth buffer and frambuffers
    app.setDefaultSimFuncs;                         // set default sim funcs, these can be overridden with gui commands

    // branch once more dependent on gui usage
    static if( !USE_GUI ) {
        app.createResizedCommands;                  // create draw loop runtime commands, only used without gui
    }

    // initial draw
    app.drawInit;


    // record the first gui command buffer
    // in the draw loop this one will be submitted
    // while the next one is recorded asynchronously


    //import vdrive.util.info;
    //app.gpu.listFeatures;

    // Todo(pp):
    //import core.thread;
    //thread_detachThis();

    char[32] title;
    uint frame_count;
    import derelict.glfw3;
    double last_time = glfwGetTime();
    import core.stdc.stdio : sprintf;
    while( !glfwWindowShouldClose( app.window ))
    {
        // compute fps
        ++frame_count;
        double delta_time = glfwGetTime() - last_time;
        if( delta_time >= 1.0 ) {
            sprintf( title.ptr, "Vulkan Erupted, FPS: %.2f", frame_count / delta_time );    // frames per second
            //sprintf( title.ptr, "Vulkan Erupted, FPS: %.2f", 1000.0 / frame_count );      // milli seconds per frame
            glfwSetWindowTitle( app.window, title.ptr );
            last_time += delta_time;
            frame_count = 0;
        }

        // draw
        app.draw();
        glfwSwapBuffers( app.window );

        // poll events in remaining frame time
        glfwPollEvents();
    }

    import cpustate : cpuFree;
    app.cpuFree;

    // drain work and destroy vulkan
    app.destroyResources;
    app.destroyVulkan;

    printf( "\n" );
    return 0;
}

