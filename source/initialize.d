//module initialize;

import erupted;
import derelict.glfw3;

import core.stdc.stdio : printf;

import vdrive.state;
import vdrive.surface;
import vdrive.util.info;
import vdrive.util.util;
import vdrive.util.array;

import appstate;




// debug report function called by the VK_EXT_debug_report mechanism
extern( System ) VkBool32 debugReport(
    VkDebugReportFlagsEXT       flags,
    VkDebugReportObjectTypeEXT  objectType,
    uint64_t                    object,
    size_t                      location,
    int32_t                     messageCode,
    const( char )*              pLayerPrefix,
    const( char )*              pMessage,
    void*                       pUserData) nothrow @nogc
{
    printf( "ObjectType  : %i\nMessage     : %s\n\n", objectType, pMessage );
    return VK_FALSE;
}


// mixin vulkan related glfw functions
// with this approach the erupted types can be used as params for the functions
mixin DerelictGLFW3_VulkanBind;


// Todo(pp): if initialization fails an error should be returned
// programm termination would than happen gracefully in module main
// pass Vulkan struct as reference parameter into this function
auto initVulkan( ref VDrive_State vd, uint32_t win_w = 1600, uint32_t win_h = 900 ) {

    // Initialize GLFW3 and Vulkan related glfw functions
    DerelictGLFW3.load( "glfw3_64.dll" );   // load the lib found in system path
    DerelictGLFW3_loadVulkan();             // load vulkan specific glfw function pointers
    glfwInit();                             // initialize glfw


    // set glfw window attributes and store it in the VDrive_State appstate
    glfwWindowHint( GLFW_CLIENT_API, GLFW_NO_API );
    vd.window = glfwCreateWindow( win_w, win_h, "Vulkan Erupted", null, null );


    // first load all global level instance functions
    loadGlobalLevelFunctions( cast( typeof( vkGetInstanceProcAddr ))
        glfwGetInstanceProcAddress( null, "vkGetInstanceProcAddr" ));


    // get some useful info from the instance
    //listExtensions;
    //listLayers;
    //"VK_LAYER_LUNARG_standard_validation".isLayer;


    // get vulkan extensions which are required by glfw
    uint32_t extension_count;
    auto glfw_required_extensions = glfwGetRequiredInstanceExtensions( &extension_count );


    // we know that glfw requires only two extensions
    // however we create storage for more of them, as we will add some extensions our self
    const( char )*[8] extensions;
    extensions[ 0..extension_count ] = glfw_required_extensions[ 0..extension_count ];


    debug {
        // we would like to use the debug report callback functionality
        extensions[ extension_count ] = "VK_EXT_debug_report";
        ++extension_count;

        // and report standard validation issues
        const( char )*[1] layers = [ "VK_LAYER_LUNARG_standard_validation" ];
        //const( char )*[0] layers;
    } else {
        const( char )*[0] layers;
    }


    // check if all of the extensions are available, exit if not
    foreach( extension; extensions[ 0..extension_count ] ) {
        if( !extension.isExtension( false )) {
            printf( "Required extension %s not available. Exiting!\n", extension );
            return VK_ERROR_INITIALIZATION_FAILED;
        }
    }


    // check if all of the layers are available, exit if not
    foreach( layer; layers ) {
        if( !layer.isLayer( false )) {
            printf( "Required layers %s not available. Exiting!\n", layer );
            return VK_ERROR_INITIALIZATION_FAILED;
        }
    }


    // initialize the vulkan instance, pass the correct slice into the extension array
    vd.initInstance( extensions[ 0..extension_count ], layers );


    // setup debug report callback
    debug {
        VkDebugReportCallbackCreateInfoEXT callbackCreateInfo = {
            flags       : VK_DEBUG_REPORT_ERROR_BIT_EXT | VK_DEBUG_REPORT_WARNING_BIT_EXT | VK_DEBUG_REPORT_PERFORMANCE_WARNING_BIT_EXT,
            pfnCallback : &debugReport,
            pUserData   : null,
        };
        vkCreateDebugReportCallbackEXT( vd.instance, &callbackCreateInfo, vd.allocator, &vd.debugReportCallback );
    }


    // create the window VkSurfaceKHR with the instance, surface is stored in the state object
    import vdrive.surface;
    glfwCreateWindowSurface( vd.instance, vd.window, vd.allocator, &vd.surface.create_info.surface ).vkAssert;
    vd.surface.create_info.imageExtent = VkExtent2D( win_w, win_h );    // Set the desired surface extent, this might change at swapchain creation


    // enumerate gpus
    auto gpus = vd.instance.listPhysicalDevices( false );


    // get some useful info from the physical devices
    foreach( ref gpu; gpus ) {
        //gpu.listProperties;
        gpu.listProperties( GPU_Info.properties );
        //gpu.listProperties( GPU_Info.limits );
        //gpu.listProperties( GPU_Info.sparse_properties );
        //gpu.listFeatures;
        //gpu.listLayers;
        //gpu.listExtensions;
        //printf( "Present supported: %u\n", gpu.presentSupport( vd.surface ));
    }


    // set the desired gpu into the state object
    // Todo(pp): find a suitable "best fit" gpu
    // - gpu must support the VK_KHR_swapchain extension
    bool presentation_supported = false;
    foreach( ref gpu; gpus ) {
        if( gpu.presentSupport( vd.surface.surface )) {
            presentation_supported = true;
            vd.gpu = gpu;
            break;
        }
    }

    // Presentation capability is required for this example, terminate if not available
    if( !presentation_supported ) {
        // Todo(pp): print to error stream
        printf( "No GPU with presentation capability detected. Terminating!" );
        vd.destroyInstance;
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    // if presentation is supported on that gpu the gpu extension VK_KHR_swapchain must be available
    const( char )*[1] deviceExtensions = [ "VK_KHR_swapchain" ];


    // enabling shader clip and cull distance is not required if gl_PerVertex is (re)defined
    VkPhysicalDeviceFeatures features;
    auto available_features = vd.gpu.listFeatures( false );
    features.fillModeNonSolid = available_features.fillModeNonSolid;
    //features.shaderClipDistance = available_features.shaderClipDistance;
    //features.shaderCullDistance = available_features.shaderCullDistance;
    //features.shaderStorageImageExtendedFormats = available_features.shaderStorageImageExtendedFormats;


    // Todo(pp): the filtering bellow is not lazy and also allocates, change both to lazy range based
    auto queue_families = listQueueFamilies( vd.gpu, false, vd.surface.surface );   // last param is optional and only for printing
    auto graphic_queues = queue_families
        .filterQueueFlags( VK_QUEUE_GRAPHICS_BIT )                  // .filterQueueFlags( include, exclude )
        .filterPresentSupport( vd.gpu, vd.surface.surface );        // .filterPresentSupport( gpu, surface )


    // treat the case of combined graphics and presentation queue first
    if( graphic_queues.length > 0 ) {
        Queue_Family[1] filtered_queues = graphic_queues.front;
        filtered_queues[0].queueCount = 1;
        filtered_queues[0].priority( 0 ) = 1;

        // initialize the logical device
        vd.initDevice( filtered_queues, deviceExtensions, layers, &features );

        // get device queues
        vd.device.vkGetDeviceQueue( filtered_queues[0].family_index, 0, &vd.graphics_queue );
        vd.device.vkGetDeviceQueue( filtered_queues[0].family_index, 0, &vd.surface.present_queue );

        // store queue family index, required for command pool creation
        vd.graphics_queue_family_index = filtered_queues[0].family_index;


    } else {
        graphic_queues = queue_families.filterQueueFlags( VK_QUEUE_GRAPHICS_BIT );  // .filterQueueFlags( include, exclude )

        // a graphics queue is required for the example, terminate if not available
        if( graphic_queues.length == 0 ) {
            // Todo(pp): print to error stream
            printf( "No queue with VK_QUEUE_GRAPHICS_BIT found. Terminating!" );
            vd.destroyInstance;
            return VK_ERROR_INITIALIZATION_FAILED;
        }

        // We know that the gpu has presentation support and can present to the surface
        // take the first available presentation queue
        Queue_Family[2] filtered_queues = [
            graphic_queues.front,
            queue_families.filterPresentSupport( vd.gpu, vd.surface.surface ).front // .filterPresentSupport( gpu, surface
        ];

        // initialize the logical device
        vd.initDevice( filtered_queues, deviceExtensions, layers, &features );

        // get device queues
        vd.device.vkGetDeviceQueue( filtered_queues[0].family_index, 0, &vd.graphics_queue );
        vd.device.vkGetDeviceQueue( filtered_queues[1].family_index, 0, &vd.surface.present_queue );

        // store queue family index, required for command pool creation
        // family_index of presentation queue seems not to be required later on
        vd.graphics_queue_family_index = filtered_queues[0].family_index;
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



void destroyVulkan( ref VDrive_State vd ) {

    vd.destroyDevice;

    debug vd.destroy( vd.debugReportCallback );
    vd.destroyInstance;

    glfwDestroyWindow( vd.window );
    glfwTerminate();
}
