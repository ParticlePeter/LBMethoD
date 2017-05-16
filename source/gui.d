module gui;

import erupted;
import imgui.types;
import ImGui = imgui.funcs_static;
import derelict.glfw3.glfw3;

//import vdrive.state;
import vdrive.memory;
import vdrive.pipeline;

import appstate;

private {

    // GLFW Data
    float           g_Time = 0.0f;
    bool[ 3 ]       g_MousePressed = [ false, false, false ];
    float           g_MouseWheel = 0.0f;
}


struct VDrive_Gui_State {
    VDrive_State    vd;
    alias           vd this;

    // gui resources
    Core_Pipeline               gui_graphics_pso;
    Meta_Image                  gui_font_tex;

    alias                               GUI_QUEUED_FRAMES = vd.MAX_FRAMES;
    Meta_Buffer[ GUI_QUEUED_FRAMES ]    gui_vtx_buffers;
    Meta_Buffer[ GUI_QUEUED_FRAMES ]    gui_idx_buffers;

    VkCommandBufferBeginInfo    gui_cmd_buffer_bi = {
        flags : VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT
    };
}



//////////////////////
// initialize imgui //
//////////////////////

auto ref initImgui( ref VDrive_Gui_State vg ) {

    // Get static ImGuiIO struct and set the address of our VDrive_Gui_State as user pointer
    auto io = & ImGui.GetIO();
    io.UserData = & vg;

    // Keyboard mapping. ImGui will use those indices to peek into the io.KeyDown[] array
    io.KeyMap[ ImGuiKey_Tab ]           = GLFW_KEY_TAB;
    io.KeyMap[ ImGuiKey_LeftArrow ]     = GLFW_KEY_LEFT;
    io.KeyMap[ ImGuiKey_RightArrow ]    = GLFW_KEY_RIGHT;
    io.KeyMap[ ImGuiKey_UpArrow ]       = GLFW_KEY_UP;
    io.KeyMap[ ImGuiKey_DownArrow ]     = GLFW_KEY_DOWN;
    io.KeyMap[ ImGuiKey_PageUp ]        = GLFW_KEY_PAGE_UP;
    io.KeyMap[ ImGuiKey_PageDown ]      = GLFW_KEY_PAGE_DOWN;
    io.KeyMap[ ImGuiKey_Home ]          = GLFW_KEY_HOME;
    io.KeyMap[ ImGuiKey_End ]           = GLFW_KEY_END;
    io.KeyMap[ ImGuiKey_Delete ]        = GLFW_KEY_DELETE;
    io.KeyMap[ ImGuiKey_Backspace ]     = GLFW_KEY_BACKSPACE;
    io.KeyMap[ ImGuiKey_Enter ]         = GLFW_KEY_ENTER;
    io.KeyMap[ ImGuiKey_Escape ]        = GLFW_KEY_ESCAPE;
    io.KeyMap[ ImGuiKey_A ]             = GLFW_KEY_A;
    io.KeyMap[ ImGuiKey_C ]             = GLFW_KEY_C;
    io.KeyMap[ ImGuiKey_V ]             = GLFW_KEY_V;
    io.KeyMap[ ImGuiKey_X ]             = GLFW_KEY_X;
    io.KeyMap[ ImGuiKey_Y ]             = GLFW_KEY_Y;
    io.KeyMap[ ImGuiKey_Z ]             = GLFW_KEY_Z;

    // specify gui font
    io.Fonts.AddFontFromFileTTF( "fonts/consola.ttf", 14 ); // size_pixels

    // set ImGui function pointer
    io.RenderDrawListsFn    = & drawGuiData;    // called of ImGui.Render. Alternatively can be set this to null and call ImGui.GetDrawData() after ImGui.Render() to get the same ImDrawData pointer.
    io.SetClipboardTextFn   = & setClipboardString;
    io.GetClipboardTextFn   = & getClipboardString;
    io.ClipboardUserData    = vg.vd.window;

    // specify display size from vulkan data
    io.DisplaySize.x = vg.vd.windowWidth;
    io.DisplaySize.y = vg.vd.windowHeight;

    //version( Windows )
        //io.ImeWindowHandle = glfwGetWin32Window( g_Window );

    // define style
    auto style                  = & ImGui.GetStyle();
    style.GrabMinSize           = 7;
    style.WindowRounding        = 0; //5;
    style.ChildWindowRounding   = 4;
    style.ScrollbarRounding     = 3;
    style.FrameRounding         = 3;
    style.GrabRounding          = 2;
    style.ItemSpacing           = ImVec2( 4, 4 );

    style.Colors[ ImGuiCol_Text ]                   = ImVec4( 0.90f, 0.90f, 0.90f, 1.00f ); //ImVec4( 0.90f, 0.90f, 0.90f, 1.00f );
    style.Colors[ ImGuiCol_TextDisabled ]           = ImVec4( 0.60f, 0.60f, 0.60f, 1.00f ); //ImVec4( 0.60f, 0.60f, 0.60f, 1.00f );
    style.Colors[ ImGuiCol_WindowBg ]               = ImVec4( 0.00f, 0.00f, 0.00f, 0.50f ); //ImVec4( 0.00f, 0.00f, 0.00f, 0.50f );
    style.Colors[ ImGuiCol_ChildWindowBg ]          = ImVec4( 0.00f, 0.00f, 0.00f, 0.50f ); //ImVec4( 0.00f, 0.00f, 0.00f, 0.50f );
    style.Colors[ ImGuiCol_PopupBg ]                = ImVec4( 0.05f, 0.05f, 0.10f, 1.00f ); //ImVec4( 0.05f, 0.05f, 0.10f, 1.00f );
    style.Colors[ ImGuiCol_Border ]                 = ImVec4( 0.37f, 0.37f, 0.37f, 0.25f ); //ImVec4( 0.37f, 0.37f, 0.37f, 0.25f );
    style.Colors[ ImGuiCol_BorderShadow ]           = ImVec4( 0.00f, 0.00f, 0.00f, 0.00f ); //ImVec4( 0.00f, 0.00f, 0.00f, 0.00f );
    style.Colors[ ImGuiCol_FrameBg ]                = ImVec4( 0.25f, 0.25f, 0.25f, 1.00f ); //ImVec4( 0.25f, 0.25f, 0.25f, 1.00f );
    style.Colors[ ImGuiCol_FrameBgHovered ]         = ImVec4( 0.50f, 0.50f, 0.50f, 1.00f ); //ImVec4( 0.50f, 0.50f, 0.50f, 1.00f );
    style.Colors[ ImGuiCol_FrameBgActive ]          = ImVec4( 0.65f, 0.65f, 0.65f, 1.00f ); //ImVec4( 0.65f, 0.65f, 0.65f, 1.00f );
    style.Colors[ ImGuiCol_TitleBg ]                = ImVec4( 0.16f, 0.26f, 0.38f, 1.00f ); //ImVec4( 0.27f, 0.27f, 0.54f, 0.83f );
    style.Colors[ ImGuiCol_TitleBgCollapsed ]       = ImVec4( 0.16f, 0.26f, 0.38f, 1.00f ); //ImVec4( 0.40f, 0.40f, 0.80f, 0.20f );
    style.Colors[ ImGuiCol_TitleBgActive ]          = ImVec4( 0.19f, 0.30f, 0.41f, 1.00f ); //ImVec4( 0.22f, 0.35f, 0.50f, 1.00f );
    style.Colors[ ImGuiCol_MenuBarBg ]              = ImVec4( 0.16f, 0.26f, 0.38f, 0.50f ); //ImVec4( 0.40f, 0.40f, 0.55f, 0.80f );
    style.Colors[ ImGuiCol_ScrollbarBg ]            = ImVec4( 0.25f, 0.25f, 0.25f, 0.60f ); //ImVec4( 0.25f, 0.25f, 0.25f, 0.60f );
    style.Colors[ ImGuiCol_ScrollbarGrab ]          = ImVec4( 0.40f, 0.40f, 0.40f, 1.00f ); //ImVec4( 0.40f, 0.40f, 0.40f, 1.00f );
    style.Colors[ ImGuiCol_ScrollbarGrabHovered ]   = ImVec4( 0.22f, 0.35f, 0.50f, 1.00f ); //ImVec4( 0.50f, 0.50f, 0.50f, 1.00f );
    style.Colors[ ImGuiCol_ScrollbarGrabActive ]    = ImVec4( 0.27f, 0.43f, 0.63f, 1.00f ); //ImVec4( 0.00f, 0.50f, 1.00f, 1.00f );
    style.Colors[ ImGuiCol_ComboBg ]                = ImVec4( 0.20f, 0.20f, 0.20f, 1.00f ); //ImVec4( 0.20f, 0.20f, 0.20f, 1.00f );
    style.Colors[ ImGuiCol_CheckMark ]              = ImVec4( 0.90f, 0.90f, 0.90f, 1.00f ); //ImVec4( 0.90f, 0.90f, 0.90f, 1.00f );
    style.Colors[ ImGuiCol_SliderGrab ]             = ImVec4( 1.00f, 1.00f, 1.00f, 0.25f ); //ImVec4( 1.00f, 1.00f, 1.00f, 0.25f );
    style.Colors[ ImGuiCol_SliderGrabActive ]       = ImVec4( 0.27f, 0.43f, 0.63f, 1.00f ); //ImVec4( 0.00f, 0.50f, 1.00f, 1.00f );
    style.Colors[ ImGuiCol_Button ]                 = ImVec4( 0.16f, 0.26f, 0.38f, 1.00f ); //ImVec4( 0.40f, 0.40f, 0.40f, 1.00f );
    style.Colors[ ImGuiCol_ButtonHovered ]          = ImVec4( 0.22f, 0.35f, 0.50f, 1.00f ); //ImVec4( 0.50f, 0.50f, 0.50f, 1.00f );
    style.Colors[ ImGuiCol_ButtonActive ]           = ImVec4( 0.27f, 0.43f, 0.63f, 1.00f ); //ImVec4( 0.00f, 0.50f, 1.00f, 1.00f );
    style.Colors[ ImGuiCol_Header ]                 = ImVec4( 0.16f, 0.26f, 0.38f, 1.00f ); //ImVec4( 0.40f, 0.40f, 0.90f, 1.00f );
    style.Colors[ ImGuiCol_HeaderHovered ]          = ImVec4( 0.22f, 0.35f, 0.50f, 1.00f ); //ImVec4( 0.45f, 0.45f, 0.90f, 1.00f );
    style.Colors[ ImGuiCol_HeaderActive ]           = ImVec4( 0.22f, 0.35f, 0.50f, 1.00f ); //ImVec4( 0.53f, 0.53f, 0.87f, 1.00f );
    style.Colors[ ImGuiCol_Column ]                 = ImVec4( 0.50f, 0.50f, 0.50f, 1.00f ); //ImVec4( 0.50f, 0.50f, 0.50f, 1.00f );
    style.Colors[ ImGuiCol_ColumnHovered ]          = ImVec4( 0.60f, 0.60f, 0.60f, 1.00f ); //ImVec4( 0.60f, 0.60f, 0.60f, 1.00f );
    style.Colors[ ImGuiCol_ColumnActive ]           = ImVec4( 0.70f, 0.70f, 0.70f, 1.00f ); //ImVec4( 0.70f, 0.70f, 0.70f, 1.00f );
    style.Colors[ ImGuiCol_ResizeGrip ]             = ImVec4( 1.00f, 1.00f, 1.00f, 1.00f ); //ImVec4( 1.00f, 1.00f, 1.00f, 1.00f );
    style.Colors[ ImGuiCol_ResizeGripHovered ]      = ImVec4( 1.00f, 1.00f, 1.00f, 1.00f ); //ImVec4( 1.00f, 1.00f, 1.00f, 1.00f );
    style.Colors[ ImGuiCol_ResizeGripActive ]       = ImVec4( 1.00f, 1.00f, 1.00f, 1.00f ); //ImVec4( 1.00f, 1.00f, 1.00f, 1.00f );
    style.Colors[ ImGuiCol_CloseButton ]            = ImVec4( 0.22f, 0.35f, 0.50f, 1.00f ); //ImVec4( 0.50f, 0.50f, 0.90f, 1.00f );
    style.Colors[ ImGuiCol_CloseButtonHovered ]     = ImVec4( 0.27f, 0.43f, 0.63f, 1.00f ); //ImVec4( 0.70f, 0.70f, 0.90f, 1.00f );
    style.Colors[ ImGuiCol_CloseButtonActive ]      = ImVec4( 0.70f, 0.70f, 0.70f, 1.00f ); //ImVec4( 0.70f, 0.70f, 0.70f, 1.00f );
    style.Colors[ ImGuiCol_PlotLines ]              = ImVec4( 1.00f, 1.00f, 1.00f, 1.00f ); //ImVec4( 1.00f, 1.00f, 1.00f, 1.00f );
    style.Colors[ ImGuiCol_PlotLinesHovered ]       = ImVec4( 0.90f, 0.70f, 0.00f, 1.00f ); //ImVec4( 0.90f, 0.70f, 0.00f, 1.00f );
    style.Colors[ ImGuiCol_PlotHistogram ]          = ImVec4( 0.90f, 0.70f, 0.00f, 1.00f ); //ImVec4( 0.90f, 0.70f, 0.00f, 1.00f );
    style.Colors[ ImGuiCol_PlotHistogramHovered ]   = ImVec4( 1.00f, 0.60f, 0.00f, 1.00f ); //ImVec4( 1.00f, 0.60f, 0.00f, 1.00f );
    style.Colors[ ImGuiCol_TextSelectedBg ]         = ImVec4( 0.27f, 0.43f, 0.63f, 1.00f ); //ImVec4( 0.00f, 0.50f, 1.00f, 1.00f );
    style.Colors[ ImGuiCol_ModalWindowDarkening ]   = ImVec4( 0.20f, 0.20f, 0.20f, 0.35f ); //ImVec4( 0.20f, 0.20f, 0.20f, 0.35f );  

    return vg;
}



auto ref createCommandObjects( ref VDrive_Gui_State vg ) {
    import resources : resources_createCommandObjects = createCommandObjects;    // forward to appstate createRenderResources
    vg.resources_createCommandObjects( VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT );
    return vg;
}


auto ref createMemoryObjects( ref VDrive_Gui_State vg ) {
    import resources : resources_createMemoryObjects = createMemoryObjects; // forward to appstate createRenderResources
    vg.resources_createMemoryObjects;

    // Initialize gui draw buffers
    foreach( i; 0 .. vg.GUI_QUEUED_FRAMES ) {
        vg.gui_vtx_buffers[ i ] = vg;
        vg.gui_idx_buffers[ i ] = vg;
    }

    // Todo(pp): memory objects should be created here in such a way that memory could be shared among all

    auto io = & ImGui.GetIO();

    ubyte* pixels;
    int width, height;
    io.Fonts.GetTexDataAsRGBA32( &pixels, &width, &height );
    size_t upload_size = width * height * 4 * ubyte.sizeof;

    // create sampler to sample the textures
    import vdrive.descriptor : createSampler;
    vg.gui_font_tex.sampler = vg.gui_font_tex( vg )
        .create( VK_FORMAT_R8G8B8A8_UNORM, width, height, VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT )
        .createMemory( VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT )
        .createView
        .createSampler; // create a sampler and store it in the internal Meta_Image sampler member

    return vg;
}


// start configuring descriptor set, pass the temporary meta_descriptor
// as a pointer to references.createDescriptorSet, where additional
// descriptors will be added, the set constructed and stored in
// vd.descriptor of type Core_Descriptor
auto ref createDescriptorSet( ref VDrive_Gui_State vg ) {

    import vdrive.descriptor;
    Meta_Descriptor meta_descriptor;    // temporary
    meta_descriptor( vg )
        .addLayoutBindingImmutable( 1, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, VK_SHADER_STAGE_FRAGMENT_BIT )
            .addImageInfo( vg.gui_font_tex.image_view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, vg.gui_font_tex.sampler );

    // forward to appstate createDescriptorSet with the currently being configured meta_descriptor
    import resources : resources_createDescriptorSet = createDescriptorSet;
    vg.resources_createDescriptorSet( & meta_descriptor );

    return vg;
}



auto ref createRenderResources( ref VDrive_Gui_State vg ) {

    //////////////////////////////////////////////
    // create appstate related render resources //
    //////////////////////////////////////////////

    // forward to appstate createRenderResources
    import resources : resources_createRenderResources = createRenderResources;
    vg.resources_createRenderResources;



    ///////////////////////////////////////////
    // create imgui related render recources //
    ///////////////////////////////////////////

    // create pipeline for gui rendering
    import vdrive.shader, vdrive.surface, vdrive.pipeline;
    Meta_Graphics meta_graphics = vg;   // temporary construction struct
    vg.gui_graphics_pso = meta_graphics
        .addShaderStageCreateInfo( vg.createPipelineShaderStage( VK_SHADER_STAGE_VERTEX_BIT,   "shader/imgui.vert" ))
        .addShaderStageCreateInfo( vg.createPipelineShaderStage( VK_SHADER_STAGE_FRAGMENT_BIT, "shader/imgui.frag" ))
        .addBindingDescription( 0, ImDrawVert.sizeof, VK_VERTEX_INPUT_RATE_VERTEX ) // add vertex binding and attribute descriptions
        .addAttributeDescription( 0, 0, VK_FORMAT_R32G32_SFLOAT,  0 ) // interleaved attributes of ImDrawVert ...
        .addAttributeDescription( 1, 0, VK_FORMAT_R32G32_SFLOAT,  ImDrawVert.uv.offsetof  )
        .addAttributeDescription( 2, 0, VK_FORMAT_R8G8B8A8_UNORM, ImDrawVert.col.offsetof )
        .inputAssembly( VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST )                   // set the inputAssembly
        .addViewportAndScissors( VkOffset2D( 0, 0 ), vg.surface.imageExtent )   // add viewport and scissor state, necessary even if we use dynamic state
        .cullMode( VK_CULL_MODE_NONE )                                          // set rasterization state
        .frontFace( VK_FRONT_FACE_COUNTER_CLOCKWISE )                           // create deafult depth state
        .depthState                                                             // set depth state - enable depth test with default attributes
        .addColorBlendState( VK_TRUE )                                          // color blend state - append common (default) color blend attachment state
        .addDynamicState( VK_DYNAMIC_STATE_VIEWPORT )                           // add dynamic states viewport
        .addDynamicState( VK_DYNAMIC_STATE_SCISSOR )                            // add dynamic states scissor
        .addDescriptorSetLayout( vg.descriptor.descriptor_set_layout )          // describe pipeline layout
        .addPushConstantRange( VK_SHADER_STAGE_VERTEX_BIT, 0, 16 )              // specify push constant range
        .renderPass( vg.render_pass.render_pass )                               // describe compatible render pass
        .construct                                                              // construct the PSO
        .destroyShaderModules                                                   // shader modules compiled into pipeline, not shared, can be deleted now
        .reset;



    // get imgui font atlas data
    ubyte* pixels;
    int width, height;
    auto io = & ImGui.GetIO();
    io.Fonts.GetTexDataAsRGBA32( &pixels, &width, &height );
    size_t upload_size = width * height * 4 * ubyte.sizeof;

    // create upload buffer and upload the data
    import vdrive.memory : Meta_Buffer;
    Meta_Buffer stage_buffer;
    stage_buffer( vg )
        .create( VK_BUFFER_USAGE_TRANSFER_SRC_BIT, upload_size )
        .createMemory( VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT )
        .copyData( pixels[ 0 .. upload_size ] );

    // create font atlas image
    if( vg.gui_font_tex.image == VK_NULL_HANDLE ) {
        vg.gui_font_tex( vg )
            .create( VK_FORMAT_R8G8B8A8_UNORM, width, height, VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT )
            .createMemory( VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT )
            .createView;
    }

    // use one command buffer for device resource initialization
    import vdrive.command : allocateCommandBuffer, commandBufferBeginInfo;
    auto cmd_buffer = vg.allocateCommandBuffer( vg.cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY );
    auto cmd_buffer_bi = commandBufferBeginInfo( VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT );
    vkBeginCommandBuffer( cmd_buffer, &cmd_buffer_bi );

    // record image layout transition to VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
    cmd_buffer.recordTransition(
        vg.gui_font_tex.image,
        vg.gui_font_tex.subresourceRange,
        VK_IMAGE_LAYOUT_UNDEFINED,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        0,  // no access mask required here
        VK_ACCESS_TRANSFER_WRITE_BIT,
        VK_PIPELINE_STAGE_HOST_BIT,
        VK_PIPELINE_STAGE_TRANSFER_BIT );

    // record a buffer to image copy
    auto subresource_range = vg.gui_font_tex.image_view_create_info.subresourceRange;
    VkBufferImageCopy buffer_image_copy = {
        imageSubresource: {
            aspectMask      : subresource_range.aspectMask,
            baseArrayLayer  : subresource_range.baseArrayLayer,
            layerCount      : subresource_range.layerCount },
        imageExtent     : vg.gui_font_tex.image_create_info.extent,
    };
    cmd_buffer.vkCmdCopyBufferToImage( stage_buffer.buffer, vg.gui_font_tex.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &buffer_image_copy );

    // record image layout transition to VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
    cmd_buffer.recordTransition(
        vg.gui_font_tex.image,
        vg.gui_font_tex.image_view_create_info.subresourceRange,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        VK_ACCESS_TRANSFER_WRITE_BIT,
        VK_ACCESS_SHADER_READ_BIT,
        VK_PIPELINE_STAGE_TRANSFER_BIT,
        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT );


    // store the texture id in imgui io struct
    io.Fonts.TexID = cast( void* )( vg.gui_font_tex.image );

    // finish recording
    cmd_buffer.vkEndCommandBuffer;

    // submit info stays local in this function scope
    import vdrive.command : queueSubmitInfo;
    auto submit_info = cmd_buffer.queueSubmitInfo;

    // submit the command buffer with one depth and one color image transitions
    import vdrive.util.util : vkAssert;
    vg.graphics_queue.vkQueueSubmit( 1, &submit_info, VK_NULL_HANDLE ).vkAssert;

    // wait on finished submission befor destroying the staging buffer
    vg.graphics_queue.vkQueueWaitIdle;   // equivalent using a fence per Spec v1.0.48
    stage_buffer.destroyResources;

    // command pool will be reset in resources.resizeRenderResources
    //vg.device.vkResetCommandPool( vg.cmd_pool, 0 ); // second argument is VkCommandPoolResetFlags

    return vg;
}



auto ref resetGlfwCallbacks( ref VDrive_Gui_State vg ) {
    // set glfw callbacks, these here wrap the callbacks in module input  
    glfwSetWindowSizeCallback(      vg.window, & guiWindowSizeCallback );
    glfwSetMouseButtonCallback(     vg.window, & guiMouseButtonCallback );
    glfwSetScrollCallback(          vg.window, &guiScrollCallback );
    glfwSetCharCallback(            vg.window, &guiCharCallback );
    glfwSetKeyCallback(             vg.window, & guiKeyCallback );

    return vg;
}



auto ref resizeRenderResources( ref VDrive_Gui_State vg ) {
    // forward to appstate resizeRenderResources
    import resources : resources_resizeRenderResources = resizeRenderResources;
    vg.resources_resizeRenderResources;

    // reset the command pool to start recording drawing commands
    vg.graphics_queue.vkQueueWaitIdle;   // equivalent using a fence per Spec v1.0.48
    vg.device.vkResetCommandPool( vg.cmd_pool, 0 ); // second argument is VkCommandPoolResetFlags

    // allocate vg.GUI_QUEUED_FRAMES command buffers
    import vdrive.command : allocateCommandBuffers;
    vg.allocateCommandBuffers( vg.cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, vg.cmd_buffers[ 0 .. vg.surface.imageCount ] );

    // gui io display size from surface extent
    auto io = & ImGui.GetIO();
    io.DisplaySize = ImVec2( vg.vd.windowWidth, vg.vd.windowHeight );

    return vg;
}



auto ref drawInit( ref VDrive_Gui_State vg ) {
    // forward to appstate drawInit
    import resources : resources_drawInit = drawInit;
    vg.resources_drawInit;
}



void draw( ref VDrive_Gui_State vg ) {

    // record next command buffer asynchronous
    vg.newGuiFrame;

    // forward to appstate drawInit
    import resources : resources_draw = draw;
    vg.resources_draw;
}


private {
    import dlsl.vector;
    bool show_test_window       = false;
    bool show_style_editor      = false;
    bool show_another_window    = false;

    int  button_height = 20;
    auto button_size = ImVec2( 100, 20 );

    int resetFrameMax   = 0;
    float minFramerate  = 10000, maxFramerate = 0.0001f;

    ImGuiWindowFlags window_flags = 0
        | ImGuiWindowFlags_NoTitleBar
        | ImGuiWindowFlags_ShowBorders
        | ImGuiWindowFlags_NoResize
        | ImGuiWindowFlags_NoMove
        | ImGuiWindowFlags_NoScrollbar
        | ImGuiWindowFlags_NoCollapse
    //  | ImGuiWindowFlags_MenuBar
        | ImGuiWindowFlags_NoSavedSettings;
}


auto ref newGuiFrame( ref VDrive_Gui_State vg ) {

    auto io = & ImGui.GetIO();
    auto style = & ImGui.GetStyle();

    // Setup display size (every frame to accommodate for window resizing)
    //int w, h;
    //int fb_w, fb_h;
    //glfwGetWindowSize( g_Window, &w, &h );
    //glfwGetFramebufferSize( g_Window, &fb_w, &fb_h );
    //io.DisplaySize = ImVec2( vg.vd.windowWidth, vg.vd.windowHeight );     // set in guiWindowSizeCallback
    //io.DisplayFramebufferScale = ImVec2( w > 0 ? (( float )fb_w / w ) : 0, h > 0 ? (( float )fb_h / h ) : 0 );

    // Setup time step
    auto current_time = cast( float )glfwGetTime();
    io.DeltaTime = g_Time > 0.0f ? ( current_time - g_Time ) : ( 1.0f / 60.0f );
    g_Time = current_time;

    // Setup inputs
    // (we already got mouse wheel, keyboard keys & characters from glfw callbacks polled in glfwPollEvents())
    if( glfwGetWindowAttrib( vg.vd.window, GLFW_FOCUSED )) {
        double mouse_x, mouse_y;
        glfwGetCursorPos( vg.vd.window, &mouse_x, &mouse_y );
        io.MousePos = ImVec2( cast( float )mouse_x, cast( float )mouse_y );   // Mouse position in screen coordinates (set to -1,-1 if no mouse / on another screen, etc.)
    } else {
        io.MousePos = ImVec2( -1, -1 );
    }

    for( int i = 0; i < 3; i++ ) {
        // If a mouse press event came, always pass it as "mouse held this frame", so we don't miss click-release events that are shorter than 1 frame.
        io.MouseDown[ i ] = g_MousePressed[ i ] || glfwGetMouseButton( vg.vd.window, i ) != 0;
        g_MousePressed[ i ] = false;
    }

    io.MouseWheel = g_MouseWheel;
    g_MouseWheel = 0.0f;

    // Hide OS mouse cursor if ImGui is drawing it
    glfwSetInputMode( vg.vd.window, GLFW_CURSOR, io.MouseDrawCursor ? GLFW_CURSOR_HIDDEN : GLFW_CURSOR_NORMAL );

    // Start the frame
    ImGui.NewFrame;

    // 1. Show a simple window
    // Tip: if we don't call ImGui.Begin()/ImGui.End() the widgets appears in a window automatically called "Debug"

    auto next_win_pos = ImVec2( 0, 0 ); ImGui.SetNextWindowPos( next_win_pos, ImGuiSetCond_Always );
    auto next_win_size = ImVec2( 350, io.DisplaySize.y ); ImGui.SetNextWindowSize( next_win_size, ImGuiSetCond_Always );
    ImGui.Begin( "Debugging", null, window_flags );
    {
        //static float f = 0.0f;
        ImGui.Text( "Hello, world!" );
        if( ImGui.SliderFloat( "Gui Window Alpha", &style.Colors[ ImGuiCol_WindowBg ].w, 0.0f, 1.0f ))
            style.Colors[ ImGuiCol_ChildWindowBg ].w = style.Colors[ ImGuiCol_WindowBg ].w;

        if( ImGui.SliderInt( "Button Height", button_height, 1, 100 ))
            button_size.y = button_height;


        // little hacky, but works - as we know that the corresponding clear value index
        ImGui.ColorEdit3( "clear color", cast( float* )( & vg.framebuffers.clear_values[ 1 ] ));

        //ImGui.ColorEdit3( "clear color", clear_color );
        if( ImGui.Button( "Test Window" )) show_test_window ^= 1;
        ImGui.SameLine;
        if( ImGui.Button( "Style Editor", button_size )) show_style_editor ^= 1;

        if( ImGui.Button( "Another Window" )) show_another_window ^= 1;
        if( ImGui.ImGui.GetIO().Framerate < minFramerate ) minFramerate = ImGui.ImGui.GetIO().Framerate;
        if( ImGui.ImGui.GetIO().Framerate > maxFramerate ) maxFramerate = ImGui.ImGui.GetIO().Framerate;
        if( resetFrameMax < 100 ) {
            ++resetFrameMax;
            maxFramerate = 0.0001f;
        }       
        ImGui.Text( "Application average %.3f ms/frame (%.1f FPS)", 1000.0f / ImGui.ImGui.GetIO().Framerate, ImGui.ImGui.GetIO().Framerate );
        ImGui.Text( "Application minimum %.3f ms/frame (%.1f FPS)", 1000.0f / minFramerate, minFramerate );
        ImGui.Text( "Application maximum %.3f ms/frame (%.1f FPS)", 1000.0f / maxFramerate, maxFramerate );

        // Specify Simulation Domain
        ImGui.DragInt2( "Domain", cast( int* )( vg.sim_domain.ptr ), 1.0f, 4, 4096 );

        if( vg.sim_play ) { if( ImGui.Button( "Pause", button_size )) vg.sim_play = false; }
        else              { if( ImGui.Button( "Play",  button_size ))  vg.sim_play = true;  }
        
        ImGui.SameLine;
        if( ImGui.Button( "Step", button_size )) vg.sim_step = true;

        ImGui.SameLine;
        import resources : resetComputePipeline;
        if( ImGui.Button( "Reset", button_size )) vg.resetComputePipeline;
        
        //ImGui.Spacing();
        if( ImGui.CollapsingHeader( "Simulation Parameter" )) {
            // Specify omega and speed
            ImGui.DragFloat( "Spatial Unit",  vg.sim_unit_spatial,  0.01f );
            ImGui.DragFloat( "Temporal Unit", vg.sim_unit_temporal, 0.01f );
            float tau = 1 / vg.sim_ubo.omega;
            if( ImGui.DragFloat( "Tau", tau, 0.01f, 0, 2 )) { vg.sim_ubo.omega = 1 / tau; }
            if( ImGui.DragFloat( "Omega", vg.sim_ubo.omega, 0.01f, 0, 2 ))  vg.updateSimUBO;
            if( ImGui.DragFloat( "Speed", vg.sim_ubo.speed, 1.0f, 0, 256 )) vg.updateSimUBO;

        }
    } ImGui.End();

    // 2. Show another simple window, this time using an explicit Begin/End pair
    if( show_another_window ) {
        next_win_size = ImVec2( 200, 100 ); ImGui.SetNextWindowSize( next_win_size, ImGuiSetCond_FirstUseEver );
        ImGui.Begin( "Another Window", &show_another_window );
        ImGui.Text( "Hello" );
        ImGui.End();
    }

    // 3. Show the ImGui test window. Most of the sample code is in ImGui.ShowTestWindow()
    if( show_test_window ) {
        next_win_pos = ImVec2( 650, 20 ); ImGui.SetNextWindowPos( next_win_pos, ImGuiSetCond_FirstUseEver );
        ImGui.ShowTestWindow( &show_test_window );
    }

    if( show_style_editor ) {
        ImGui.Begin( "Style Editor", &show_style_editor );
        ImGui.ShowStyleEditor();
        ImGui.End();
    }


    ImGui.Render;

    return vg;
}



auto ref destroyResources( ref VDrive_Gui_State vg ) {

    // forward to appstate destroyResources, this also calls device.vkDeviceWaitIdle;
    import resources : resources_destroyResources = destroyResources;
    vg.resources_destroyResources;

    // now destroy all remaining gui resources
    foreach( i; 0 .. vg.GUI_QUEUED_FRAMES ) {
        vg.gui_vtx_buffers[ i ].destroyResources;
        vg.gui_idx_buffers[ i ].destroyResources;
    }

    // descriptor set and layout is destroyed in module resources
    import vdrive.state, vdrive.pipeline;
    vg.destroy( vg.cmd_pool );
    vg.destroy( vg.gui_graphics_pso );
    vg.gui_font_tex.destroyResources;

    ImGui.Shutdown;

    return vg;
}




extern( C++ ):

// This is the main rendering function that you have to implement and provide to ImGui (via setting up 'RenderDrawListsFn' in the ImGuiIO structure)
void drawGuiData( ImDrawData* draw_data ) {

    // get VDrive_Gui_State pointer from ImGuiIO.UserData
    auto vg = cast( VDrive_Gui_State* )( & ImGui.GetIO()).UserData;

    // one of the cmd_buffers is currently submitted
    // here we record into the other one
    //vg.next_image_index = ( vg.next_image_index + 1 ) % vg.GUI_QUEUED_FRAMES;

    // Todo(pp): for some reasons there is a vertex buffer per swapchain
    // as well as one memory object per vertex buffer
    // consolidate at least the memory object into one!

    // create the vertex buffer
    size_t vertex_size = draw_data.TotalVtxCount * ImDrawVert.sizeof;
    if( vg.gui_vtx_buffers[ vg.next_image_index ].memSize < vertex_size ) {
        vg.gui_vtx_buffers[ vg.next_image_index ].destroyResources;
        vg.gui_vtx_buffers[ vg.next_image_index ]
            .create( VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, vertex_size )
            .createMemory( VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT );
    }

    // create the index buffer
    size_t index_size = draw_data.TotalIdxCount * ImDrawIdx.sizeof;
    if( vg.gui_idx_buffers[ vg.next_image_index ].memSize < index_size ) {
        vg.gui_idx_buffers[ vg.next_image_index ].destroyResources;
        vg.gui_idx_buffers[ vg.next_image_index ]
            .create( VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, vertex_size )
            .createMemory( VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT );
    }

    // upload vertex and index data
    auto vert_ptr = cast( ImDrawVert* )vg.gui_vtx_buffers[ vg.next_image_index ].mapMemory;
    auto elem_ptr = cast( ImDrawIdx*  )vg.gui_idx_buffers[ vg.next_image_index ].mapMemory;
    import core.stdc.string : memcpy;
    for( int n = 0; n < draw_data.CmdListsCount; ++n ) {
        const ImDrawList* cmd_list = draw_data.CmdLists[ n ];
        memcpy( vert_ptr, cmd_list.VtxBuffer.Data, cmd_list.VtxBuffer.Size * ImDrawVert.sizeof );
        memcpy( elem_ptr, cmd_list.IdxBuffer.Data, cmd_list.IdxBuffer.Size * ImDrawIdx.sizeof  );
        vert_ptr += cmd_list.VtxBuffer.Size;
        elem_ptr += cmd_list.IdxBuffer.Size;
    }

    VkMappedMemoryRange[ 2 ] flush_ranges = [ vg.gui_vtx_buffers[ vg.next_image_index ].createMappedMemoryRange, vg.gui_idx_buffers[ vg.next_image_index ].createMappedMemoryRange ];
    ( *vg ).flushMappedMemoryRanges( flush_ranges );
    vg.gui_vtx_buffers[ vg.next_image_index ].unmapMemory;
    vg.gui_idx_buffers[ vg.next_image_index ].unmapMemory;

    ////////////////////////////////////
    // begin command buffer recording //
    ////////////////////////////////////

    // first attach the swapchain image related frambuffer to the render pass
    import vdrive.renderbuffer : attachFramebuffer;
    vg.render_pass.attachFramebuffer( vg.framebuffers( vg.next_image_index ));

    // convenience copy
    auto cmd_buffer = vg.cmd_buffers[ vg.next_image_index ];

    // begin the command buffer
    cmd_buffer.vkBeginCommandBuffer( &vg.gui_cmd_buffer_bi );

    // begin the render pass
    cmd_buffer.vkCmdBeginRenderPass( &vg.render_pass.begin_info, VK_SUBPASS_CONTENTS_INLINE );

    // take care of dynamic state
    cmd_buffer.vkCmdSetViewport( 0, 1, &vg.viewport );
    cmd_buffer.vkCmdSetScissor(  0, 1, &vg.scissors );

    // bind descriptor set
    cmd_buffer.vkCmdBindDescriptorSets(     // VkCommandBuffer              commandBuffer
        VK_PIPELINE_BIND_POINT_GRAPHICS,    // VkPipelineBindPoint          pipelineBindPoint
        vg.graphics_pso.pipeline_layout,    // VkPipelineLayout             layout
        0,                                  // uint32_t                     firstSet
        1,                                  // uint32_t                     descriptorSetCount
        &vg.descriptor.descriptor_set,      // const( VkDescriptorSet )*    pDescriptorSets
        0,                                  // uint32_t                     dynamicOffsetCount
        null                                // const( uint32_t )*           pDynamicOffsets
    );





    // bind graphics lucien pipeline
    cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_GRAPHICS, vg.graphics_pso.pipeline );

    // push constant the sim display scale 
    cmd_buffer.vkCmdPushConstants( vg.graphics_pso.pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, vec2.sizeof, vg.sim_display_scale.ptr );

    // buffer-less draw with build in gl_VertexIndex exclusively to generate position and texcoord data
    cmd_buffer.vkCmdDraw( 4, 1, 0, 0 ); // vertex count ,instance count ,first vertex ,first instance






    // bind gui pipeline
    cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_GRAPHICS, vg.gui_graphics_pso.pipeline );

    // bind vertex and index buffer
    VkDeviceSize vertex_offset;
    cmd_buffer.vkCmdBindVertexBuffers( 0, 1, & vg.gui_vtx_buffers[ vg.next_image_index ].buffer, & vertex_offset );
    cmd_buffer.vkCmdBindIndexBuffer( vg.gui_idx_buffers[ vg.next_image_index ].buffer, 0, VK_INDEX_TYPE_UINT16 );

    // setup scale and translation
    auto scale = 2.0f / vec2( vg.vd.windowWidth, vg.vd.windowHeight );
    auto translate = vec2( -1.0f );
    cmd_buffer.vkCmdPushConstants( vg.gui_graphics_pso.pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT,           0, vec2.sizeof, scale.ptr );
    cmd_buffer.vkCmdPushConstants( vg.gui_graphics_pso.pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, vec2.sizeof, vec2.sizeof, translate.ptr );

    // record the command lists
    int vtx_offset = 0;
    int idx_offset = 0;
    for( int n = 0; n < draw_data.CmdListsCount; ++n ) {
        ImDrawList* cmd_list = draw_data.CmdLists[ n ];

        for( int cmd_i = 0; cmd_i < cmd_list.CmdBuffer.Size; ++cmd_i ) {
            ImDrawCmd* pcmd = &cmd_list.CmdBuffer[ cmd_i ];

            if( pcmd.UserCallback ) {
                pcmd.UserCallback( cmd_list, pcmd );
            } else {
                VkRect2D scissor;
                scissor.offset.x = cast( int32_t )( pcmd.ClipRect.x );
                scissor.offset.y = cast( int32_t )( pcmd.ClipRect.y );
                scissor.extent.width  = cast( uint32_t )( pcmd.ClipRect.z - pcmd.ClipRect.x );
                scissor.extent.height = cast( uint32_t )( pcmd.ClipRect.w - pcmd.ClipRect.y + 1 ); // TODO: + 1??????
                cmd_buffer.vkCmdSetScissor( 0, 1, &scissor );
                cmd_buffer.vkCmdDrawIndexed( pcmd.ElemCount, 1, idx_offset, vtx_offset, 0 );
            }
            idx_offset += pcmd.ElemCount;
        }
        vtx_offset += cmd_list.VtxBuffer.Size;
    }

    // end the render pass
    cmd_buffer.vkCmdEndRenderPass;

    // finish recording
    cmd_buffer.vkEndCommandBuffer;
}


private const( char )* getClipboardString( void* user_data ) {
    return glfwGetClipboardString( cast( GLFWwindow* )user_data );
}

private void setClipboardString( void* user_data, const( char )* text ) {
    glfwSetClipboardString( cast( GLFWwindow* )user_data, text );
}


extern( C ) nothrow:
void guiMouseButtonCallback( GLFWwindow* window, int button, int val, int mod ) {
    if( val == GLFW_PRESS && button >= 0 && button < 3 )
        g_MousePressed[ button ] = true;

    // forward to input.guiKeyCallback
    import input : inputMouseButtonCallback = mouseButtonCallback;
    inputMouseButtonCallback( window, button, val, mod );
}

void guiScrollCallback( GLFWwindow*, double /*xoffset*/, double yoffset ) {
    g_MouseWheel += cast( float )yoffset; // Use fractional mouse wheel, 1.0 unit 5 lines.
}


void guiCharCallback( GLFWwindow*, uint c ) {
    auto io = & ImGui.GetIO();
    if( c > 0 && c < 0x10000 )
        io.AddInputCharacter( cast( ImWchar )c );
}


void guiKeyCallback( GLFWwindow* window, int key, int scancode, int val, int mod ) {
    auto io = & ImGui.GetIO();
    //if( action == GLFW_PRESS )
        io.KeysDown[ key ] = val > 0;
    //if( action == GLFW_RELEASE )
        //io.KeysDown[ key ] = GLFW_RELEASE;

    //( void )mods; // Modifiers are not reliable across systems
    io.KeyCtrl  = io.KeysDown[ GLFW_KEY_LEFT_CONTROL    ] || io.KeysDown[ GLFW_KEY_RIGHT_CONTROL    ];
    io.KeyShift = io.KeysDown[ GLFW_KEY_LEFT_SHIFT      ] || io.KeysDown[ GLFW_KEY_RIGHT_SHIFT      ];
    io.KeyAlt   = io.KeysDown[ GLFW_KEY_LEFT_ALT        ] || io.KeysDown[ GLFW_KEY_RIGHT_ALT        ];
    io.KeySuper = io.KeysDown[ GLFW_KEY_LEFT_SUPER      ] || io.KeysDown[ GLFW_KEY_RIGHT_SUPER      ];

    // forward to input.guiKeyCallback
    import input : inputKeyCallback = keyCallback;
    inputKeyCallback( window, key, scancode, val, mod );
}


/// Callback Function for capturing window resize events
void guiWindowSizeCallback( GLFWwindow * window, int w, int h ) {
    auto io = & ImGui.GetIO();  
    auto vg = cast( VDrive_Gui_State* )io.UserData; // get VDrive_Gui_State pointer from ImGuiIO.UserData
    io.DisplaySize = ImVec2( vg.vd.windowWidth, vg.vd.windowHeight );

    // the extent might change at swapchain creation when the specified extent is not usable
    swapchainExtent( &vg.vd, w, h );
    vg.vd.window_resized = true;
}
