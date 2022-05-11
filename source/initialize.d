//module initialize;

import erupted;
import bindbc.glfw;

import core.stdc.stdio : printf;

import vdrive.util;
import vdrive.state;
import vdrive.validator;
import vdrive.initializer;


import appstate;


// mixin vulkan related glfw functions
// with this approach the erupted types can be used as params for the functions
mixin( bindGLFW_Vulkan );


//nothrow @nogc:


// Todo(pp): if initialization fails an error should be returned
// programm termination would than happen gracefully in module main
// pass Vulkan struct as reference parameter into this function
VkResult initVulkan( ref VDrive_State app, uint32_t win_w, uint32_t win_h ) {

    // set vulkan state verbosity
    vdrive.initializer.verbose_init = verbose;

    println();

    // Initialize GLFW3 and Vulkan related glfw functions
    loadGLFW( "glfw3_x64_3.3.3.dll" ); // load the lib found in system path
    loadGLFW_Vulkan;    // load vulkan specific glfw function pointers
    glfwInit();         // initialize glfw

    // set glfw window attributes and store it in the VDrive_State appstate
    glfwWindowHint( GLFW_CLIENT_API, GLFW_NO_API );
    app.window = glfwCreateWindow( win_w, win_h, "Vulkan Erupted", null, null );

    // first load all global level instance functions

    // glwf3 way
    //loadGlobalLevelFunctions( cast( PFN_vkGetInstanceProcAddr )glfwGetInstanceProcAddress( null, "vkGetInstanceProcAddr" ));

    // ErupteD way
    import erupted.vulkan_lib_loader;
    loadGlobalLevelFunctions;



    // get some useful info from the instance
    //listExtensions;   // heap allocation
    //listLayers;       // heap allocation
    //app.listExtensions; // arena sub-allocation
    //app.listLayers;     // arena sub-allocation
    //"VK_LAYER_KHRONOS_validation".isLayer;


    // get vulkan extensions which are required by glfw
    uint32_t  extension_count;
    string_z* glfw_required_extensions = glfwGetRequiredInstanceExtensions( & extension_count );

    //*
    auto meta_init = Meta_Init( app );
    VkResult result = meta_init
        .validateVulkan( true )
        .addInstanceExtensions( glfw_required_extensions[ 0 .. extension_count ] )
        .addInstanceLayer( "VK_LAYER_KHRONOS_validation" )
        .setDebugUtilsSeverityFlags( 0
            | VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT
            | VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT
        //  | VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT
        //  | VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT
        )
        .setDebugUtilsTypeFlags( 0
            | VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT
            | VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT
            | VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT
        )
//        .setDebugUtilsSeverityFlags( VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT )
//        .addDebugUtilsSeverityFlags( VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT )
//        .addDebugUtilsSeverityFlags( VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT )
//        .addDebugUtilsSeverityFlags( VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT )
//        .setDebugUtilsTypeFlags( VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT )
//        .addDebugUtilsTypeFlags( VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT )
//        .addDebugUtilsTypeFlags( VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT )
        .initInstance;

    string_z[] layers = meta_init.instance_layers.data;
    uint32_t layer_count = meta_init.instance_layers.count.to_uint;

    /*/
    // we know that glfw requires only two extensions
    // however we create storage for more of them, as we will add some extensions our self
    const( char )*[8] extensions;
    extensions[ 0 .. extension_count ] = glfw_required_extensions[ 0 .. extension_count ];


    // we would like to enable LunarG Validation layers if they are available
    uint32_t layer_count = 0;
    const( char )*[1] layers;   // one layer suffices

    static if( validate_vulkan ) {
        // we prefer using the modern debug utils
        if( VK_EXT_DEBUG_UTILS_EXTENSION_NAME.isInstanceExtension( verbose )) {
            extensions[ extension_count ] = VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
            ++extension_count;
        }

        // else we use the debug report callback functionality if available
        else if( VK_EXT_DEBUG_REPORT_EXTENSION_NAME.isInstanceExtension( verbose )) {
            extensions[ extension_count ] = VK_EXT_DEBUG_REPORT_EXTENSION_NAME;
            ++extension_count;

            // and also debug marker functionality if available
            if( VK_EXT_DEBUG_MARKER_EXTENSION_NAME.isInstanceExtension( verbose )) {
                extensions[ extension_count ] = VK_EXT_DEBUG_MARKER_EXTENSION_NAME;
                ++extension_count;
            }
        }

        // and report standard validation issues if LunarG validation layer is available
        if( "VK_LAYER_KHRONOS_validation".isInstanceLayer( verbose )) {
            layers[ layer_count ] = "VK_LAYER_KHRONOS_validation";
            ++layer_count;
        }
    }


    // check if all of the extensions are available, exit if not
    foreach( extension; extensions[ 0 .. extension_count ] ) {
        if( !extension.isInstanceExtension( verbose )) {
            printf( "Required extension %s not available. Exiting!\n", extension );
            return VK_ERROR_INITIALIZATION_FAILED;
        }
    }


    // check if all of the layers are available, exit if not
    foreach( layer; layers[ 0 .. layer_count ] ) {
        if( !layer.isInstanceLayer( verbose )) {
            printf( "Required layers %s not available. Exiting!\n", layer );
            return VK_ERROR_INITIALIZATION_FAILED;
        }
    }


    // initialize the vulkan instance, pass the correct slice into the extension array
    app.initInstance( extensions[ 0 .. extension_count ], layers[ 0 .. layer_count ] );


    // setup debug utils messenger
    static if( validate_vulkan ) {
        // setup debug utils messenger if available
        if( VK_EXT_DEBUG_UTILS_EXTENSION_NAME.isInstanceExtension( verbose )) {
            app.createDebugMessenger(
                  VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT
                | VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT
            //  | VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT
            //  | VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT
                ,
                  VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT
                | VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT
                | VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT
            );
        }

        // setup debug report callback
        else if( VK_EXT_DEBUG_REPORT_EXTENSION_NAME.isInstanceExtension( verbose )) {
            app.createDebugReporter(
                  VK_DEBUG_REPORT_ERROR_BIT_EXT
                | VK_DEBUG_REPORT_WARNING_BIT_EXT
                | VK_DEBUG_REPORT_PERFORMANCE_WARNING_BIT_EXT
            );
        }
    }

    //*/


    // we have to create the window VkSurfaceKHR with the instance, before we can querry the available devices for presentation ability
    import vdrive.swapchain;
    glfwCreateWindowSurface( app.instance, app.window, app.allocator, & app.swapchain.surface ).vkAssert;
    app.swapchain.image_extent = VkExtent2D( win_w, win_h );     // Set the desired swapchain extent, this might change at swapchain (re)creation


    // enumerate gpus
    //auto gpus = listPhysicalDevicesResult( app );
    auto gpus = app.listPhysicalDevices( false );
    //auto gpus = app.instance.listPhysicalDevices( false );


    // get some useful info from the physical devices
    foreach( ref gpu; gpus ) {
        //gpu.listProperties;
        //gpu.listProperties( GPU_Info_Flags.properties, app.scratch );
        //gpu.listProperties( GPU_Info_Flags.limits );
        //gpu.listProperties( GPU_Info_Flags.sparse_properties );
        //gpu.listFeatures;

        app.gpu = gpu;

        //auto gpu_layers = List_Layers_Result( app );
        //listLayers( gpu_layers, verbose );
        //gpu.listLayers;       // allocates
        //app.listLayers;

        //auto gpu_extensions = List_Extensions_Result( app );
        //listExtensions( gpu_extensions,  true );
        //"VK_EXT_debug_marker".isExtension( app, true );
        //gpu.listExtensions;   // heap allocation
        //app.listExtensions;      // area sub-allocation

        //printf( "Present supported: %u\n", gpu.presentSupport( app.swapchain.surface ));
        //auto presentation_modes = listPresentModesResult( app );
        //listPresentModes( presentation_modes, app.swapchain.surface, verbose );
        //gpu.listPresentModes( app.swapchain.surface, true );     // stack allocation
    }


    // set the desired gpu into the state object
    // Todo(pp): find a suitable "best fit" gpu
    // - gpu must support the VK_KHR_swapchain extension
    bool presentation_supported = false;
    foreach( ref gpu; gpus ) {
        if( gpu.presentSupport( app.swapchain.surface )) {
            presentation_supported = true;
            app.gpu = gpu;
            break;
        }
    }

    // Presentation capability is required for this example, terminate if not available
    if( !presentation_supported ) {
        // Todo(pp): print to error stream
        printf( "No GPU with presentation capability detected. Terminating!" );
        app.destroyInstance;
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    // if presentation is supported on that gpu the gpu extension VK_KHR_swapchain must be available
    const( char )*[1] device_extensions = [ VK_KHR_SWAPCHAIN_EXTENSION_NAME ];


    // enabling shader clip and cull distance is not required if gl_PerVertex is (re)defined
    VkPhysicalDeviceFeatures features;
    auto available_features = app.gpu.listFeatures( false );
    //features.fillModeNonSolid = available_features.fillModeNonSolid;
    //features.shaderClipDistance = available_features.shaderClipDistance;
    //features.shaderCullDistance = available_features.shaderCullDistance;
    //features.tessellationShader = available_features.tessellationShader;
    features.shaderStorageImageExtendedFormats  = available_features.shaderStorageImageExtendedFormats;
    features.vertexPipelineStoresAndAtomics     = available_features.vertexPipelineStoresAndAtomics;
    app.feature_shader_double    = 0 < ( features.shaderFloat64 = available_features.shaderFloat64 );
    app.feature_large_points     = 0 < ( features.largePoints = available_features.largePoints );
    app.feature_wide_lines       = 0 < ( features.wideLines = available_features.wideLines );


    //auto queue_families = listQueueFamiliesResult( app );
    //listQueueFamilies( queue_families, verbose, app.swapchain.surface );           // last param is optional and only for printing
    auto queue_families = app.listQueueFamilies( true, app.swapchain.surface );   // last param is optional and only for printing - allocates

    auto graphic_queues = queue_families.dup;
    graphic_queues
        .filterQueueFlags( VK_QUEUE_GRAPHICS_BIT )                  // .filterQueueFlags( include, exclude )
        .filterPresentSupport( app.gpu, app.swapchain.surface );    // .filterPresentSupport( gpu, swapchain )


    // treat the case of combined graphics and presentation queue first
    if( graphic_queues.length > 0 ) {

        Queue_Family[1] filtered_queues = graphic_queues.front;
        filtered_queues[0].queueCount = 1;
        filtered_queues[0].priority( 0 ) = 1;

        // initialize the logical device
        // Todo(pp): fix allocations dependent on extensions and layers type
        app.initDevice( filtered_queues, device_extensions, /*meta_init.instance_layers.data*/layers, & features );

        // get device queues
        app.device.vkGetDeviceQueue( filtered_queues[0].family_index, 0, & app.graphics_queue );
        app.device.vkGetDeviceQueue( filtered_queues[0].family_index, 0, & app.swapchain.present_queue );

        // store queue family index, required for command pool creation
        app.graphics_queue_family_index = filtered_queues[0].family_index;

    } else {

        graphic_queues.reset( queue_families );
        graphic_queues.filterQueueFlags( VK_QUEUE_GRAPHICS_BIT );  // .filterQueueFlags( include, exclude )

        // a graphics queue is required for the example, terminate if not available
        if( graphic_queues.length == 0 ) {
            // Todo(pp): print to error stream
            printf( "No queue with VK_QUEUE_GRAPHICS_BIT found. Terminating!" );
            app.destroyInstance;
            return VK_ERROR_INITIALIZATION_FAILED;
        }

        // We know that the gpu has presentation support and can present to the swapchain
        // take the first available presentation queue
        Queue_Family[2] filtered_queues = [
            graphic_queues.front,
            queue_families.filterPresentSupport( app.gpu, app.swapchain.surface ).front // .filterPresentSupport( gpu, swapchain
        ];

        // initialize the logical device
        app.initDevice( filtered_queues, device_extensions, /*meta_init.instance_layers.data*/layers, & features );

        // get device queues
        app.device.vkGetDeviceQueue( filtered_queues[0].family_index, 0, & app.graphics_queue );
        app.device.vkGetDeviceQueue( filtered_queues[1].family_index, 0, & app.swapchain.present_queue );

        // store queue family index, required for command pool creation
        // family_index of presentation queue seems not to be required later on
        app.graphics_queue_family_index = filtered_queues[0].family_index;

    }

    return VK_SUCCESS;

    /*
    // Enable graphic and compute queue example
    auto compute_queues = queue_families
        .filterQueueFlags( VK_QUEUE_COMPUTE_BIT, VK_QUEUE_GRAPHICS_BIT );   // .filterQueueFlags( include, exclude )
    assert( compute_queues.length );
    Queue_Family[2] filtered_queues = [ graphic_queues.front, compute_queues.front ];
    filtered_queues[0].queueCount = 1;
    filtered_queues[0].priority( 0 ) = 1;
    filtered_queues[1].queueCount = 1;          // float[2] compute_priorities = [0.8, 0.5];
    filtered_queues[1].priority( 0 ) = 0.8;     // filtered_queues[1].priorities = compute_priorities;
    //writeln( filtered_queues );
    */
}



void destroyVulkan( ref VDrive_State app ) {

    app.destroyDevice;

    static if( validate_vulkan ) {
        if( !app.debug_report_callback.is_null ) app.destroy( app.debug_report_callback );
        if( !app.debug_utils_messenger.is_null ) app.destroy( app.debug_utils_messenger );
    }
    app.destroyInstance;

    // unload vulkan lib
    import erupted.vulkan_lib_loader;
    freeVulkanLib;

    glfwDestroyWindow( app.window );
    glfwTerminate();
}
