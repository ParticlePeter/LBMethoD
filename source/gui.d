module gui;

import erupted;
import imgui.types;
import ImGui = imgui.funcs_static;
import derelict.glfw3.glfw3;

debug import std.stdio;

//import vdrive.state;
import vdrive.memory;
import vdrive.pipeline;

import appstate;
import cpustate;
import exportstate;
import resources;

private {

    // GLFW Data
    float           g_Time = 0.0f;
    bool[ 3 ]       g_MousePressed = [ false, false, false ];
    float           g_MouseWheel = 0.0f;
}


////////////////////////////////
// struct of gui related data //
////////////////////////////////

struct VDrive_Gui_State {
    alias               vd this;
    VDrive_State        vd;
    //VDrive_Export_State ve;
    //VDrive_Cpu_State    vc;


    // gui resources
    Core_Pipeline               gui_graphics_pso;
    Meta_Image                  gui_font_tex;

    alias                               GUI_QUEUED_FRAMES = vd.MAX_FRAMES;
    Meta_Buffer[ GUI_QUEUED_FRAMES ]    gui_vtx_buffers;
    Meta_Buffer[ GUI_QUEUED_FRAMES ]    gui_idx_buffers;

    VkCommandBufferBeginInfo gui_cmd_buffer_bi = {
        flags : VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT
    };

    // gui helper and cache sim settings
    float       sim_relaxation_rate;    // tau
    float       sim_viscosity;          // at a relaxation rate of 1 and lattice units x, t = 1
    float       sim_wall_velocity;

    enum Line_Axis : uint8_t { X, Y, Z };
    enum Line_Type : uint8_t {
        velocity,
        vel_base,
        axis,
        grid,
        bounds,
        ghia,
        count,
    };

    enum Ghia_Type : int {
        re___100,
        re___400,
        re__1000,
        re__3200,
        re__5000,
        re__7500,
        re_10000,
    }

    struct Sim_Display {                // std140 conform
      align( 1 ):
        uint[3]     sim_domain;
        Line_Type   line_type       = Line_Type.velocity;
        Line_Axis   line_axis       = Line_Axis.Y;
        Line_Axis   repl_axis       = Line_Axis.X;
        Line_Axis   velocity_axis   = Line_Axis.X;
        int         repl_count      = 0;
        float       line_offset     = 0;
        float       repl_spread     = 1;
        float       point_size      = 1;
    }

    Sim_Display sim_display;

    // compute parameters
    uint32_t[3] sim_domain;
    uint32_t    sim_layers;
    uint32_t[3] sim_work_group_size;
    uint32_t    sim_step_size;
    float[2]    recip_window_size = [ 2.0f / 1600, 2.0f / 900 ];
    float[3]    point_size_line_width = [ 9, 3, 1 ];
    float       sim_typical_length;

    // count of command buffers to be drawn when in play mode
    uint32_t    sim_play_cmd_buffer_count;

    // ldc (0,1), taylor_green (2,4),
    int         init_shader_index   = 0;  // 0-based default init shader index, from all shaders in shader dir starting with init
    int         loop_shader_index   = 1;  // 0-based default loop shader index, from all shaders in shader dir starting with loop   
    Ghia_Type   sim_ghia_type       = Ghia_Type.re___100;

    bool        sim_use_double;
    bool        sim_use_3_dim;
    bool        sim_compute_dirty;
    bool        sim_work_group_dirty;
    bool        draw_gui = true;
    bool        draw_velocity_lines_as_points = false;
    bool        sim_profile_mode = false;   // Todo(pp): this is redundant as we can use play_mode bellow as well, remove this one

    bool        sim_draw_lines = true;
    bool        sim_draw_vel_base = true;
    bool        sim_draw_axis;
    bool        sim_draw_grid;
    bool        sim_draw_scale = true;
    bool        sim_draw_bounds;
    bool        sim_validate_ghia;
    bool        sim_validate_poiseuille_flow;
    bool        sim_validate_taylor_green;
    bool        sim_validate_velocity = true;
    bool        sim_validate_vel_base = false;

}



//////////////////////
// initialize imgui //
//////////////////////

void initImgui( ref VDrive_Gui_State vg ) {

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
    auto style                      = & ImGui.GetStyle();
    //  style.Alpha                     = 1;    // Global Alpah
    style.WindowPadding             = ImVec2( 4, 4 );
    //  style.WindowMinSize
    style.WindowRounding            = 0;
    //  style.WindowTitleAlign
    style.ChildWindowRounding       = 4;
    //  style.FramePadding
    style.FrameRounding             = 3;
    style.ItemSpacing               = ImVec2( 4, 4 );
    //  style.ItemInnerSpacing
    //  style.TouchExtraPadding
    //  style.IndentSpacing
    //  style.ColumnsMinSpacing
    //  style.ScrollbarSize
    style.ScrollbarRounding         = 3;
    style.GrabMinSize               = 7;
    style.GrabRounding              = 2;
    //  style.ButtonTextAlign
    //  style.DisplayWindowPadding
    //  style.DisplaySafeAreaPadding
    //  style.AntiAliasedLines
    //  style.AntiAliasedShapes
    //  style.CurveTessellationTol

    style.Colors[ ImGuiCol_Text ]                   = ImVec4( 0.90f, 0.90f, 0.90f, 1.00f ); //ImVec4( 0.90f, 0.90f, 0.90f, 1.00f );
    style.Colors[ ImGuiCol_TextDisabled ]           = ImVec4( 0.60f, 0.60f, 0.60f, 1.00f ); //ImVec4( 0.60f, 0.60f, 0.60f, 1.00f );
    style.Colors[ ImGuiCol_WindowBg ]               = ImVec4( 0.00f, 0.00f, 0.00f, 0.50f ); //ImVec4( 0.00f, 0.00f, 0.00f, 0.50f );
    style.Colors[ ImGuiCol_ChildWindowBg ]          = ImVec4( 0.00f, 0.00f, 0.00f, 0.00f ); //ImVec4( 0.00f, 0.00f, 0.00f, 0.50f );
    style.Colors[ ImGuiCol_PopupBg ]                = ImVec4( 0.05f, 0.05f, 0.10f, 1.00f ); //ImVec4( 0.05f, 0.05f, 0.10f, 1.00f );
    style.Colors[ ImGuiCol_Border ]                 = ImVec4( 0.37f, 0.37f, 0.37f, 0.25f ); //ImVec4( 0.37f, 0.37f, 0.37f, 0.25f );
    style.Colors[ ImGuiCol_BorderShadow ]           = ImVec4( 0.00f, 0.00f, 0.00f, 0.00f ); //ImVec4( 0.00f, 0.00f, 0.00f, 0.00f );
    style.Colors[ ImGuiCol_FrameBg ]                = ImVec4( 0.25f, 0.25f, 0.25f, 1.00f ); //ImVec4( 0.25f, 0.25f, 0.25f, 1.00f );
    style.Colors[ ImGuiCol_FrameBgHovered ]         = ImVec4( 0.40f, 0.40f, 0.40f, 1.00f ); //ImVec4( 0.50f, 0.50f, 0.50f, 1.00f );
    style.Colors[ ImGuiCol_FrameBgActive ]          = ImVec4( 0.50f, 0.50f, 0.50f, 1.00f ); //ImVec4( 0.65f, 0.65f, 0.65f, 1.00f );
    style.Colors[ ImGuiCol_TitleBg ]                = ImVec4( 0.16f, 0.26f, 0.38f, 1.00f ); //ImVec4( 0.27f, 0.27f, 0.54f, 0.83f );
    style.Colors[ ImGuiCol_TitleBgCollapsed ]       = ImVec4( 0.16f, 0.26f, 0.38f, 1.00f ); //ImVec4( 0.40f, 0.40f, 0.80f, 0.20f );
    style.Colors[ ImGuiCol_TitleBgActive ]          = ImVec4( 0.19f, 0.30f, 0.41f, 1.00f ); //ImVec4( 0.22f, 0.35f, 0.50f, 1.00f );
    style.Colors[ ImGuiCol_MenuBarBg ]              = ImVec4( 0.16f, 0.26f, 0.38f, 0.50f ); //ImVec4( 0.40f, 0.40f, 0.55f, 0.80f );
    style.Colors[ ImGuiCol_ScrollbarBg ]            = ImVec4( 0.25f, 0.25f, 0.25f, 0.60f ); //ImVec4( 0.25f, 0.25f, 0.25f, 0.60f );
    style.Colors[ ImGuiCol_ScrollbarGrab ]          = ImVec4( 0.40f, 0.40f, 0.40f, 1.00f ); //ImVec4( 0.40f, 0.40f, 0.40f, 1.00f );
    style.Colors[ ImGuiCol_ScrollbarGrabHovered ]   = ImVec4( 0.22f, 0.35f, 0.50f, 1.00f ); //ImVec4( 0.50f, 0.50f, 0.50f, 1.00f );
    style.Colors[ ImGuiCol_ScrollbarGrabActive ]    = ImVec4( 0.27f, 0.43f, 0.63f, 1.00f ); //ImVec4( 0.00f, 0.50f, 1.00f, 1.00f );
    style.Colors[ ImGuiCol_ComboBg ]                = ImVec4( 0.20f, 0.20f, 0.20f, 1.00f ); //ImVec4( 0.20f, 0.20f, 0.20f, 1.00f );
    style.Colors[ ImGuiCol_CheckMark ]              = ImVec4( 0.41f, 0.65f, 0.94f, 1.00f ); //ImVec4( 0.27f, 0.43f, 0.63f, 1.00f ); //ImVec4( 0.90f, 0.90f, 0.90f, 1.00f );
    style.Colors[ ImGuiCol_SliderGrab ]             = ImVec4( 1.00f, 1.00f, 1.00f, 0.25f ); //ImVec4( 1.00f, 1.00f, 1.00f, 0.25f );
    style.Colors[ ImGuiCol_SliderGrabActive ]       = ImVec4( 0.27f, 0.43f, 0.63f, 1.00f ); //ImVec4( 0.00f, 0.50f, 1.00f, 1.00f );
    style.Colors[ ImGuiCol_Button ]                 = ImVec4( 0.16f, 0.26f, 0.38f, 1.00f ); //ImVec4( 0.40f, 0.40f, 0.40f, 1.00f );
    style.Colors[ ImGuiCol_ButtonHovered ]          = ImVec4( 0.22f, 0.35f, 0.50f, 1.00f ); //ImVec4( 0.50f, 0.50f, 0.50f, 1.00f );
    style.Colors[ ImGuiCol_ButtonActive ]           = ImVec4( 0.27f, 0.43f, 0.63f, 1.00f ); //ImVec4( 0.00f, 0.50f, 1.00f, 1.00f );
    style.Colors[ ImGuiCol_Header ]                 = ImVec4( 0.16f, 0.26f, 0.38f, 1.00f ); //ImVec4( 0.40f, 0.40f, 0.90f, 1.00f );
    style.Colors[ ImGuiCol_HeaderHovered ]          = ImVec4( 0.22f, 0.35f, 0.50f, 1.00f ); //ImVec4( 0.45f, 0.45f, 0.90f, 1.00f );
    style.Colors[ ImGuiCol_HeaderActive ]           = ImVec4( 0.22f, 0.35f, 0.50f, 1.00f ); //ImVec4( 0.53f, 0.53f, 0.87f, 1.00f );
    style.Colors[ ImGuiCol_Separator ]              = ImVec4( 0.22f, 0.22f, 0.22f, 1.00f ); //ImVec4( 0.50f, 0.50f, 0.50f, 1.00f );
    style.Colors[ ImGuiCol_SeparatorHovered ]       = ImVec4( 0.60f, 0.60f, 0.60f, 1.00f ); //ImVec4( 0.60f, 0.60f, 0.60f, 1.00f );
    style.Colors[ ImGuiCol_SeparatorActive ]        = ImVec4( 0.70f, 0.70f, 0.70f, 1.00f ); //ImVec4( 0.70f, 0.70f, 0.70f, 1.00f );
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



    // as this is the first func called, without requiring any VDrive state
    // we use the opportunity to setup all the drawFunc function pointers
    vg.setDefaultSimFuncs;

}



//////////////////////////////////////////////////////////////////////////////////////////////
// create vulkan related command and synchronization objects and data updated for gui usage //
//////////////////////////////////////////////////////////////////////////////////////////////

void createCommandObjects( ref VDrive_Gui_State vg ) {
    resources.createCommandObjects( vg, VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT );
}



//////////////////////////////////////////////////////
// create simulation and gui related memory objects //
//////////////////////////////////////////////////////

void createMemoryObjects( ref VDrive_Gui_State vg ) {
    resources.createMemoryObjects( vg );

    // get available devices, store their names concatenated in private devices pointer
    // with this we can list them in an ImGui.Combo and make them selectable
    import vdrive.util.info;
    size_t devices_char_count = 4;
    auto gpus = vg.instance.listPhysicalDevices( false );
    device_count += cast( ubyte )gpus.length;
    //devices_char_count += device_count * size_t.sizeof;  // sizeof( some_pointer );

    import core.stdc.string : strlen;
    foreach( ref gpu; gpus ) {
        devices_char_count += strlen( gpu.listProperties.deviceName.ptr ) + 1;
    }

    import core.stdc.stdlib : malloc;
    device_names = cast( char* )malloc( devices_char_count + 1 );   // + 1 for second terminating zero
    device_names[ 0 .. 4 ] = "CPU\0";

    char* device_name_target = device_names + 4;
    import core.stdc.string : strcpy;
    foreach( ref gpu; gpus ) {
        strcpy( device_name_target, gpu.listProperties.deviceName.ptr );
        device_name_target += strlen( gpu.listProperties.deviceName.ptr ) + 1;
    }

    // even though the allocated memory range seems to be \0 initialized we set the last char to \0 to be sure
    device_names[ devices_char_count ] = '\0';  // we allocated devices_char_count + 1, hence no -1 required


    // initialize VDrive_Gui_State member from VDrive_State member
    vg.sim_domain               = vg.vd.sim_domain;
    vg.sim_typical_length       = vg.vd.sim_domain[0];
    vg.sim_layers               = vg.vd.sim_layers;
    vg.sim_work_group_size      = vg.vd.sim_work_group_size;
    vg.sim_step_size            = vg.vd.sim_step_size;
    vg.sim_use_double           = vg.vd.sim_use_double;
    vg.sim_use_3_dim            = vg.vd.sim_use_3_dim;
    vg.sim_wall_velocity        = vg.compute_ubo.wall_velocity * vg.sim_speed_of_sound * vg.sim_speed_of_sound;
    vg.sim_relaxation_rate      = 1 / vg.compute_ubo.collision_frequency;
    vg.sim_display.sim_domain   = vg.vd.sim_domain;

    vg.updateViscosity;

    vg.sim_viscosity = 0.001 * vg.sim_typical_length;
    vg.updateTauOmega;
    /*
    import dlsl.vector;
    import std.stdio;
    uvec3 Domain = uvec3( vg.sim_domain );
    uvec3 gl_WorkGroupSize = uvec3( vg.sim_work_group_size );
    uvec3 gl_NumWorkGroups = uvec3( vg.sim_domain ) / gl_WorkGroupSize;
    uvec3 gl_WorkGroupID;
    uvec3 gl_LocalInvocationID;
    uvec3 gl_GlobalInvocationID;
    foreach( gl_WorkGroupID_z; 0 .. gl_NumWorkGroups.z )        { gl_WorkGroupID.z = gl_WorkGroupID_z;
    foreach( gl_WorkGroupID_y; 0 .. gl_NumWorkGroups.y )        { gl_WorkGroupID.y = gl_WorkGroupID_y;
    foreach( gl_WorkGroupID_x; 0 .. gl_NumWorkGroups.x )        { gl_WorkGroupID.x = gl_WorkGroupID_x;
    foreach( gl_LocalInvocationID_z; 0 .. gl_WorkGroupSize.z )  { gl_LocalInvocationID.z = gl_LocalInvocationID_z;
    foreach( gl_LocalInvocationID_y; 0 .. gl_WorkGroupSize.y )  { gl_LocalInvocationID.y = gl_LocalInvocationID_y;
    foreach( gl_LocalInvocationID_x; 0 .. gl_WorkGroupSize.x )  { gl_LocalInvocationID.x = gl_LocalInvocationID_x;
        gl_GlobalInvocationID = gl_WorkGroupID * gl_WorkGroupSize + gl_LocalInvocationID;

        uint gl_LocalInvocationIndex =
            gl_LocalInvocationID.z * gl_WorkGroupSize.x * gl_WorkGroupSize.y +
            gl_LocalInvocationID.y * gl_WorkGroupSize.x +
            gl_LocalInvocationID.x;

        uint gl_WorkGroupIndex =
            gl_WorkGroupID.z * gl_NumWorkGroups.z * gl_NumWorkGroups.y +
            gl_WorkGroupID.y * gl_NumWorkGroups.x +
            gl_WorkGroupID.x;

        uint I = gl_WorkGroupIndex * gl_WorkGroupSize.x * gl_WorkGroupSize.y * gl_WorkGroupSize.z + gl_LocalInvocationIndex;


            //gl_WorkGroupID.z * gl_WorkGroupSize.z + gl_LocalInvocationID.z * Domain.x * Domain.y + // in the 2D case gl_GlobalInvocationID.z is const and 0
            //gl_WorkGroupID.y * gl_WorkGroupSize.y + gl_LocalInvocationID.y * Domain.x +
            //gl_WorkGroupID.x * gl_WorkGroupSize.x + gl_LocalInvocationID.x;

        //writeln( "         gl_WorkGroupID : ", gl_WorkGroupID );
        //writeln( "       gl_WorkGroupSize : ", gl_WorkGroupSize );
        //writeln( "   gl_LocalInvocationID : ", gl_LocalInvocationID );
        //writeln( "  gl_GlobalInvocationID : ", gl_GlobalInvocationID );
        //writeln( "gl_LocalInvocationIndex : ", gl_LocalInvocationIndex );
        writeln( "                      I : ", I );
        //writeln;
    }}}}}}
    */




    // collect useable shaders
    //if( hasShaderDirChanged( "shader" ))
    parseShaderDirectory;
    compareShaderNamesAndReplace( shader_names_ptr[ init_shader_start_index + vg.init_shader_index ], vg.sim_init_shader );
    compareShaderNamesAndReplace( shader_names_ptr[ loop_shader_start_index + vg.loop_shader_index ], vg.sim_loop_shader );

    /*
    import std.stdio;
    printf( shader_names_ptr[ 1 ] );
    writefln( " and %s are %s", vg.sim_init_shader,
        compareShaderNamesAndReplace( shader_names_ptr[ 1 ], vg.sim_init_shader ) ? "equal!" : "not equal!" );

    printf( shader_names_ptr[ 1 ] );
    writefln( " and %s are %s", vg.sim_init_shader,
        compareShaderNamesAndReplace( shader_names_ptr[ 1 ], vg.sim_init_shader ) ? "equal!" : "not equal!" );
    */

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

}



//////////////////////////////////////////////////////
// create simulation and gui related descriptor set //
//////////////////////////////////////////////////////

void createDescriptorSet( ref VDrive_Gui_State vg ) {

    // start configuring descriptor set, pass the temporary meta_descriptor
    // as a pointer to references.createDescriptorSet, where additional
    // descriptors will be added, the set constructed and stored in
    // vd.descriptor of type Core_Descriptor

    import vdrive.descriptor;
    Meta_Descriptor meta_descriptor;    // temporary
    meta_descriptor( vg )
        .addLayoutBinding/*Immutable*/( 1, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, VK_SHADER_STAGE_FRAGMENT_BIT )
        .addImageInfo( vg.gui_font_tex.image_view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, vg.gui_font_tex.sampler );

    // forward to appstate createDescriptorSet with the currently being configured meta_descriptor
    resources.createDescriptorSet( vg, & meta_descriptor );

}



//////////////////////////////////////////////////////
// create appstate and gui related render resources //
//////////////////////////////////////////////////////


void createRenderResources( ref VDrive_Gui_State vg ) {



    // forward to appstate createRenderResources
    resources.createRenderResources( vg );



    ///////////////////////////////////////////
    // create imgui related render resources //
    ///////////////////////////////////////////

    // create pipeline for gui rendering
    import vdrive.shader, vdrive.swapchain, vdrive.pipeline;
    Meta_Graphics meta_graphics;   // temporary construction struct
    vg.gui_graphics_pso = meta_graphics( vg )
        .addShaderStageCreateInfo( vg.createPipelineShaderStage( VK_SHADER_STAGE_VERTEX_BIT,   "shader/imgui.vert" ))
        .addShaderStageCreateInfo( vg.createPipelineShaderStage( VK_SHADER_STAGE_FRAGMENT_BIT, "shader/imgui.frag" ))
        .addBindingDescription( 0, ImDrawVert.sizeof, VK_VERTEX_INPUT_RATE_VERTEX ) // add vertex binding and attribute descriptions
        .addAttributeDescription( 0, 0, VK_FORMAT_R32G32_SFLOAT,  0 ) // interleaved attributes of ImDrawVert ...
        .addAttributeDescription( 1, 0, VK_FORMAT_R32G32_SFLOAT,  ImDrawVert.uv.offsetof  )
        .addAttributeDescription( 2, 0, VK_FORMAT_R8G8B8A8_UNORM, ImDrawVert.col.offsetof )
        .inputAssembly( VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST )                   // set the inputAssembly
        .addViewportAndScissors( VkOffset2D( 0, 0 ), vg.swapchain.imageExtent ) // add viewport and scissor state, necessary even if we use dynamic state
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
    import vdrive.command : allocateCommandBuffer, createCmdBufferBI;
    auto cmd_buffer = vg.allocateCommandBuffer( vg.cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY );
    auto cmd_buffer_bi = createCmdBufferBI( VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT );
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

}



void resetGlfwCallbacks( ref VDrive_Gui_State vg ) {
    // set glfw callbacks, these here wrap the callbacks in module input
    glfwSetWindowSizeCallback(      vg.window, & guiWindowSizeCallback );
    glfwSetMouseButtonCallback(     vg.window, & guiMouseButtonCallback );
    glfwSetScrollCallback(          vg.window, & guiScrollCallback );
    glfwSetCharCallback(            vg.window, & guiCharCallback );
    glfwSetKeyCallback(             vg.window, & guiKeyCallback );

}



void resizeRenderResources( ref VDrive_Gui_State vg ) {
    // forward to appstate resizeRenderResources
    resources.resizeRenderResources( vg );

    // reset the command pool to start recording drawing commands
    vg.graphics_queue.vkQueueWaitIdle;   // equivalent using a fence per Spec v1.0.48
    vg.device.vkResetCommandPool( vg.cmd_pool, 0 ); // second argument is VkCommandPoolResetFlags

    // allocate vg.GUI_QUEUED_FRAMES command buffers
    import vdrive.command : allocateCommandBuffers;
    vg.allocateCommandBuffers( vg.cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, vg.cmd_buffers[ 0 .. vg.swapchain.imageCount ] );

    // gui io display size from swapchain extent
    auto io = & ImGui.GetIO();
    io.DisplaySize = ImVec2( vg.vd.windowWidth, vg.vd.windowHeight );

}



///////////////////////////////////
// Exit destroying all resources //
///////////////////////////////////

void destroyResources( ref VDrive_Gui_State vg ) {

    // forward to appstate destroyResources, this also calls device.vkDeviceWaitIdle;
    resources.destroyResources( vg );

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

    import core.stdc.stdlib : free;
    free( device_names );

    ImGui.Shutdown;

}



///////////////////////////////////////////////////////
// Draw function pointer for play, pause and profile //
///////////////////////////////////////////////////////

enum Transport { pause, play, step, profile };

Transport transport = Transport.pause;
Transport play_mode = Transport.play;

//
// Actually a function pointer so that we can set it with the purpose of cpu sim or export
//
alias Draw_Func = void function( ref VDrive_Gui_State vg ) nothrow @system;
private Draw_Func draw_func_play;
private Draw_Func draw_func_profile;


void setDefaultSimFuncs( ref VDrive_Gui_State vg ) nothrow @system {
    draw_func_play      = & drawFuncPlay;
    draw_func_profile   = & drawFuncProfile;

    vg.sim_play_cmd_buffer_count = 2;

    //vg.simPause;
}



void setSimFuncPlay( ref VDrive_Gui_State vg, Draw_Func func ) nothrow @system {
    if( func is null )  draw_func_play = & drawFuncPlay;
    else                draw_func_play = func;

    //vg.simPlay;     // Todo(pp): is this really necessary? Transport Controls should be public for fine grained control
}

void setSimFuncProfile( ref VDrive_Gui_State vg, Draw_Func func ) nothrow @system {
    if( func is null )  draw_func_profile = & drawFuncProfile;
    else                draw_func_profile = func;
}


private {
    // this is the default draw_func function, we need it outside of VDrive_State
    // now we can perfectly control single stepping through the gui
    // we must wrap the VDrive_State functions as they require a VDrive_State reference
    // but other functions require the whole VDrive_Gui_State
    void drawFuncPlay( ref VDrive_Gui_State vg ) nothrow @system {
        appstate.drawSim( vg.vd );
    }


    void drawFuncProfile( ref VDrive_Gui_State vg ) nothrow @system {
        appstate.profileCompute( vg.vd );
    }



    void drawStep(ref VDrive_Gui_State vg ) nothrow @system {
        vg.drawCmdBufferCount = vg.sim_play_cmd_buffer_count;
        vg.draw_func_play;
        vg.drawCmdBufferCount = 1;
        transport = Transport.pause;
    }

    void drawProfile( ref VDrive_Gui_State vg ) nothrow @system {
        vg.sim_profile_step_index += vg.sim_profile_step_size;
        vg.draw_func_profile;

        if( 0 < vg.sim_profile_step_count && vg.sim_profile_step_index >= vg.sim_profile_step_count ) {
            vg.simPause;
        }
    }

    //
    // transport control funcs
    //
    void simPause( ref VDrive_Gui_State vg ) nothrow @system {
        transport = Transport.pause;
        vg.drawCmdBufferCount = 1;
    }

    void simPlay( ref VDrive_Gui_State vg ) nothrow @system {
        if( vg.sim_profile_mode && vg.sim_profile_step_count <= vg.sim_profile_step_index ) {
            vg.sim_profile_step_index = 0;
            vg.resetStopWatch;
        }
        transport = play_mode; // Transport.play or Transport.profile;
        vg.drawCmdBufferCount = vg.sim_play_cmd_buffer_count;
    }

    void simStep( ref VDrive_Gui_State vg ) nothrow @system {
        if( !vg.isPlaying ) {
            transport = Transport.step;
        }
    }

    void simReset( ref VDrive_Gui_State vg ) nothrow @system {
        if( vg.sim_profile_mode ) {
            vg.sim_profile_step_index = 0;
            vg.resetStopWatch;
        }
        vg.sim_index = 0;
        try {
            if( vg.sim_use_cpu ) {
                vg.cpuInit;
            } else {
                vg.createBoltzmannPSO( false, false, true );  // rebuild init pipeline, rebuild loop pipeline, reset domain
            }
        } catch( Exception ) {}
    }

    bool isPlaying( ref VDrive_Gui_State vg ) nothrow @system {
        return transport != Transport.pause;
    }
}



///////////////////////////////////
// Loop draw called in main loop //
///////////////////////////////////

void draw( ref VDrive_Gui_State vg ) {

    // record next command buffer asynchronous
    if( vg.draw_gui )   // this can't be a function pointer as well
        vg.drawGui;     // as we wouldn't know what else has to be drawn (drawFunc or drawFuncPlay etc. )

    final switch( transport ) {
        case Transport.pause    : appstate.draw( vg.vd );   break;
        case Transport.play     : vg.draw_func_play;        break;
        case Transport.step     : vg.drawStep;              break;
        case Transport.profile  : vg.drawProfile;           break;
    }
    // call function pointer
    //vg.draw_func;
}



//////////////////////////
// private module stuff //
//////////////////////////

private {
    bool show_test_window           = false;
    bool show_style_editor          = false;
    bool show_another_window        = false;
    bool show_imgui_examples        = false;

    //
    // used to determine fps
    //
    int resetFrameMax   = 0;
    float minFramerate  = 10000, maxFramerate = 0.0001f;

    //
    // Base item settings
    //
    immutable auto main_win_pos     = ImVec2( 0, 0 );
    auto main_win_size              = ImVec2( 352, 900 );

    auto scale_win_pos              = ImVec2( 1550, 710 );
    immutable auto scale_win_size   = ImVec2(   50,  20 );

    immutable auto button_size_1    = ImVec2( 344, 20 );
    immutable auto button_size_2    = ImVec2( 176, 20 );
    immutable auto button_size_3    = ImVec2( 112, 20 );
    immutable auto button_size_4    = ImVec2(  85, 20 );

    immutable auto disabled_text    = ImVec4( 0.4, 0.4, 0.4, 1 );

    ubyte   device_count  = 1;      // initialize with one being the CPU
    char*   device_names;           // store all names of physical devices consecutively
    int     compute_device = 1;     // select compute device, 0 = CPU
    //char**  device_names_ptr;     // store pointers to each individual string


    void checkComputeParams( ref VDrive_Gui_State vg ) {
        vg.sim_compute_dirty =
            ( vg.vd.sim_use_double  != vg.sim_use_double )
        ||  ( vg.vd.sim_use_3_dim   != vg.sim_use_3_dim )
        ||  ( vg.vd.sim_domain != vg.sim_domain )
        ||  ( vg.vd.sim_layers != vg.sim_layers );
    }

    void checkComputePSO( ref VDrive_Gui_State vg ) {
        vg.sim_work_group_dirty = vg.vd.sim_work_group_size != vg.sim_work_group_size;
    }

    void updateTauOmega( ref VDrive_Gui_State vg ) {
        //float speed_of_sound_squared = vg.sim_speed_of_sound * vg.sim_speed_of_sound;
        //vg.compute_ubo.collision_frequency =
        //    2 * speed_of_sound_squared /
        //    ( vg.sim_unit_temporal * ( 2 * vg.sim_viscosity + speed_of_sound_squared ));
        //vg.sim_relaxation_rate = 1 / vg.compute_ubo.collision_frequency;
        vg.sim_relaxation_rate = 3 * vg.sim_viscosity + 0.5;
        vg.compute_ubo.collision_frequency = 1 / vg.sim_relaxation_rate;
        vg.updateComputeUBO;
    }

    void updateWallVelocity( ref VDrive_Gui_State vg ) {
        float speed_of_sound_squared = vg.sim_speed_of_sound * vg.sim_speed_of_sound;
        vg.compute_ubo.wall_velocity = vg.sim_wall_velocity * 3;// / speed_of_sound_squared;
    }

    void updateViscosity( ref VDrive_Gui_State vg ) {
        //vg.sim_viscosity = vg.sim_speed_of_sound * vg.sim_speed_of_sound * ( vg.sim_relaxation_rate / vg.sim_unit_temporal - 0.5 );
        vg.sim_viscosity = 1.0 / 6 * ( 2 * vg.sim_relaxation_rate - 1 );
    }

    void pushButtonStyleDisable() {
        ImGui.PushStyleColor( ImGuiCol_Text, disabled_text );
        auto disabled_color = ImVec4( 0.08f, 0.13f, 0.19f, 1.00f );
        ImGui.PushStyleColor( ImGuiCol_Button, disabled_color );
        ImGui.PushStyleColor( ImGuiCol_ButtonHovered, disabled_color );
        ImGui.PushStyleColor( ImGuiCol_ButtonActive, disabled_color );
    }

    void popButtonStyleDisable() {
        ImGui.PopStyleColor( 4 );
    }

    void collapsingTerminator() {
        ImGui.Separator;
        ImGui.Spacing;
    }

    void showTooltip( const( char )* text, float wrap_position = 300 ) {
        //ImGui.TextDisabled("(?)");    // this should be called before showTooltip so we can customize it
        if( ImGui.IsItemHovered ) {
            ImGui.BeginTooltip;
            ImGui.PushTextWrapPos( wrap_position );
            ImGui.TextUnformatted( text );
            ImGui.PopTextWrapPos;
            ImGui.EndTooltip;
        }
    }



    /////////////////////////////////////////////////////////////////////////////////////
    // store available shader names concatenated and pointer into it as dynamic arrays //
    /////////////////////////////////////////////////////////////////////////////////////

    import vdrive.util.array;
    Array!( const( char )* )    shader_names_ptr;
    Array!char                  shader_names_combined;

    // any of the following will be set to size_t max
    // if no shader of corresponding type is found
    size_t  init_shader_start_index = 0;
    size_t  loop_shader_start_index;
    size_t  draw_shader_start_index;
    size_t  export_shader_start_index;


    void parseShaderDirectoryNo( string path_to_dir = "shader" ) {
        init_shader_start_index     = size_t.max;
        loop_shader_start_index     = size_t.max;
        draw_shader_start_index     = size_t.max;
        export_shader_start_index   = size_t.max;
    }


    void parseShaderDirectory( string path_to_dir = "shader" ) {
        import std.file : dirEntries, SpanMode;
        import std.path : stripExtension;
        import std.array : array;
        import std.algorithm : filter, map, startsWith, endsWith, uniq;

        shader_dir = path_to_dir;
        shader_names_ptr.clear();
        shader_names_combined.clear();


        //
        // append init shader
        //
        dirEntries( path_to_dir, SpanMode.shallow )
            .filter!( f => f.name.startsWith( "shader\\init_" ))
            .filter!( f => f.name.endsWith( ".comp" ))
            .map!( f => f.name.stripExtension )
            .array
            .toPtrArray( shader_names_ptr, shader_names_combined, '\0' );


        // if shader_names_combined reallocated shader_names_ptr are invalid afterwards
        // hence we cast each pointer to the distance to his successor
        // the last appending operation will have valid pointers and we can use the
        // distances to reconstruct the correct pointers

        // store the last valid start pointer
        const( char )* last_start_pointer = null;
        size_t last_shader_count;
        if( 0 < shader_names_ptr.length ) {
            last_start_pointer = shader_names_ptr[0];

            // get distances of init shaders
            foreach( i, ptr; shader_names_ptr.data[ 1 .. $ ] )
                shader_names_ptr[ i ] = cast( const( char* ))( ptr - shader_names_ptr[ i ] );
            shader_names_ptr[ $ - 1 ] = cast( const( char* ))( & shader_names_combined[ $ - 1 ] + 1 - shader_names_ptr[ $ - 1 ] );

            // store the current shader count, should be the same as loop_shader_start_index
            last_shader_count = shader_names_ptr.length;
        } else
            init_shader_start_index = size_t.max;


        //
        // append loop shader
        //
        loop_shader_start_index = dirEntries( path_to_dir, SpanMode.shallow )
            .filter!( f => f.name.startsWith( "shader\\loop_" ))
            .filter!( f => f.name.endsWith( ".comp" ))
            .map!( f => f.name.stripExtension )
            .array
            .toPtrArray( shader_names_ptr, shader_names_combined, '\0' );

        // store the last valid start pointer
        if( last_shader_count  < shader_names_ptr.length ) {
            last_start_pointer = shader_names_ptr[ last_shader_count ];

            // get distances of loop shaders
            foreach( i, ptr; shader_names_ptr.data[ last_shader_count + 1 .. $ ] )
                shader_names_ptr[last_shader_count + i ] = cast( const( char* ))( ptr - shader_names_ptr[ last_shader_count + i ] );
            shader_names_ptr[ $ - 1 ] = cast( const( char* ))( & shader_names_combined[ $ - 1 ] + 1 - shader_names_ptr[ $ - 1 ] );

            // if store the current shader count, should be the same as draw_shader_start_index
            last_shader_count = shader_names_ptr.length;
        } else
            loop_shader_start_index = size_t.max;


        //
        // append draw display shader
        //
        draw_shader_start_index = dirEntries( path_to_dir, SpanMode.shallow )
            .filter!( f => f.name.startsWith( "shader\\display_" ))
            .filter!( f => f.name.endsWith( ".frag" ))
            .map!( f => f.name.stripExtension )
            .array
            .toPtrArray( shader_names_ptr, shader_names_combined, '\0' );


        // store the last valid start pointer
        if( last_shader_count  < shader_names_ptr.length ) {
            last_start_pointer = shader_names_ptr[ last_shader_count ];

            // get distances of draw display shaders
            foreach( i, ptr; shader_names_ptr.data[ last_shader_count + 1 .. $ ] )
                shader_names_ptr[ last_shader_count + i ] = cast( const( char* ))( ptr - shader_names_ptr[ last_shader_count + i ] );
            shader_names_ptr[ $ - 1 ] = cast( const( char* ))( & shader_names_combined[ $ - 1 ] + 1 - shader_names_ptr[ $ - 1 ] );

            // store the current shader count, should be the same as draw_shader_start_index
            last_shader_count = shader_names_ptr.length;
        } else
            draw_shader_start_index = size_t.max;

        //
        // append export shader
        //
        export_shader_start_index = dirEntries( path_to_dir, SpanMode.shallow )
            .filter!( f => f.name.startsWith( "shader\\export_" ))
            .filter!( f => f.name.endsWith( ".comp" ))
            .map!( f => f.name.stripExtension )
            .array
            .toPtrArray( shader_names_ptr, shader_names_combined, '\0' );

        // store the last valid start pointer
        if( last_shader_count  < shader_names_ptr.length ) {
            last_start_pointer = shader_names_ptr[ last_shader_count ];

            // get distances of draw display shaders
            foreach( i, ptr; shader_names_ptr.data[ last_shader_count + 1 .. $ ] )
                shader_names_ptr[ last_shader_count + i ] = cast( const( char* ))( ptr - shader_names_ptr[ last_shader_count + i ] );
            shader_names_ptr[ $ - 1 ] = cast( const( char* ))( & shader_names_combined[ $ - 1 ] + 1 - shader_names_ptr[ $ - 1 ] );

            // store the current shader count, should be the same as draw_shader_start_index
            last_shader_count = shader_names_ptr.length;
        } else
            export_shader_start_index = size_t.max;

        // the distance stored at index last_shader_count is not needed any more
        // set the location to the last valid start pointer
        shader_names_ptr[ $ - 1 ] = shader_names_combined.ptr + shader_names_combined.length - cast( int )shader_names_ptr[ $ - 1 ];

        //auto reconstruct_ptr =
        // now patch shader_names_ptr going backwards from index last_shader_count
        // fixing previous pointers with distances stored starting a last_shader_count - 1
        foreach_reverse( i, ptr; shader_names_ptr.data[ 1 .. $ ] ) {
            shader_names_ptr[ i ] = ptr - cast( int )shader_names_ptr[ i ];
        }


        //  foreach( shader; shader_names_ptr ) {
        //      import core.stdc.stdio : printf;
        //      printf( "%s\n", shader );
        //  }
    }

    //
    // comapere shader names of currently used shader and currently selected shader
    //
    bool compareShaderNamesAndReplace( const( char* ) gui_shader, ref string sim_shader ) {
        import std.conv : to;
        import std.algorithm : cmp;
        import std.string : fromStringz;
        import std.path : extension, stripExtension;

        bool equal = cmp( gui_shader.fromStringz, sim_shader.stripExtension ) == 0;
        if( !equal ) sim_shader = gui_shader.fromStringz.to!string ~ sim_shader.extension;
        //import std.stdio;
        //writeln( sim_shader );
        return equal;
    }

    //
    // detect if shader directory was modified
    //
    import std.datetime : SysTime;
    SysTime shader_dir_mod_time;
    string  shader_dir;

    bool hasShaderDirChanged( string path_to_dir = "shader" ) {
        import std.file : getTimes;
        SysTime access_time, mod_time;                          // access times are irrelevant
        path_to_dir.getTimes( access_time, mod_time );          // get dir mod times
        if( shader_dir_mod_time < mod_time || path_to_dir != shader_dir ) {
            shader_dir_mod_time = mod_time;
            return true;
        }
        return false;
    }

    //
    // window flags for the main UI window
    //
    ImGuiWindowFlags window_flags = 0
        | ImGuiWindowFlags_NoTitleBar
    //  | ImGuiWindowFlags_ShowBorders
        | ImGuiWindowFlags_NoResize
        | ImGuiWindowFlags_NoMove
        | ImGuiWindowFlags_NoScrollbar
        | ImGuiWindowFlags_NoCollapse
    //  | ImGuiWindowFlags_MenuBar
        | ImGuiWindowFlags_NoSavedSettings;
}





////////////////////////////////////
// Create and draw User Interface //
////////////////////////////////////

void drawGui( ref VDrive_Gui_State vg ) {

    auto io = & ImGui.GetIO();



    //
    // general per frame data
    //
    {
        // Setup time step
        auto current_time = cast( float )glfwGetTime();
        io.DeltaTime = g_Time > 0.0f ? ( current_time - g_Time ) : ( 1.0f / 60.0f );
        vg.xform_ubo.time_step = io.DeltaTime;
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

        // Todo(pp): move this into guiMouseButtonCallback
        for( int i = 0; i < 3; i++ ) {
            // If a mouse press event came, always pass it as "mouse held this frame", so we don't miss click-release events that are shorter than 1 frame.
            io.MouseDown[ i ] = g_MousePressed[ i ] || glfwGetMouseButton( vg.vd.window, i ) != 0;
            g_MousePressed[ i ] = false;
        }

        // Todo(pp): move this into guiScrollCallback
        io.MouseWheel = g_MouseWheel;
        g_MouseWheel = 0.0f;

        // Hide OS mouse cursor if ImGui is drawing it
        glfwSetInputMode( vg.vd.window, GLFW_CURSOR, io.MouseDrawCursor ? GLFW_CURSOR_HIDDEN : GLFW_CURSOR_NORMAL );

        // Start the frame
        ImGui.NewFrame;

        // 1. Show a simple window
        // Tip: if we don't call ImGui.Begin()/ImGui.End() the widgets appears in a window automatically called "Debug"

        //auto scale_win_pos  = ImVec2( 500, 500 );
        //auto scale_win_size = ImVec2( 50, 20 );

        ImGui.SetNextWindowPos(  scale_win_pos,  ImGuiCond_Always );
        ImGui.SetNextWindowSize( scale_win_size, ImGuiCond_Always );

        if( vg.sim_draw_scale ) {
            ImGui.PushStyleColor( ImGuiCol_WindowBg, 0 );
            ImGui.Begin( "Scale Window", null, window_flags );
            ImGui.Text( "%.3f", 1 / vg.display_ubo.amplify_property );
            ImGui.End();
            ImGui.PopStyleColor;
        }


        ImGui.SetNextWindowPos(  main_win_pos,  ImGuiCond_Always );
        ImGui.SetNextWindowSize( main_win_size, ImGuiCond_Always );
        ImGui.Begin( "Main Window", null, window_flags );

        // create transport controls at top of window
        if( vg.isPlaying ) { if( ImGui.Button( "Pause", button_size_3 )) simPause( vg ); }
        else               { if( ImGui.Button( "Play",  button_size_3 )) simPlay(  vg ); }
        ImGui.SameLine;      if( ImGui.Button( "Step",  button_size_3 )) simStep(  vg );
        ImGui.SameLine;      if( ImGui.Button( "Reset", button_size_3 )) simReset( vg );
        ImGui.Separator;

        // create transport controls at top of window
        //if( vg.sim_play ) { if( ImGui.Button( "Pause", button_size_3 )) { draw_func = & drawSim; vg.drawCmdBufferCount = 2; }
        //else              { if( ImGui.Button( "Play",  button_size_3 )) { draw_func = & draw;    vg.drawCmdBufferCount = 1; }
        //ImGui.SameLine;     if( ImGui.Button( "Step",  button_size_3 ) && !sim_play ) { vg.drawCmdBufferCount = 2; vg.drawSim; vg.drawCmdBufferCount = 1; }
        //ImGui.SameLine;     if( ImGui.Button( "Reset", button_size_3 )) vg.simReset;
        //ImGui.Separator;

        // set width of items and their label
        ImGui.PushItemWidth( main_win_size.x / 2 );
    }



    //
    // ImGui example Widgets
    //
    if( show_imgui_examples ) {

        auto style = & ImGui.GetStyle();

        // set gui transparency
        ImGui.SliderFloat( "Gui Alpha", &style.Colors[ ImGuiCol_WindowBg ].w, 0.0f, 1.0f );

        // little hacky, but works - as we know that the corresponding clear value index
        ImGui.ColorEdit3( "clear color", cast( float* )( & vg.framebuffers.clear_values[ 1 ] ));

        //ImGui.ColorEdit3( "clear color", clear_color );
        if( ImGui.Button( "Test Window", button_size_3 )) show_test_window ^= 1;
        ImGui.SameLine;
        if( ImGui.Button( "Another Window", button_size_3 )) show_another_window ^= 1;
        ImGui.SameLine;
        if( ImGui.Button( "Style Editor", button_size_3 )) show_style_editor ^= 1;

        if( ImGui.ImGui.GetIO().Framerate < minFramerate ) minFramerate = ImGui.ImGui.GetIO().Framerate;
        if( ImGui.ImGui.GetIO().Framerate > maxFramerate ) maxFramerate = ImGui.ImGui.GetIO().Framerate;
        if( resetFrameMax < 100 ) {
            ++resetFrameMax;
            maxFramerate = 0.0001f;
        }
        ImGui.Text( "Refresh average %.3f ms/frame (%.1f FPS)", 1000.0f / ImGui.ImGui.GetIO().Framerate, ImGui.ImGui.GetIO().Framerate );
        ImGui.Text( "Refresh minimum %.3f ms/frame (%.1f FPS)", 1000.0f / minFramerate, minFramerate );
        ImGui.Text( "Refresh maximum %.3f ms/frame (%.1f FPS)", 1000.0f / maxFramerate, maxFramerate );
        ImGui.Separator;
    }



    ////////////////////
    // Compute Device //
    ////////////////////

    if( ImGui.CollapsingHeader( "Compute Device" )) {
        ImGui.Separator;
        ImGui.PushItemWidth( -1 );
        if( ImGui.Combo( "Device", & compute_device, device_names )) {
            if( compute_device == 0 ) {
                vg.cpuReset;
                vg.setCpuSimFuncs;
                vg.sim_use_cpu = true;
                vg.drawCmdBufferCount = vg.sim_play_cmd_buffer_count = 1;
            } else {
                vg.setDefaultSimFuncs;
                vg.sim_use_cpu = false;
                vg.sim_use_double &= vg.feature_shader_double;
                if( play_mode == Transport.play ) {     // in profile mode this must stay 1 (switches with play/pause )
                    vg.sim_play_cmd_buffer_count = 2;   // as we submitted compute and draw command buffers separately
                    if( transport == Transport.play ) { // if we are in play mode
                        vg.drawCmdBufferCount = 2;      // we must set this value immediately
                    }
                }
            }
        }
        ImGui.PopItemWidth;

        collapsingTerminator;
    }



    ////////////////////////
    // Compute Parameters //
    ////////////////////////

    float drag_step = 16;
    if( ImGui.CollapsingHeader( "Compute Parameter" )) {
        ImGui.Separator;


        //
        // Shader or Function choice
        //
        if( compute_device > 0 ) {  // 0 is CPU, > 0 are available GPUs
            // Shader Choice

            ImGui.Spacing;
            ImGui.SetCursorPosX( 8 );
            ImGui.Text( "Compute Shader" );
            ImGui.Separator;

            // select init shader
            ImGui.PushItemWidth( ImGui.GetWindowWidth * 0.75 );
            if( ImGui.Combo( "Initialize", & vg.init_shader_index, //"shader/init_D2Q9.comp\0\0" )
                init_shader_start_index == size_t.max
                    ? "None found!"
                    : shader_names_ptr[ init_shader_start_index ] )
                ) {
                if( init_shader_start_index != size_t.max ) {
                    if(!compareShaderNamesAndReplace( shader_names_ptr[ init_shader_start_index + vg.init_shader_index ], vg.sim_init_shader )) {
                        vg.createBoltzmannPSO( true, false, true );
                    }
                }
            }

            // update init shader list when hovering over Combo
            if( ImGui.IsItemHovered ) {
                if( hasShaderDirChanged ) {
                    parseShaderDirectory;
                    // a new shader might replace the shader at the current index
                    // when we would actually use the ImGui.Combo and select this new shader
                    // the shader change would not be recognized
                    if( init_shader_start_index != size_t.max ) {     // might all have been deleted
                        if(!compareShaderNamesAndReplace( shader_names_ptr[ init_shader_start_index + vg.init_shader_index ], vg.sim_init_shader )) {
                            vg.createBoltzmannPSO( true, false, true );
                        }
                    }
                }
            }

            // parse init shader through context menu
            if( ImGui.BeginPopupContextItem( "Init Shader Context Menu" )) {
                if( ImGui.Selectable( "Parse Shader" )) {
                    vg.createBoltzmannPSO( true, false, true );
                } ImGui.EndPopup();
            }

            ImGui.Spacing;

            // select loop shader
            if( ImGui.Combo( "Simulate", & vg.loop_shader_index, //"shader/loop_D2Q9_channel_flow.comp\0\0" )
                loop_shader_start_index == size_t.max
                    ? "None found!"
                    : shader_names_ptr[ loop_shader_start_index ] )
                ) {
                if( loop_shader_start_index != size_t.max ) {
                    if(!compareShaderNamesAndReplace( shader_names_ptr[ loop_shader_start_index + vg.loop_shader_index ], vg.sim_loop_shader )) {
                        vg.createBoltzmannPSO( false, true, false );
                    }
                }
            }

            // update loop shader list when hovering over Combo
            if( ImGui.IsItemHovered ) {
                if( hasShaderDirChanged ) {
                    parseShaderDirectory;   // see comment in IsItemHovered above
                    if( loop_shader_start_index != size_t.max ) {
                        if(!compareShaderNamesAndReplace( shader_names_ptr[ loop_shader_start_index + vg.loop_shader_index ], vg.sim_loop_shader )) {
                            vg.createBoltzmannPSO( false, true, false );
                        }
                    }
                }
            }

            // parse loop shader through context menu
            if( ImGui.BeginPopupContextItem( "Loop Shader Context Menu" )) {
                if( ImGui.Selectable( "Parse Shader" )) {
                    vg.createBoltzmannPSO( false, true, false );
                } ImGui.EndPopup();
            }

            ImGui.PopItemWidth;

        } else {
            int func = 0;

            ImGui.SetCursorPosX( 8 );
            ImGui.Text( "CPU Function" );
            ImGui.Separator;

            int init_and_loop;
            ImGui.PushItemWidth( ImGui.GetWindowWidth() * 0.75 );
            ImGui.Combo( "Initialize", & init_and_loop, "D2Q9 Density One\0\0" );
            ImGui.Separator;
            ImGui.Combo( "Simulate", & init_and_loop, "D2Q9 Lid Driven Cavity\0\0" );
            ImGui.PopItemWidth;
        }
        ImGui.Separator;

        //
        // Radio 2D or 3D
        //
        int dimensions = vg.sim_use_3_dim;
        if( ImGui.RadioButton( "2D", & dimensions, 0 )) {
            vg.sim_use_3_dim = false;
            vg.sim_domain[2] = 1;
            vg.checkComputeParams;
        }

        ImGui.SameLine;
        ImGui.SetCursorPosX( main_win_size.x * 0.25 + 6 );
        if( ImGui.RadioButton( "3D", & dimensions, 1 )) vg.sim_use_3_dim = true;

        ImGui.SameLine;
        ImGui.SetCursorPosX( main_win_size.x * 0.5 + 8 );
        ImGui.Text( "Simulation Type" );
        ImGui.Separator;


        //
        // Grid Resolution
        //
        if( dimensions == 0
            ? ImGui.DragInt2( "Grid Resolution", cast( int* )( vg.sim_domain.ptr ), drag_step, 4, 4096 )
            : ImGui.DragInt3( "Grid Resolution", cast( int* )( vg.sim_domain.ptr ), drag_step, 4, 4096 ))
            vg.checkComputeParams;

        if( ImGui.BeginPopupContextItem( "Sim Domain Context Menu" )) {
            import core.stdc.stdio : sprintf;
            char[24]    label;
            char[3]     dir = [ 'X', 'Y', 'Z' ];
            float       click_range = 0.5 / ( 2 + dimensions );
            float       mouse_pos_x = ImGui.GetMousePosOnOpeningCurrentPopup.x;

            foreach( j; 0 .. 2 + dimensions ) {
                if(( j * click_range * main_win_size.x < mouse_pos_x ) && ( mouse_pos_x < ( j + 1 ) * click_range * main_win_size.x )) {
                    uint dim = 8;
                    sprintf( label.ptr, "Resolution %c", dir[j] );
                    ImGui.Text( label.ptr );
                    ImGui.Separator;
                    foreach( i; 0 .. 12 ) {
                        sprintf( label.ptr, "Size %c: %d", dir[j], dim );
                        if( ImGui.Selectable( label.ptr )) {
                            vg.sim_domain[j] = dim;
                            vg.checkComputeParams;
                        }
                        dim *= 2;
                    }

                    if( dimensions == 0 ) {
                        ImGui.Separator;
                        sprintf( label.ptr, "Window Res %c",     dir[j] ); if( ImGui.Selectable( label.ptr )) { vg.sim_domain[j] = ( j == 0 ? vg.vd.windowWidth : vg.vd.windowHeight );     vg.checkComputeParams; }
                        sprintf( label.ptr, "Window Res %c / 2", dir[j] ); if( ImGui.Selectable( label.ptr )) { vg.sim_domain[j] = ( j == 0 ? vg.vd.windowWidth : vg.vd.windowHeight ) / 2; vg.checkComputeParams; }
                        sprintf( label.ptr, "Window Res %c / 4", dir[j] ); if( ImGui.Selectable( label.ptr )) { vg.sim_domain[j] = ( j == 0 ? vg.vd.windowWidth : vg.vd.windowHeight ) / 4; vg.checkComputeParams; }
                        sprintf( label.ptr, "Window Res %c / 8", dir[j] ); if( ImGui.Selectable( label.ptr )) { vg.sim_domain[j] = ( j == 0 ? vg.vd.windowWidth : vg.vd.windowHeight ) / 8; vg.checkComputeParams; }
                    }
                }
            }

            if( 0.5 * main_win_size.x < mouse_pos_x ) {
                uint dim = 8;
                ImGui.Text( dimensions == 0 ? "Resolution XY" : "Resolution XYZ" );
                ImGui.Separator;
                const( char* )[2] vol = [ "XY", "XYZ" ];
                foreach( i; 0 .. 12 ) {
                    sprintf( label.ptr, "Size %s: %d ^ %d", vol[ dimensions ], dim, 2 + dimensions );
                    if( ImGui.Selectable( label.ptr )) {
                        vg.sim_domain[ 0 .. 2 + dimensions ] = dim;
                        vg.checkComputeParams;
                    } dim *= 2;
                }

                if( dimensions == 0 ) {
                    ImGui.Separator;
                    if( ImGui.Selectable( "Window Res"     )) { vg.sim_domain[0] = vg.vd.windowWidth;     vg.sim_domain[1] = vg.vd.windowHeight;     vg.checkComputeParams; }
                    if( ImGui.Selectable( "Window Res / 2" )) { vg.sim_domain[0] = vg.vd.windowWidth / 2; vg.sim_domain[1] = vg.vd.windowHeight / 2; vg.checkComputeParams; }
                    if( ImGui.Selectable( "Window Res / 4" )) { vg.sim_domain[0] = vg.vd.windowWidth / 4; vg.sim_domain[1] = vg.vd.windowHeight / 4; vg.checkComputeParams; }
                    if( ImGui.Selectable( "Window Res / 8" )) { vg.sim_domain[0] = vg.vd.windowWidth / 8; vg.sim_domain[1] = vg.vd.windowHeight / 8; vg.checkComputeParams; }
                }
            } ImGui.EndPopup();
        }


        //
        // Values per Cell and their precision
        //
        ImGui.PushItemWidth( 86 );
        if( ImGui.DragInt( "##Values per Cell", cast( int* )( & vg.sim_layers ), 0.1f, 1, 1024 ))
            vg.checkComputeParams;


        // Specify precision
        int precision = vg.sim_use_double;
        ImGui.SameLine;
        if( ImGui.Combo( "Per Cell Values", & precision, vg.feature_shader_double || vg.sim_use_cpu ? "Float\0Double\0\0" : "Float\0\0" )) {
            vg.sim_use_double = precision > 0;
            vg.checkComputeParams;
        }

        // inform if double precision is not available or CPU mode is deactivated
        if( !( vg.feature_shader_double || vg.sim_use_cpu ))
            showTooltip( "Shader double precision is not available on the selected device." );

        ImGui.PopItemWidth;


        // Apply button for all the settings within Compute Parameter
        // If more then work group size has changed rebuild sim_buffer
        // If the simulation dimensions has not changed we do not need to rebuild sim_image
        // Update the descriptor set, rebuild compute command buffers and reset cpu data if running on cpu
        // We also update the scale of the display plane and normalization factors for the velocity lines
        // Additionally if only the work group size changes, we need to update only the compute PSO (see else if)
        if( vg.sim_compute_dirty ) {
            if( ImGui.Button( "Apply", button_size_2 )) {

                // only if the sim domain changed we must ...
                if( vg.vd.sim_domain != vg.sim_domain ) {
                    // recreate sim image, update trackball and sim_display push constant data
                    vg.vd.sim_domain = vg.sim_display.sim_domain = vg.sim_domain;
                    vg.createSimImage;
                    import input : initTrackball;
                    vg.initTrackball;
                }

                vg.sim_compute_dirty        = vg.sim_work_group_dirty = false;
                vg.vd.sim_work_group_size   = vg.sim_work_group_size;
                vg.vd.sim_step_size         = vg.sim_step_size;
                vg.vd.sim_use_double        = vg.sim_use_double;
                vg.vd.sim_layers            = vg.sim_layers;

                // this must be after sim_domain_changed edits
                vg.createSimBuffer;

                // update descriptor, at least the sim buffer has cahnged, and possibly the sim image
                vg.updateDescriptorSet;

                // recreate lattice boltzmann pipeline with possibly new shaders
                vg.createBoltzmannPSO( true, true, true );

                if( vg.sim_use_cpu ) {
                    vg.cpuReset;
                }
            }
            ImGui.SameLine;
            ImGui.Text( "Changes" );

        } else if( vg.sim_work_group_dirty ) {
            if( ImGui.Button( "Apply", button_size_2 )) {
                vg.sim_work_group_dirty     = false;
                vg.vd.sim_work_group_size   = vg.sim_work_group_size;
                vg.vd.sim_step_size         = vg.sim_step_size;
                vg.createBoltzmannPSO( true, true, false );  // rebuild init pipeline, rebuild loop pipeline, reset domain
            }
            ImGui.SameLine;
            ImGui.Text( "Changes" );

        } else if( vg.vd.sim_step_size != vg.sim_step_size ) {
            if( ImGui.Button( "Apply", button_size_2 )) {
                vg.vd.sim_step_size = vg.sim_step_size;
                vg.createBoltzmannPSO( false, true, false );  // rebuild init pipeline, rebuild loop pipeline, reset domain
            }
            ImGui.SameLine;
            ImGui.Text( "Changes" );

        } else {
            pushButtonStyleDisable;
            ImGui.Button( "No", button_size_2 );
            ImGui.SameLine;
            ImGui.Text( "Changes" );
            popButtonStyleDisable;
        }


        //
        // Work Group Size
        //
        if( ImGui.DragInt( "Work Group Size X", cast( int* )( & vg.sim_work_group_size[0] ), drag_step, 1, 1024 )) vg.checkComputePSO;

        if( ImGui.BeginPopupContextItem( "Work Group Size Context Menu" )) {
            ImGui.Text( "Group Size X" );
            ImGui.Separator;

            char[24] label;
            uint dim = 2;
            import core.stdc.stdio;
            foreach( i; 0 .. 10 ) {
                sprintf( label.ptr, "Size X: %d", dim );
                if( ImGui.Selectable( label.ptr )) {
                    vg.sim_work_group_size[0] = dim;
                    vg.checkComputePSO;
                } dim *= 2;
            } dim = 2;
            if( ImGui.Selectable( "Resolution X" )) { vg.sim_work_group_size[0] = vg.sim_domain[0]; vg.checkComputePSO; }
            foreach( i; 0 .. 8 ) {
                sprintf( label.ptr, "Resolution X / %d", dim );
                if( ImGui.Selectable( label.ptr  )) { vg.sim_work_group_size[0] = vg.sim_domain[0] / dim; vg.checkComputePSO; }
                dim *= 2;
            } ImGui.EndPopup();
        }


        //
        // Store Every Nth Step
        //
        int step_size = cast( int )vg.sim_step_size;
        if( ImGui.DragInt( "Store Every Nth Step", & step_size, 0.1, 1, int.max )) {
            vg.sim_step_size = step_size < 1 ? 1 : step_size;
        }

        ImGui.DragInt( "Compute Index", cast( int* )( & vg.compute_ubo.comp_index ), 0.1, 1, int.max );

        /*
        //////////////////////////////////////////////////////////////////////////////////////////////
        // Work Group Size alternative version when we can use multi dim work group sizes in shader //
        //////////////////////////////////////////////////////////////////////////////////////////////
        if( dimensions == 0
            ? ImGui.DragInt2( "Work Group Size", cast( int* )( & vg.sim_work_group_size[0] ), drag_step, 1, 1024 )
            : ImGui.DragInt3( "Work Group Size", cast( int* )( & vg.sim_work_group_size[0] ), drag_step, 1, 1024 ))
            vg.checkComputeParams;


        if( ImGui.BeginPopupContextItem( "Work Group Size Context Menu" )) {
            import core.stdc.stdio : sprintf;
            char[24]    label;
            char[3]     dir = [ 'X', 'Y', 'Z' ];
            float       click_range = 0.5 / ( 2 + dimensions );
            float       mouse_pos_x = ImGui.GetMousePosOnOpeningCurrentPopup.x;

            foreach( j; 0 .. 2 + dimensions ) {
                if(( j * click_range * main_win_size.x < mouse_pos_x ) && ( mouse_pos_x < ( j + 1 ) * click_range * main_win_size.x )) {
                    uint dim = 1;
                    sprintf( label.ptr, "Group Size %c", dir[j] );
                    ImGui.Text( label.ptr  );
                    ImGui.Separator;
                    foreach( i; 0 .. 11 ) {
                        sprintf( label.ptr, "Size %c: %d##1", dir[j], dim );
                        if( ImGui.Selectable( label.ptr )) {
                            vg.sim_work_group_size[j] = dim;
                            vg.checkComputePSO;
                        } dim *= 2;
                    } ImGui.Separator;

                    sprintf( label.ptr, "Grid Res %c", dir[j] );
                    if( ImGui.Selectable( label.ptr )) {
                        vg.sim_work_group_size[j] = vg.sim_domain[j];
                        vg.checkComputePSO;
                    }

                    dim = 1;
                    foreach( i; 0 .. 8 ) {
                        sprintf( label.ptr, "Grid Res %c / %d", dir[j], dim );
                        if( ImGui.Selectable( label.ptr  )) {
                            vg.sim_work_group_size[j] = vg.sim_domain[j] / dim;
                            vg.checkComputePSO;
                        } dim *= 2;
                    }
                }
            }

            if( 0.5 * main_win_size.x < mouse_pos_x ) {
                uint dim = 4 - 2 * dimensions;
                ImGui.Text( dimensions == 0 ? "Group Size XY" : "Group Size XYZ" );
                ImGui.Separator;
                const( char* )[2] vol = [ "XY", "XYZ" ];
                foreach( i; 0 .. 4 ) {
                    sprintf( label.ptr, "Size %s: %d ^ %d##1", vol[ dimensions ], dim, 2 + dimensions );
                    if( ImGui.Selectable( label.ptr )) {
                        vg.sim_work_group_size[ 0 .. 2 + dimensions ] = dim;
                        vg.checkComputePSO; }
                    dim *= 2;
                } ImGui.Separator;

                sprintf( label.ptr, "Grid Res %s", vol[ dimensions ] );
                if( ImGui.Selectable( label.ptr )) {
                    vg.sim_work_group_size[ 0 .. 2 + dimensions ] = vg.sim_domain[ 0 .. 2 + dimensions ];
                    vg.checkComputePSO;
                }

                dim = 2;
                foreach( i; 0 .. 8 ) {
                    sprintf( label.ptr, "Grid Res %s / %d", vol[ dimensions ], dim, 2 + dimensions, dim );
                    if( ImGui.Selectable( label.ptr  )) {
                        vg.sim_work_group_size[ 0 .. 2 + dimensions ] = vg.sim_domain[ 0 .. 2 + dimensions ] / dim;
                        vg.checkComputePSO;
                    } dim *= 2;
                }
            } ImGui.EndPopup();
        }
        */

        collapsingTerminator;
    }



    ///////////////////////////
    // Simulation Parameters //
    ///////////////////////////

    if( ImGui.CollapsingHeader( "Simulation Parameter" )) {
        // preset settings context menu
        if( ImGui.BeginPopupContextItem( "Simulation Parameter Context Menu" )) {
            if( ImGui.Selectable( "Unit Parameter" )) {
                vg.sim_wall_velocity = 0.1; vg.updateWallVelocity;
                vg.compute_ubo.collision_frequency = vg.sim_relaxation_rate = 1; vg.updateViscosity;
            }
            if( ImGui.Selectable( "Looow Viscosity" )) {
                vg.sim_wall_velocity = 0.001; vg.updateWallVelocity;
                vg.compute_ubo.collision_frequency = 2;
                vg.sim_relaxation_rate = 0.5001;
                vg.updateViscosity;
                if( vg.sim_algorithm != 4 ) {
                    vg.sim_algorithm  = 4;
                    vg.createBoltzmannPSO( false, true, false );
                }
            }
            if( ImGui.Selectable( "Crazy Cascades" )) {
                vg.sim_wall_velocity = 0.5; vg.updateWallVelocity;
                vg.compute_ubo.collision_frequency = 0.8;
                vg.sim_relaxation_rate = 1.25;
                vg.updateViscosity;
                if( vg.sim_algorithm != 4 ) {
                    vg.sim_algorithm  = 4;
                    vg.createBoltzmannPSO( false, true, false );
                }
                // set resolution to 1024 * 1024

            } ImGui.EndPopup();
        }

        ImGui.Separator;

        // Relaxation Rate Tau
        if( ImGui.DragFloat( "Relaxation Rate Tau",& vg.sim_relaxation_rate, 0.001f, 0.5f, 2.0f, "%.4f" )) {
            vg.compute_ubo.collision_frequency = 1 / vg.sim_relaxation_rate;
            vg.updateViscosity;
            vg.updateComputeUBO;
        }

        // wall velocity
        if( ImGui.DragFloat( "Wall Velocity", & vg.sim_wall_velocity, 0.001f )) {
            vg.updateWallVelocity;
            vg.updateComputeUBO;
        }

        // collision algorithm
        if( ImGui.Combo( "Collision Algorithm", cast( int* )( & vg.sim_algorithm ), "SRT-LBGK\0TRT\0MRT\0Cascaded\0Cascaded Drag\0\0" )) {
            vg.createBoltzmannPSO( false, true, false );
        }

        ImGui.Separator;


        //
        // simulation details tree node
        //
        if( ImGui.TreeNode( "Simulation Details" )) {
            ImGui.Separator;

            // set width of items and their label - aligned visually with 8 pixels
            ImGui.PushItemWidth( ImGui.GetContentRegionAvailWidth - main_win_size.x / 2 + 8 );

            // spatial and temporal unit
            if( ImGui.DragFloat2( "Spatial/Temporal Unit", & vg.sim_unit_spatial, 0.001f )) {  // next value in struct is vg.sim_unit_temporal
                vg.sim_speed_of_sound = vg.sim_unit_speed_of_sound * vg.sim_unit_spatial / vg.sim_unit_temporal;
                vg.updateTauOmega;
            }

            // kinematic viscosity
            if( ImGui.DragFloat( "Kinematic Viscosity", & vg.sim_viscosity, 0.001f, 0.0f, 1000.0f, "%.9f", 2.0f )) {
                vg.updateTauOmega;
            }

            // Collision Frequency Omega
            if( ImGui.DragFloat( "Collision Frequency", & vg.compute_ubo.collision_frequency, 0.001f, 0, 2 )) {
                vg.sim_relaxation_rate = 1 / vg.compute_ubo.collision_frequency;
                vg.updateViscosity;
                vg.updateComputeUBO;
            }
            ImGui.PopItemWidth;
            ImGui.TreePop;
        }

        collapsingTerminator;

        //
        // Reynolds number tree node
        //
        if( ImGui.TreeNode( "Reynolds Number" )) {
            ImGui.Separator;

            // set width of items and their label - aligned visually with 8 pixels
            ImGui.PushItemWidth( ImGui.GetContentRegionAvailWidth - main_win_size.x / 2 + 8 );

            static float typical_vel = 0.1;
            ImGui.DragFloat( "Typical Velocity U", & typical_vel, 0.001f );
            if( ImGui.BeginPopupContextItem( "Typical Velocity Context Menu" )) {
                if( ImGui.Selectable( "Wall Velocity" )) { typical_vel = vg.sim_wall_velocity; }
                ImGui.EndPopup();
            }

            ImGui.DragFloat( "Typical Length L", & vg.sim_typical_length, 0.001f );

            auto next_win_size = ImVec2( 200, 60 ); ImGui.SetNextWindowSize( next_win_size );
            if( ImGui.BeginPopupContextItem( "Typical Length Context Menu" )) {

                if( ImGui.Selectable( "Spatial Lattice Unit" )) { vg.sim_typical_length = vg.sim_unit_spatial; }
                ImGui.Separator;

                ImGui.Columns( 2, "Typical Length Context Columns", true );

                if( ImGui.Selectable( "Lattice X" )) { vg.sim_typical_length = vg.sim_domain[0]; }
                ImGui.NextColumn();
                if( ImGui.Selectable( "Lattice Y" )) { vg.sim_typical_length = vg.sim_domain[1]; }
                ImGui.NextColumn();

                if( ImGui.Selectable( "Domain X"  )) { vg.sim_typical_length = vg.sim_domain[0] * vg.sim_unit_spatial; }
                ImGui.NextColumn();
                if( ImGui.Selectable( "Domain Y"  )) { vg.sim_typical_length = vg.sim_domain[1] * vg.sim_unit_spatial; }
                ImGui.NextColumn();

                ImGui.EndPopup;
            }

            float re = typical_vel * vg.sim_typical_length / vg.sim_viscosity;
            if( ImGui.DragFloat( "Re", & re, 0.001f )) {
                vg.sim_viscosity = typical_vel * vg.sim_typical_length / re;
                vg.updateTauOmega;
            }

            ImGui.PopItemWidth;
            ImGui.TreePop;
        }

        collapsingTerminator;
    }



    ////////////////////////
    // Display Parameters //
    ////////////////////////

    if( ImGui.CollapsingHeader( "Display Parameter" )) {
        ImGui.Separator;
        // specify display parameter
        if( ImGui.Combo(
            "Display Property", cast( int* )( & vg.display_ubo.display_property ),
            "Density\0Velocity X\0Velocity Y\0Velocity Magnitude\0Velocity Gradient\0Velocity Curl\0\0"
        ))  vg.updateDisplayUBO;

        if( ImGui.BeginPopupContextItem( "Display Property Context Menu" )) {
            if( ImGui.Selectable( "Parse Display Shader" )) {
                vg.createGraphicsPSO;
                vg.createLinePSO;
            } ImGui.EndPopup();
        }

        if( ImGui.DragFloat( "Amp Display Property", & vg.display_ubo.amplify_property, 0.001f, 0, 255 )) vg.updateDisplayUBO;

        if( ImGui.BeginPopupContextItem( "Amp Display Property Context Menu" )) {
            if( ImGui.Selectable( "1" ))    { vg.display_ubo.amplify_property = 1;      vg.updateDisplayUBO; }
            if( ImGui.Selectable( "10" ))   { vg.display_ubo.amplify_property = 10;     vg.updateDisplayUBO; }
            if( ImGui.Selectable( "100" ))  { vg.display_ubo.amplify_property = 100;    vg.updateDisplayUBO; }
            if( ImGui.Selectable( "1000" )) { vg.display_ubo.amplify_property = 1000;   vg.updateDisplayUBO; }
            ImGui.EndPopup();
        }

        if( ImGui.DragInt( "Color Layers", cast( int* )( & vg.display_ubo.color_layers ), 0.1f, 0, 255 )) vg.updateDisplayUBO;

        static int z_layer = 0;
        if( vg.sim_use_3_dim ) {
            if( ImGui.DragInt( "Z-Layer", & z_layer, 0.1f, 0, vg.sim_domain[2] - 1 )) {
                z_layer = 0 > z_layer ? 0 : z_layer >= vg.sim_domain[2] ? vg.sim_domain[2] - 1 : z_layer;
                vg.display_ubo.z_layer = z_layer;
                vg.updateDisplayUBO;
            }
        }

        ImGui.Separator;

        // Todo(pp): currently the lines are not drawn when the UI is turned off
        // -> move / copy line settings into VDrive_State and include in createResizedCommands


        //
        // velocity lines tree node
        //
        if( ImGui.TreeNode( "Velocity Lines" )) {
            ImGui.Separator;

            // set width of items and their label - aligned visually with 8 pixels
            ImGui.PushItemWidth( ImGui.GetContentRegionAvailWidth - main_win_size.x / 2 + 8 );

            int line_count = vg.sim_display.repl_count;
            if( ImGui.DragInt( "Velocity Line Count", & vg.sim_display.repl_count, 0.1, 0, int.max ))
                vg.sim_display.repl_count = vg.sim_display.repl_count < 0 ? 0 : vg.sim_display.repl_count;

            ImGui.DragFloat2( "Line Offset/Spread", & vg.sim_display.line_offset, 1.0f );  // next value in struct is repl_spread

            ImGui.BeginGroup(); // Want to use popup on the following three items
            {
                const( char )* axis_label = "X\0Y\0Z\0\0";
                int axis = cast( int )vg.sim_display.velocity_axis;
                if( ImGui.Combo( "Velocity Direction", & axis, axis_label ))
                    vg.sim_display.velocity_axis = cast( vg.Line_Axis )axis;

                axis = cast( int )vg.sim_display.repl_axis;
                if( ImGui.Combo( "Replication Direction", & axis, axis_label ))
                    vg.sim_display.repl_axis = cast( vg.Line_Axis )axis;

                axis = cast( int )vg.sim_display.line_axis;
                if( ImGui.Combo( "Line Direction", & axis, axis_label ))
                    vg.sim_display.line_axis = cast( vg.Line_Axis )axis;
            }
            ImGui.EndGroup();

            // line axis setup shortcut for U- and V-Velocities
            if( ImGui.BeginPopupContextItem( "Velocity Lines Context Menu" )) {
                if( ImGui.Selectable( "U-Velocity" )) {
                    vg.sim_display.line_axis       = vg.Line_Axis.Y;
                    vg.sim_display.repl_axis       = vg.Line_Axis.X;
                    vg.sim_display.velocity_axis   = vg.Line_Axis.X;
                }

                if( ImGui.Selectable( "V-Velocity" )) {
                    vg.sim_display.line_axis       = vg.Line_Axis.X;
                    vg.sim_display.repl_axis       = vg.Line_Axis.Y;
                    vg.sim_display.velocity_axis   = vg.Line_Axis.Y;
                }

                ImGui.EndPopup();
            }

            ImGui.SetCursorPosX( 160 );
            ImGui.Checkbox( "Draw Base Lines", & vg.sim_draw_vel_base );

            ImGui.SetCursorPosX( 160 );
            ImGui.Checkbox( "Draw as Points", & vg.draw_velocity_lines_as_points );

            ImGui.PopItemWidth;
            ImGui.TreePop;
        }

        collapsingTerminator;


        //
        // particles tree node
        //
        if( ImGui.TreeNode( "Particles" )) {

            // set width of items and their label - aligned visually with 8 pixels
            ImGui.PushItemWidth( ImGui.GetContentRegionAvailWidth - main_win_size.x / 2 + 8 );


            ImGui.PopItemWidth;
            ImGui.TreePop;
        }

        collapsingTerminator;


        //
        // scene objects tree node
        //
        if( ImGui.TreeNode( "Scene Objects" )) {
            ImGui.Separator;

            // set width of items and their label - aligned visually with 8 pixels
            ImGui.PushItemWidth( ImGui.GetContentRegionAvailWidth - main_win_size.x / 2 + 8 );
            ImGui.SetCursorPosX( 160 );
            ImGui.Checkbox( "Draw Axis", & vg.sim_draw_axis );
            ImGui.SetCursorPosX( 160 );
            ImGui.Checkbox( "Draw Grid", & vg.sim_draw_grid );
            ImGui.SetCursorPosX( 160 );
            ImGui.Checkbox( "Draw Scale", & vg.sim_draw_scale );

            ImGui.PopItemWidth;
            ImGui.TreePop;
        }

        collapsingTerminator;
    }



    /////////////////////////
    // Validate Simulation //
    /////////////////////////

    if( ImGui.CollapsingHeader( "Validate Simulation" )) {
        ImGui.Separator;

        ImGui.SetCursorPosX( 160 );
        ImGui.Checkbox( "Draw as Points", & vg.draw_velocity_lines_as_points );

        if( vg.draw_velocity_lines_as_points )
            ImGui.DragFloat2( "Point Size##1", vg.point_size_line_width.ptr, 0.125f, 0.25f );
        else
            ImGui.DragFloat2( "Line Width##1", vg.point_size_line_width.ptr, 0.125f, 0.25f );

        collapsingTerminator;

        //
        // Ghia tree node
        //
        if( ImGui.TreeNode( "Ghia et. all - Lid Driven Cavity" )) {
            ImGui.Separator;

            // set width of items and their label - aligned visually with 8 pixels
            ImGui.PushItemWidth( ImGui.GetContentRegionAvailWidth - main_win_size.x / 2 + 8 );

            int axis = cast( int )( vg.sim_display.velocity_axis ) % 2;

            ImGui.SetCursorPosX( 160 );

            // setup parameter for profiling, sim_domain must be set manually
            ImGui.SetCursorPosX( 160 );
            if( ImGui.Checkbox( "Draw Ghia Profile", & vg.sim_validate_ghia )) {
                if( vg.sim_validate_ghia ) {
                    vg.sim_wall_velocity = 0.1;
                    vg.updateWallVelocity;
                }
            }

            ImGui.SetCursorPosX( 160 );
            ImGui.Checkbox( "Draw Velocity Profile", & vg.sim_validate_velocity );

            ImGui.SetCursorPosX( 160 );
            ImGui.Checkbox( "Draw Velocity Base", & vg.sim_validate_vel_base );

            if( ImGui.Combo( "Re Number", cast( int* )( & vg.sim_ghia_type ), "   100\0   400\0  1000\0  3200\0  5000\0  7500\0 10000\0\0" )) {
                immutable float[7] re = [ 100, 400, 1000, 3200, 5000, 7500, 10000 ];
                vg.sim_viscosity = 0.1 * vg.sim_typical_length / re[ vg.sim_ghia_type ];  // typical_vel * vg.sim_typical_length
                vg.updateTauOmega;
            }

            ImGui.PopItemWidth;
            ImGui.TreePop;
        }

        collapsingTerminator;


        //
        // poiseuille tree node
        //
        if( ImGui.TreeNode( "Poiseuille Flow" )) {
            ImGui.Separator;

            // set width of items and their label - aligned visually with 8 pixels
            ImGui.PushItemWidth( ImGui.GetContentRegionAvailWidth - main_win_size.x / 2 + 8 );

            ImGui.SetCursorPosX( 160 );
            ImGui.Checkbox( "Draw Profile##1", & vg.sim_validate_poiseuille_flow );


            ImGui.PopItemWidth;
            ImGui.TreePop;
        }

        collapsingTerminator;


        //
        // taylor-green tree node
        //
        if( ImGui.TreeNode( "Taylor Green" )) {
            ImGui.Separator;

            // set width of items and their label - aligned visually with 8 pixels
            ImGui.PushItemWidth( ImGui.GetContentRegionAvailWidth - main_win_size.x / 2 + 8 );

            ImGui.SetCursorPosX( 160 );
            ImGui.Checkbox( "Draw Profile##2", & vg.sim_validate_taylor_green );


            ImGui.PopItemWidth;
            ImGui.TreePop;
        }


        collapsingTerminator;

    }



    ////////////////////////
    // Profile Simulation //
    ////////////////////////

    if( ImGui.CollapsingHeader( "Profile Simulation" )) {
        ImGui.Separator;

        //static int checkbox_offset = 160;
        //ImGui.DragInt( "Checkbox Offset", & checkbox_offset );
        ImGui.SetCursorPosX( 160 );

        if( ImGui.Checkbox( "Enable Profiling", & vg.sim_profile_mode )) {

            vg.simPause;    // currently sim is crashing we don't enter pause mode

            if( vg.sim_profile_mode ) {
                transport = play_mode = Transport.profile;
                vg.drawCmdBufferCount = vg.sim_play_cmd_buffer_count = 1;
            } else {
                transport = play_mode = Transport.play;
                if( !vg.sim_use_cpu ) {
                    vg.drawCmdBufferCount = vg.sim_play_cmd_buffer_count = 2;
                }
            }
        }


        ImGui.DragInt( "Profile Step Count", cast( int* )( & vg.sim_profile_step_count ));

        int sim_index = cast( int )vg.compute_ubo.comp_index;
        //ImGui.PushStyleColor( ImGuiCol_Text, disabled_text );
        ImGui.DragInt( "Profile Step Index", & sim_index );
        //ImGui.DragInt( "Duration", & duration );
        //ImGui.DragFloat( "Average Per Step", & avg_per_step, 0.001f );
        //ImGui.PopStyleColor( 1 );

        import core.stdc.stdio : sprintf;
        char[24] buffer;

        long duration = vg.getStopWatch_hnsecs;
        sprintf( buffer.ptr, "%d", duration );
        ImGui.InputText( "Duration (hnsecs)", buffer.ptr, buffer.length, ImGuiInputTextFlags_ReadOnly );

        double avg_per_step = duration / cast( double )sim_index;
        sprintf( buffer.ptr, "%f", avg_per_step );
        ImGui.InputText( "Avg. / Step (hnsecs)", buffer.ptr, buffer.length, ImGuiInputTextFlags_ReadOnly );

        ulong  node_count = vg.vd.sim_domain[0] * vg.vd.sim_domain[1] * vg.vd.sim_domain[2];
        double mlups = 10.0 * node_count * sim_index / duration;
        sprintf( buffer.ptr, "%f", mlups );
        ImGui.InputText( "Avg. MLups", buffer.ptr, buffer.length, ImGuiInputTextFlags_ReadOnly );

        collapsingTerminator;
    }



    ////////////////////
    // Export Ensight //
    ////////////////////

    if( ImGui.CollapsingHeader( "Export Ensight" )) {
        ImGui.Separator;

        if( vg.sim_use_cpu ) {
            ImGui.Text( "Export from CPU is not available" );
        } else {

            int sim_index = cast( int )vg.sim_index;
            ImGui.PushStyleColor( ImGuiCol_Text, disabled_text );
            ImGui.DragInt( "Simulation Index", & sim_index );
            ImGui.PopStyleColor( 1 );
            ImGui.Separator;

            ImGui.DragInt( "Start Index", & vg.ve.start_index,  0.1, 0 );
            ImGui.DragInt( "Step Count",  & vg.ve.step_count,   0.1, 1 );
            ImGui.DragInt( "Every Nth Step", & vg.ve.step_size, 0.1, 1 );
            ImGui.Separator;

            ImGui.InputText( "Case File Name", vg.ve.case_file_name.ptr, vg.ve.case_file_name.length );
            ImGui.InputText( "Var Name",  vg.ve.variable_name.ptr, 9 );
            ImGui.SameLine;
            ImGui.SetCursorPosX( 10 + ImGui.GetCursorPosX );
            ImGui.Checkbox( "is Vector", & vg.vd.export_as_vector );
            ImGui.Combo( "File Format", & cast( int )vg.ve.file_format, "Ascii\0Binary\0\0" );
            ImGui.Separator;


            ImGui.Spacing;
            ImGui.Text( "Export Shader" );

            // select export shader
            static int export_shader_index = 0;
            ImGui.PushItemWidth( ImGui.GetWindowWidth * 0.75 );
            if( ImGui.Combo( "Export", & export_shader_index, //"shader/export_from_image.comp\0\0" )
                export_shader_start_index == size_t.max
                    ? "None found!"
                    : shader_names_ptr[ export_shader_start_index ] )
                ) {
                if( export_shader_start_index != size_t.max ) {
                    auto export_shader_dirty = !compareShaderNamesAndReplace(
                        shader_names_ptr[ export_shader_start_index + export_shader_index ], vg.export_shader
                    );
                }
            }

            // update init shader list when hovering over Combo
            if( ImGui.IsItemHovered ) {
                if( hasShaderDirChanged ) {
                    parseShaderDirectory;
                    // a new shader might replace the shader at the current index
                    // when we would actually use the ImGui.Combo and select this new shader
                    // it would not be registered
                    if( export_shader_start_index != size_t.max ) {     // might all have been deleted
                        auto export_shader_dirty = !compareShaderNamesAndReplace(
                            shader_names_ptr[ export_shader_start_index + export_shader_index ], vg.export_shader
                        );
                    }
                }
            } collapsingTerminator;


            // Execute the data export
            if( ImGui.Button( "Export Data", button_size_1 )) {

                // reset simulation if we past the export step index
                if( vg.ve.start_index < vg.sim_index ) {
                    vg.simReset;
                }

                // create export related gpu data and setup export function
                // gpu export is always float
                vg.createExportResources;

                // set the play mode to play, might have been set to profile before, and start the sim
                play_mode = Transport.play;
                transport = Transport.play;

            }
        } collapsingTerminator;
    }

    ImGui.End();



    // 2. Show another simple window, this time using an explicit Begin/End pair
    if( show_another_window ) {
        auto next_win_size = ImVec2( 200, 100 ); ImGui.SetNextWindowSize( next_win_size, ImGuiCond_FirstUseEver );
        ImGui.Begin( "Another Window", &show_another_window );
        ImGui.Text( "Hello" );
        ImGui.End();
    }

    // 3. Show the ImGui test window. Most of the sample code is in ImGui.ShowTestWindow()
    if( show_test_window ) {
        auto next_win_pos = ImVec2( 650, 20 ); ImGui.SetNextWindowPos( next_win_pos, ImGuiCond_FirstUseEver );
        ImGui.ShowTestWindow( &show_test_window );
    }

    if( show_style_editor ) {
        ImGui.Begin( "Style Editor", &show_style_editor );
        ImGui.ShowStyleEditor();
        ImGui.End();
    }


    ImGui.Render;
}





/////////////////////////////////////////////////////////////
// Callback for C++ ImGui lib, in particular draw function //
/////////////////////////////////////////////////////////////

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



    //
    // begin command buffer recording
    //

    // first attach the swapchain image related framebuffer to the render pass
    import vdrive.renderbuffer : attachFramebuffer;
    vg.render_pass.attachFramebuffer( vg.framebuffers( vg.next_image_index ));

    // convenience copy
    auto cmd_buffer = vg.cmd_buffers[ vg.next_image_index ];

    // begin the command buffer
    cmd_buffer.vkBeginCommandBuffer( &vg.gui_cmd_buffer_bi );





    // Copy CPU buffer data to the gpu image
    if( vg.vd.sim_use_cpu && ( *vg ).isPlaying ) {

        // record image layout transition to VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
        cmd_buffer.recordTransition(
            vg.sim_image.image,
            vg.sim_image.subresourceRange,
            VK_IMAGE_LAYOUT_GENERAL,
            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            VK_ACCESS_SHADER_READ_BIT,
            VK_ACCESS_TRANSFER_WRITE_BIT,
            VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            VK_PIPELINE_STAGE_TRANSFER_BIT,
        );

        // record a buffer to image copy
        auto subresource_range = vg.sim_image.subresourceRange;
        VkBufferImageCopy buffer_image_copy = {
            imageSubresource: {
                aspectMask      : subresource_range.aspectMask,
                baseArrayLayer  : 0,
                layerCount      : 1 },
            imageExtent     : vg.sim_image.extent,
        };
        cmd_buffer.vkCmdCopyBufferToImage( vg.sim_stage_buffer.buffer, vg.sim_image.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &buffer_image_copy );

        // record image layout transition to VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
        cmd_buffer.recordTransition(
            vg.sim_image.image,
            vg.sim_image.subresourceRange,
            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            VK_IMAGE_LAYOUT_GENERAL,
            VK_ACCESS_TRANSFER_WRITE_BIT,
            VK_ACCESS_SHADER_READ_BIT,
            VK_PIPELINE_STAGE_TRANSFER_BIT,
            VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT
        );
    }






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

    // begin the render pass
    cmd_buffer.vkCmdBeginRenderPass( &vg.render_pass.begin_info, VK_SUBPASS_CONTENTS_INLINE );




    //
    // bind lbmd graphics pso
    //
    cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_GRAPHICS, vg.graphics_pso.pipeline );

    // push constant the sim display scale
    float[4] sim_domain = [ vg.vd.sim_domain[0], vg.vd.sim_domain[1], vg.recip_window_size[0], vg.recip_window_size[1] ];
    cmd_buffer.vkCmdPushConstants( vg.graphics_pso.pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, 4 * float.sizeof, sim_domain.ptr ); //sim_display.scale.ptr );

    // buffer-less draw with build in gl_VertexIndex exclusively to generate position and tex_coord data
    cmd_buffer.vkCmdDraw( 4, 1 + vg.sim_draw_scale, 0, 0 ); // vertex count, instance count, first vertex, first instance



    //
    // bind lines pipeline
    //
    if( vg.sim_draw_lines )
        cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_GRAPHICS, vg.draw_line_pso[ 0 ].pipeline );


    //
    // set push constants and record draw commands for axis drawing
    //
    if( vg.sim_draw_axis ) {
        vg.sim_display.line_type = vg.Line_Type.axis;
        cmd_buffer.vkCmdPushConstants( vg.draw_line_pso[ 0 ].pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, vg.sim_display.line_type.offsetof, uint32_t.sizeof, & vg.sim_display.line_type );
        cmd_buffer.vkCmdDraw( 2, 3, 0, 0 ); // vertex count, instance count, first vertex, first instance
    }

    //
    // set push constants and record draw commands for grid drawing
    //
    if( vg.sim_draw_grid ) {
        vg.sim_display.line_type = vg.Line_Type.grid;

        // draw lines repeating in X direction
        vg.sim_display.line_axis = vg.Line_Axis.X;
        cmd_buffer.vkCmdPushConstants( vg.draw_line_pso[ 0 ].pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, 4 * uint32_t.sizeof, & vg.sim_display );
        cmd_buffer.vkCmdDraw( 2, vg.sim_domain[0] + 1, 0, 0 ); // vertex count, instance count, first vertex, first instance

        // draw lines repeating in Y direction
        vg.sim_display.line_axis = vg.Line_Axis.Y;
        cmd_buffer.vkCmdPushConstants( vg.draw_line_pso[ 0 ].pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, vg.sim_display.line_type.offsetof, uint32_t.sizeof, & vg.sim_display.line_type );
        cmd_buffer.vkCmdDraw( 2, vg.sim_domain[1] + 1, 0, 0 ); // vertex count, instance count, first vertex, first instance
    }

    void setPointSizeLineWidth( size_t index ) {
        if( vg.draw_velocity_lines_as_points ) {
            if( vg.vd.feature_large_points ) {
                vg.sim_display.point_size = vg.point_size_line_width[ index ];
            }
        } else {
            if( vg.vd.feature_wide_lines ) {
                cmd_buffer.vkCmdSetLineWidth( vg.point_size_line_width[ index ] );
            }
        }
    }


    //
    // draw ghia validation profiles
    //
    if( vg.sim_validate_ghia ) {

        // setup pipeline, either lines or points drawing
        uint draw_as_points = vg.draw_velocity_lines_as_points ? 1 : 0;
        cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_GRAPHICS, vg.draw_line_pso[ draw_as_points ].pipeline );
        auto pipeline_layout = vg.draw_line_pso[ draw_as_points ].pipeline_layout;


        //
        // store UI Values
        //
        int          repl_count     = vg.sim_display.repl_count;
        vg.Line_Axis line_axis      = vg.sim_display.line_axis;
        vg.Line_Axis repl_axis      = vg.sim_display.repl_axis;
        vg.Line_Axis velocity_axis  = vg.sim_display.velocity_axis;
        float        line_offset    = vg.sim_display.line_offset;


        //
        // vertical lines
        //
        vg.sim_display.repl_count = cast( int )vg.sim_ghia_type;    // choose Re
        vg.sim_display.line_axis        = vg.Line_Axis.Y;
        vg.sim_display.repl_axis        = vg.Line_Axis.X;
        vg.sim_display.velocity_axis    = vg.Line_Axis.X;
        vg.sim_display.line_offset      = 63;
        setPointSizeLineWidth( 0 );

        // push constant the whole sim_display struct and draw
        vg.sim_display.line_type = vg.Line_Type.ghia;
        cmd_buffer.vkCmdPushConstants( pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, vg.Sim_Display.sizeof, & vg.sim_display );
        cmd_buffer.vkCmdDraw( 17, 1, 0, 0 ); // vertex count, instance count, first vertex, first instance

        if( vg.sim_validate_velocity ) {
            // adjust push constants and draw velocity line
            setPointSizeLineWidth( 1 );
            vg.sim_display.line_type = vg.Line_Type.velocity;
            cmd_buffer.vkCmdPushConstants( pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, vg.Sim_Display.sizeof, & vg.sim_display );
            cmd_buffer.vkCmdDraw( vg.vd.sim_domain[ vg.sim_display.line_axis ], 1, 0, 0 ); // vertex count, instance count, first vertex, first instance
        }

        if( vg.sim_validate_vel_base ) {
            setPointSizeLineWidth( 2 );
            // adjust push constants and draw velocity line
            vg.sim_display.line_type = vg.Line_Type.vel_base;
            cmd_buffer.vkCmdPushConstants( pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, vg.Sim_Display.sizeof, & vg.sim_display );
            cmd_buffer.vkCmdDraw( vg.vd.sim_domain[ vg.sim_display.line_axis ], 1, 0, 0 ); // vertex count, instance count, first vertex, first instance
        }


        //
        // horizontal lines
        //
        vg.sim_display.line_type        = vg.Line_Type.ghia;
        vg.sim_display.velocity_axis    = vg.Line_Axis.Y;
        vg.sim_display.repl_axis        = vg.Line_Axis.Y;
        vg.sim_display.line_axis        = vg.Line_Axis.X;
        setPointSizeLineWidth( 0 );

        cmd_buffer.vkCmdPushConstants( pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, vg.Sim_Display.sizeof, & vg.sim_display );
        cmd_buffer.vkCmdDraw( 17, 1, 0, 0 ); // vertex count, instance count, first vertex, first instance

        if( vg.sim_validate_velocity ) {
            // adjust push constants and draw velocity line
            setPointSizeLineWidth( 1 );
            vg.sim_display.line_type = vg.Line_Type.velocity;
            cmd_buffer.vkCmdPushConstants( pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, vg.Sim_Display.sizeof, & vg.sim_display );
            cmd_buffer.vkCmdDraw( vg.vd.sim_domain[ vg.sim_display.line_axis ], 1, 0, 0 ); // vertex count, instance count, first vertex, first instance
        }

        if( vg.sim_validate_vel_base ) {
            // adjust push constants and draw velocity base line
            setPointSizeLineWidth( 2 );
            vg.sim_display.line_type = vg.Line_Type.vel_base;
            cmd_buffer.vkCmdPushConstants( pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, vg.Sim_Display.sizeof, & vg.sim_display );
            cmd_buffer.vkCmdDraw( vg.vd.sim_domain[ vg.sim_display.line_axis ], 1, 0, 0 ); // vertex count, instance count, first vertex, first instance
        }


        //
        // reconstruct UI values
        //
        vg.sim_display.repl_count       = repl_count;
        vg.sim_display.line_axis        = line_axis;
        vg.sim_display.repl_axis        = repl_axis;
        vg.sim_display.velocity_axis    = velocity_axis;
        vg.sim_display.line_offset      = line_offset;

    }

    //
    // setup velocity and base lines drawing
    //
    if( vg.sim_display.repl_count ) {

        // setup pipeline, either lines or points drawing
        uint draw_as_points = vg.draw_velocity_lines_as_points ? 1 : 0;
        cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_GRAPHICS, vg.draw_line_pso[ draw_as_points ].pipeline );
        auto pipeline_layout = vg.draw_line_pso[ draw_as_points ].pipeline_layout;

        if( vg.sim_draw_vel_base ) {
            // push constant the whole sim_display struct
            setPointSizeLineWidth( 2 );
            vg.sim_display.line_type = vg.Line_Type.vel_base;
            cmd_buffer.vkCmdPushConstants( pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, vg.sim_display.sizeof, & vg.sim_display );
            cmd_buffer.vkCmdDraw(
                vg.vd.sim_domain[ vg.sim_display.line_axis ], vg.sim_display.repl_count, 0, 0 ); // vertex count, instance count, first vertex, first instance
        }

        // push constant the whole sim_display struct and draw
        setPointSizeLineWidth( 1 );
        vg.sim_display.line_type = vg.Line_Type.velocity;
        cmd_buffer.vkCmdPushConstants( pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, vg.sim_display.sizeof, & vg.sim_display );
        cmd_buffer.vkCmdDraw(
            vg.vd.sim_domain[ vg.sim_display.line_axis ], vg.sim_display.repl_count, 0, 0 ); // vertex count, instance count, first vertex, first instance

        /*
        if( vg.sim_display.line_count[0] > 0 ) // buffer-less draw with build in gl_VertexIndex exclusively to generate position and tex_coord data
            // the X lines run from top to bottom and repeat in X direction, hence their vertex count is the Y sim_domain
            cmd_buffer.vkCmdDraw( vg.vd.sim_domain[1] + 1, vg.sim_display.line_count[0], 0, 0 ); // vertex count, instance count, first vertex, first instance

        if( vg.sim_display.line_count[1] > 0 ) {
            vg.sim_display.line_axis = 1;
            // the Y lines run from left to right and repeat in Y direction, hence their vertex count is the X sim_domain
            cmd_buffer.vkCmdPushConstants( vg.draw_line_pso[ vg.vg.Line_Type.velocity ].pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, vg.sim_display.sizeof, & vg.sim_display );
            cmd_buffer.vkCmdDraw( vg.vd.sim_domain[0] + 1, vg.sim_display.line_count[1], 0, 0 ); // vertex count, instance count, first vertex, first instance
        }
        */

    }





    VkDeviceSize vertex_offset;
    /*    // bind draw particle pipeline
    cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_GRAPHICS, vg.draw_part_pso.pipeline );
    cmd_buffer.vkCmdBindDescriptorSets(     // VkCommandBuffer              commandBuffer           // bind descriptor set
        VK_PIPELINE_BIND_POINT_COMPUTE,     // VkPipelineBindPoint          pipelineBindPoint
        vg.draw_part_pso.pipeline_layout,   // VkPipelineLayout             layout
        0,                                  // uint32_t                     firstSet
        1,                                  // uint32_t                     descriptorSetCount
        &vg.descriptor.descriptor_set,      // const( VkDescriptorSet )*    pDescriptorSets
        0,                                  // uint32_t                     dynamicOffsetCount
        null                                // const( uint32_t )*           pDynamicOffsets
    );

    cmd_buffer.vkCmdBindVertexBuffers( 0, 1, & vg.sim_particle_buffer.buffer, & vertex_offset );
    cmd_buffer.vkCmdDraw( 2 * vg.vd.sim_particle_count, 1, 0, 0 ); // vertex count, instance count, first vertex, first instance
    */



    // bind gui pipeline
    cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_GRAPHICS, vg.gui_graphics_pso.pipeline );

    // bind vertex and index buffer
    cmd_buffer.vkCmdBindVertexBuffers( 0, 1, & vg.gui_vtx_buffers[ vg.next_image_index ].buffer, & vertex_offset );
    cmd_buffer.vkCmdBindIndexBuffer( vg.gui_idx_buffers[ vg.next_image_index ].buffer, 0, VK_INDEX_TYPE_UINT16 );

    // setup scale and translation
    float[2] scale = [ 2.0f / vg.vd.windowWidth, 2.0f / vg.vd.windowHeight ];
    float[2] trans = [ -1.0f, -1.0f ];
    cmd_buffer.vkCmdPushConstants( vg.gui_graphics_pso.pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT,            0, scale.sizeof, scale.ptr );
    cmd_buffer.vkCmdPushConstants( vg.gui_graphics_pso.pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, scale.sizeof, trans.sizeof, trans.ptr );

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

    /*
    // bind comp particle pipeline
    cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_COMPUTE, vg.comp_part_pso.pipeline );
    cmd_buffer.vkCmdPushConstants( vg.comp_part_pso.pipeline_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, 2 * float.sizeof, vg.sim_display.scale.ptr );
    cmd_buffer.vkCmdDispatch( 16, 1, 1 );   // dispatch compute command
    */

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

    auto io = & ImGui.GetIO();
    if( !io.WantCaptureMouse ) {
        // forward to input.mouseButtonCallback
        import input : mouseButtonCallback;
        mouseButtonCallback( window, button, val, mod );
    }
}


void guiScrollCallback( GLFWwindow* window, double xoffset, double yoffset ) {
    g_MouseWheel += cast( float )yoffset; // Use fractional mouse wheel, 1.0 unit 5 lines.
    auto io = & ImGui.GetIO();
    if( !io.WantCaptureMouse ) {
        // forward to input.scrollCallback
        import input : scrollCallback;
        scrollCallback( window, xoffset, yoffset );
    }
}


void guiCharCallback( GLFWwindow*, uint c ) {
    auto io = & ImGui.GetIO();
    if( c > 0 && c < 0x10000 )
        io.AddInputCharacter( cast( ImWchar )c );
}


void guiKeyCallback( GLFWwindow* window, int key, int scancode, int val, int mod ) {
    auto io = & ImGui.GetIO();
    io.KeysDown[ key ] = val > 0;

    // interpret KP Enter as Ky Enter
    if( key == GLFW_KEY_KP_ENTER )
        io.KeysDown[ GLFW_KEY_ENTER ] = val > 0;

    //if( action == GLFW_PRESS )
        //io.KeysDown[ key ] = true;
    //if( action == GLFW_RELEASE )
        //io.KeysDown[ key ] = false;

    //( void )mods; // Modifiers are not reliable across systems
    io.KeyCtrl  = io.KeysDown[ GLFW_KEY_LEFT_CONTROL    ] || io.KeysDown[ GLFW_KEY_RIGHT_CONTROL    ];
    io.KeyShift = io.KeysDown[ GLFW_KEY_LEFT_SHIFT      ] || io.KeysDown[ GLFW_KEY_RIGHT_SHIFT      ];
    io.KeyAlt   = io.KeysDown[ GLFW_KEY_LEFT_ALT        ] || io.KeysDown[ GLFW_KEY_RIGHT_ALT        ];
    io.KeySuper = io.KeysDown[ GLFW_KEY_LEFT_SUPER      ] || io.KeysDown[ GLFW_KEY_RIGHT_SUPER      ];

    // return here on key up events, all functionality bellow requires key up events only
    if( val == 0 ) return;

    // forward to input.guiKeyCallback
    import input : inputKeyCallback = keyCallback;
    inputKeyCallback( window, key, scancode, val, mod );

    // if window fullscreen event happened we will not be notified, we must catch the key itself
    auto vg = cast( VDrive_Gui_State* )io.UserData; // get VDrive_Gui_State pointer from ImGuiIO.UserData

    if( key == GLFW_KEY_KP_ENTER && mod == GLFW_MOD_ALT ) {
        io.DisplaySize = ImVec2( vg.vd.windowWidth, vg.vd.windowHeight );
        main_win_size.y = vg.vd.windowHeight;       // this sets the window gui height to the window height
    } else

    // turn gui on or off with tab key
    // Todo(pp): this should work only if not in text edit mode
    switch( key ) {
        case GLFW_KEY_F1 :
        vg.draw_gui ^= 1 ;
        if( !vg.draw_gui ) {
            vg.vd.createResizedCommands;   // create draw loop runtime commands, only used without gui
        } break;

        case GLFW_KEY_F2 :
        show_imgui_examples ^= 1;
        break;

        case GLFW_KEY_F5 :
        if( isPlaying( *vg )) simPause( *vg );
        else                  simPlay(  *vg );
        break;

        case GLFW_KEY_F6 :
        simStep( *vg );
        break;

        case GLFW_KEY_F7 :
        simReset( *vg );
        break;

        case GLFW_KEY_P :
        try {
            vg.vd.createLinePSO;
        } catch( Exception ) {}
        break;

        case GLFW_KEY_D :
        try {
            vg.vd.createGraphicsPSO;
        } catch( Exception ) {}
        break;

        default : break;
    }
}

/// Callback Function for capturing window resize events
void guiWindowSizeCallback( GLFWwindow * window, int w, int h ) {
    auto io = & ImGui.GetIO();
    auto vg = cast( VDrive_Gui_State* )io.UserData; // get VDrive_Gui_State pointer from ImGuiIO.UserData
    io.DisplaySize  = ImVec2( w, h );

    //import std.stdio;
    //printf( "WindowSize: %d, %d\n", w, h );

    scale_win_pos.x = w -  50;     // set x - position of scale window
    scale_win_pos.y = h - 190;     // set y - position of scale window
    main_win_size.y = h;           // this sets the window gui height to the window height

    vg.recip_window_size[0] = 2.0f / w;
    vg.recip_window_size[1] = 2.0f / h;

    // the extent might change at swapchain creation when the specified extent is not usable
    swapchainExtent( &vg.vd, w, h );
    vg.vd.window_resized = true;
}




// Space optimized version of Sim_Display
/*
    struct Sim_Display {                // std140 conform
      align( 1 ):
        uint[3]     sim_domain;
        ubyte       line_type  = 0;
        ubyte       velocity_repl_line_axis  = 0;
        ushort      repl_count = 0;

        void velocity_axis( ubyte axis ) {
            if( axis & 1 )  velocity_repl_line_axis |=  ( 1 << 4 );
            else            velocity_repl_line_axis &= ~( 1 << 4 );
            if( axis & 2 )  velocity_repl_line_axis |=  ( 1 << 5 );
            else            velocity_repl_line_axis &= ~( 1 << 5 );
        }

        void repl_axis( ubyte axis ) {
            if( axis & 1 )  velocity_repl_line_axis |=  ( 1 << 2 );
            else            velocity_repl_line_axis &= ~( 1 << 2 );
            if( axis & 2 )  velocity_repl_line_axis |=  ( 1 << 3 );
            else            velocity_repl_line_axis &= ~( 1 << 3 );
        }

        void line_axis( ubyte axis ) {
            if( axis & 1 )  velocity_repl_line_axis |=  ( 1 << 0 );
            else            velocity_repl_line_axis &= ~( 1 << 0 );
            if( axis & 2 )  velocity_repl_line_axis |=  ( 1 << 1 );
            else            velocity_repl_line_axis &= ~( 1 << 1 );
        }

        ubyte velocity_axis()   { return ( velocity_repl_line_axis >> 4 ) & 3; }
        ubyte repl_axis()       { return ( velocity_repl_line_axis >> 2 ) & 3; }
        ubyte line_axis()       { return ( velocity_repl_line_axis >> 0 ) & 3; }
    }
*/