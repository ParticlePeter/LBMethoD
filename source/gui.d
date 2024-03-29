module gui;

import vdrive;
import erupted;

import imgui.types;
import ImGui = imgui.funcs_static;

import bindbc.glfw;

import appstate;
import cpustate;
import simulate;
import visualize;
import resources;
import exportstate;

import settings : setting;

debug import std.stdio;




//
// struct of gui related data //
//
struct Gui_State {

    alias                       app this;
    @setting VDrive_State       app;

    // presentation mode handling
    Static_Array!( char, 60 )   available_present_modes;        // 64 bytes
    VkPresentModeKHR[ 4 ]       available_present_modes_map;
    int                         selected_present_mode;

    //private:

    // GLFW data
    float       time = 0.0f;
    bool[ 3 ]   mouse_pressed = [ false, false, false ];
    float       mouse_wheel = 0.0f;

    // gui resources
    Core_Pipeline               gui_graphics_pso;
    Core_Pipeline               current_pso;        // with this we keep track which pso is active to avoid rebinding of the
    Core_Image_Memory_Sampler   gui_font_tex;

    // MAX_FRAMES is the maximum storage for these buffers and also swapchains. We should only construct swapchain count resources
    alias Gui_Draw_Buffer = Core_Buffer_Memory_T!( 0, BMC.Size | BMC.Ptr );
    Gui_Draw_Buffer[ app.MAX_FRAMES ]   gui_draw_buffers;

    // gui helper and cache sim settings
    float       sim_relaxation_rate;    // tau
    float       sim_viscosity;          // at a relaxation rate of 1 and lattice units x, t = 1
    float       sim_wall_velocity;

    enum Line_Axis : uint8_t { X, Y, Z };
    enum Line_Type : uint8_t {
        vel_curves,
        vel_base,
        axis,
        grid,
        bounds,
        ghia,
        poiseuille,
        velocity,
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

    // Sim Display Struct is used to configure the lines display ueber shader
    // it is applied as push constant the struct must be std140 conform
    struct Vis_Line_Display {
      align( 1 ):
        uint[3]     sim_domain;
        Line_Type   line_type       = Line_Type.vel_curves;
        Line_Axis   line_axis       = Line_Axis.Y;
        Line_Axis   repl_axis       = Line_Axis.X;
        Line_Axis   velocity_axis   = Line_Axis.X;
        int         repl_count      = 0;
        float       line_offset     = 0;
        float       repl_spread     = 1;
        float       point_size      = 1;
    }

    Vis_Line_Display vis_line_display;

    // reflected compute parameters for gui editing
    // they are compared with those in VDrive_State when pressing the apply button
    // if they differ PSOs and memory objects are rebuild
    alias               Sim_Layout = Sim_State.Layout;
    uint32_t[3]         sim_domain;
    Sim_Layout          sim_layout;
    uint32_t[3]         sim_work_group_size;
    uint32_t            sim_layers;
    uint32_t            sim_step_size;
    float               sim_typical_length;
    float               sim_typical_vel;
    float[2]            recip_window_size = [ 2.0f / 1600, 2.0f / 900 ];
    @setting float[3]   point_size_line_width = [ 9, 3, 1 ];

    // initial setting for Ghia et al. validation of lid driven cavity
    Ghia_Type           ghia_type           = Ghia_Type.re___100;

    // significant changes in pipeline must be aproved
    // hence we capture gui state in app_var, compare app.var
    // to enable apply button and commit changes on apply button press
    bool                sim_use_double;
    bool                sim_use_3_dim() { return sim_layout != Sim_Layout.D2Q9; }

    // helper to the system explained above
    bool                compute_dirty;
    bool                work_group_dirty;

    // flags which can be only enabled in gui mode
    @setting bool   draw_gui            = true;
    @setting bool   profile_mode        = false;
    @setting bool   draw_lines          = true;
    @setting bool   draw_vel_base       = true;
    @setting bool   draw_axis           = true;
    @setting bool   draw_grid           = false;
    @setting bool   draw_bounds         = true;
    @setting bool   draw_velocity_lines = false;
    @setting bool   lines_as_points     = false;

    @setting bool   validate_ghia;
    @setting bool   validate_poiseuille_flow;
    @setting bool   validate_taylor_green;
    @setting bool   validate_velocity   = true;
    @setting bool   validate_vel_base   = false;

    public:

    //
    // initialize imgui
    //
    void initImgui() {

        // display the gui
        draw_gui = true;

        // Get static ImGuiIO struct and set the address of our Gui_State as user pointer
        auto io = & ImGui.GetIO();
        io.UserData = & this;

        // Keyboard mapping. ImGui will use those indexes to peek into the io.KeyDown[] array
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
        io.ClipboardUserData    = window;

        // specify display size from vulkan data
        io.DisplaySize.x = windowWidth;
        io.DisplaySize.y = windowHeight;


        // define style
        auto style                      = & ImGui.GetStyle();
        //  style.Alpha                     = 1;    // Global Alpha
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
    }


    //
    // initialize vulkan
    //
    VkResult initVulkan() {

        // first initialize vulkan main handles, exit early if something goes wrong
        auto vk_result = app.initVulkan;
        if( vk_result != VK_SUCCESS )
            return vk_result;

        // now collect swapchain info and populate related gui structures
        auto present_modes = app.gpu.listPresentModes( app.swapchain.surface, false );
        uint mode_name_idx = 0;
        foreach( uint i; 0 .. 4 ) {
            foreach( mode; present_modes ) {
                if( mode == cast( VkPresentModeKHR )i ) {
                    // settings have been loaded and applied by now, so we can use the last chosen present mode
                    // to initialize the selected mapped present mode (we need a mapping as not all present modes have to exist)
                    if( mode == app.present_mode )
                        selected_present_mode = cast( int )mode_name_idx;
                    // now we setup the mapping and populate the relevant imgui combo string
                    available_present_modes_map[ mode_name_idx++ ] = mode;
                    switch( mode ) {
                        case VK_PRESENT_MODE_IMMEDIATE_KHR      : available_present_modes.append( "IMMEDIATE_KHR\0" );    break;
                        case VK_PRESENT_MODE_MAILBOX_KHR        : available_present_modes.append( "MAILBOX_KHR\0" );      break;
                        case VK_PRESENT_MODE_FIFO_KHR           : available_present_modes.append( "FIFO_KHR\0" );         break;
                        case VK_PRESENT_MODE_FIFO_RELAXED_KHR   : available_present_modes.append( "FIFO_RELAXED_KHR\0" ); break;
                        default: break;
                    }
                }
            }
        }
        available_present_modes.append( '\0' );
        return vk_result;
    }


    //
    // initial draw to configure gui after all other resources were initialized
    //
    void drawInit() {

        // first forward to appstate drawInit
        app.drawInit;

        //
        // Initialize GUI Data //
        //

        // list available devices so the user can choose one
        getAvailableDevices;

        // list available shaders for init, loop and export
        // get their directory file index for gui combo display
        // and set the initial shaders for init and loop
        parseShaderDirectory;
        init_shader_index = getShaderFileIndexFromName( sim.init_shader.ptr,   shader_names_ptr[ init_shader_start_index .. $ ] );
        loop_shader_index = getShaderFileIndexFromName( sim.loop_shader.ptr,   shader_names_ptr[ loop_shader_start_index .. $ ] );
        port_shader_index = getShaderFileIndexFromName( exp.export_shader.ptr, shader_names_ptr[ port_shader_start_index .. $ ] );
        app.createBoltzmannPSO( true, true, true );


        // initialize Gui_State member from VDrive_State member
        sim_use_double      = sim.use_double;
        sim_domain          = sim.domain;
        sim_layout          = sim.layout;
        sim_typical_length  = sim.domain[0];
        sim_typical_vel     = sim.compute_ubo.wall_velocity_soss;
        sim_layers          = sim.layers;
        sim_work_group_size = sim.work_group_size;
        sim_step_size       = sim.step_size;

        sim_wall_velocity   = sim.compute_ubo.wall_velocity_soss * sim.speed_of_sound * sim.speed_of_sound;
        sim_relaxation_rate = 1 / sim.compute_ubo.collision_frequency;
        vis_line_display.sim_domain  = sim.domain;

        scale_win_pos.x = windowWidth  -  60;     // set x - position of scale window
        scale_win_pos.y = windowHeight - 190;     // set y - position of scale window

        updateViscosity;
    }


    //
    // Loop draw called in main loop
    //
    void draw() {

        // record next command buffer asynchronous
        if( draw_gui )      // this can't be a function pointer as well
            this.buildGui;  // as we wouldn't know what else has to be drawn (drawFunc or drawFuncPlay etc. )

        app.draw;
    }


    private:

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


    //
    // Create and draw User Interface
    //
    void buildGui() {

        auto io = & ImGui.GetIO();

        //
        // general per frame data
        //

        {
            // Setup time step
            auto current_time = cast( float )glfwGetTime();
            io.DeltaTime = time > 0.0f ? ( current_time - time ) : ( 1.0f / 60.0f );
            xform_ubo.time_step = io.DeltaTime;
            time = current_time;

            // Setup inputs
            if( glfwGetWindowAttrib( window, GLFW_FOCUSED )) {
                double mouse_x, mouse_y;
                glfwGetCursorPos( window, & mouse_x, & mouse_y );
                io.MousePos = ImVec2( cast( float )mouse_x, cast( float )mouse_y );   // Mouse position in screen coordinates (set to -1,-1 if no mouse / on another screen, etc.)
            } else {
                io.MousePos = ImVec2( -1, -1 );
            }

            // Handle mouse button data from callback
            for( int i = 0; i < 3; i++ ) {
                // If a mouse press event came, always pass it as "mouse held this frame", so we don't miss click-release events that are shorter than 1 frame.
                io.MouseDown[ i ] = mouse_pressed[ i ] || glfwGetMouseButton( window, i ) != 0;
                mouse_pressed[ i ] = false;
            }

            // Handle mouse scroll data from callback
            io.MouseWheel = mouse_wheel;
            mouse_wheel = 0.0f;

            // Hide OS mouse cursor if ImGui is drawing it
            glfwSetInputMode( window, GLFW_CURSOR, io.MouseDrawCursor ? GLFW_CURSOR_HIDDEN : GLFW_CURSOR_NORMAL );

            // Start the frame
            ImGui.NewFrame;

            // possibly draw mini window to display the maximum size of the current color scale
            if( vis.draw_scale && vis.display_property != Vis_State.Property.VEL_GRAD ) {
                ImGui.SetNextWindowPos(  scale_win_pos,  ImGuiCond_Always );
                ImGui.SetNextWindowSize( scale_win_size, ImGuiCond_Always );
                ImGui.PushStyleColor( ImGuiCol_WindowBg, 0 );
                ImGui.Begin( "Scale Window", null, window_flags );
                if(( vis.display_property == Vis_State.Property.DENSITY )
                || ( vis.display_property == Vis_State.Property.VEL_MAG ))
                    ImGui.Text( " %.3f",  1 / vis.display_ubo.amplify_property );
                else
                    ImGui.Text( "+-%.3f", 1 / vis.display_ubo.amplify_property );
                ImGui.End();
                ImGui.PopStyleColor;
            }

            // define main gui window position and size
            ImGui.SetNextWindowPos(  main_win_pos,  ImGuiCond_Always );
            ImGui.SetNextWindowSize( main_win_size, ImGuiCond_Always );
            ImGui.Begin( "Main Window", null, window_flags );

            // create transport controls at top of window
            if( isPlaying )   { if( ImGui.Button( "Pause", button_size_3 )) simPause; }
            else              { if( ImGui.Button( "Play",  button_size_3 )) simPlay;  }
            ImGui.SameLine;     if( ImGui.Button( "Step",  button_size_3 )) simStep;
            ImGui.SameLine;     if( ImGui.Button( "Reset", button_size_3 )) simReset;
            ImGui.Separator;

            // set width of items and their label
            ImGui.PushItemWidth( main_win_size.x / 2 );
        }



        //
        // ImGui example Widgets
        //
        if( show_imgui_examples ) {

            auto style = & ImGui.GetStyle();

            // set gui transparency
            ImGui.SliderFloat( "Gui Alpha", & style.Colors[ ImGuiCol_WindowBg ].w, 0.0f, 1.0f );

            // little hacky, but works - as we know that the corresponding clear value index
            ImGui.ColorEdit3( "Clear Color", cast( float* )( & clear_values[ 1 ] ));

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



        //
        // Compute Device
        //
        if( ImGui.CollapsingHeader( "Compute Device" )) {
            ImGui.Separator;
            ImGui.PushItemWidth( -1 );
            if( ImGui.Combo( "Device", & compute_device, device_names )) {
                if( compute_device == 0 ) {
                    this.cpuReset;
                    this.setCpuSimFuncs;
                    use_cpu = true;
                    drawCmdBufferCount = sim_play_cmd_buffer_count = 1;
                } else {
                    this.setDefaultSimFuncs;
                    use_cpu = false;
                    sim_use_double &= feature_shader_double;
                    if( play_mode == Transport.play ) {     // in profile mode this must stay 1 (switches with play/pause )
                        sim_play_cmd_buffer_count = 2;      // as we submitted compute and draw command buffers separately
                        if( transport == Transport.play ) { // if we are in play mode
                            drawCmdBufferCount = 2;         // we must set this value immediately
                        }
                    }
                }
            }
            ImGui.Separator;
            float cursor_pos_y = ImGui.GetCursorPosY();
            ImGui.ImGui.SetCursorPosY(cursor_pos_y + 3);
            ImGui.Text( "VK_PRESENT_MODE_" );
            ImGui.SameLine;
            ImGui.SetCursorPosY(cursor_pos_y);
            if( ImGui.Combo( "Present Mode", & selected_present_mode, available_present_modes.ptr )) {
                resources.resizeRenderResources( app, cast( VkPresentModeKHR )available_present_modes_map[ selected_present_mode ] );
                //app.drawInit;
            }

            ImGui.PopItemWidth;

            collapsingTerminator;
        }



        //
        // Compute Parameters
        //
        float drag_step = 16;
        if( ImGui.CollapsingHeader( "Compute Parameter", ImGuiTreeNodeFlags_DefaultOpen )) {
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
                if( ImGui.Combo( "Initialize", & init_shader_index, //"shader/init_D2Q9.comp\0\0" )
                    init_shader_start_index == typeof( init_shader_start_index ).max
                        ? "None found!"
                        : shader_names_ptr[ init_shader_start_index ] )
                    ) {
                    if( init_shader_start_index != typeof( init_shader_start_index ).max ) {
                        if(!compareShaderNamesAndReplace( shader_names_ptr[ init_shader_start_index + init_shader_index ], sim.init_shader.ptr )) {
                            app.createBoltzmannPSO( true, false, true );
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
                        if( init_shader_start_index != typeof( init_shader_start_index ).max ) {     // might all have been deleted
                            if(!compareShaderNamesAndReplace( shader_names_ptr[ init_shader_start_index + init_shader_index ], sim.init_shader.ptr )) {
                                app.createBoltzmannPSO( true, false, true );
                            }
                        }
                    }
                }

                // parse init shader through context menu
                if( ImGui.BeginPopupContextItem( "Init Shader Context Menu" )) {
                    if( ImGui.Selectable( "Parse Shader" )) {
                        app.createBoltzmannPSO( true, false, true );
                    } ImGui.EndPopup();
                }

                ImGui.Spacing;

                // select loop shader
                if( ImGui.Combo( "Simulate", & loop_shader_index, //"shader/loop_D2Q9_channel_flow.comp\0\0" )
                    loop_shader_start_index == typeof( loop_shader_start_index ).max
                        ? "None found!"
                        : shader_names_ptr[ loop_shader_start_index ] )
                    ) {
                    if( loop_shader_start_index != typeof( loop_shader_start_index ).max ) {
                        if(!compareShaderNamesAndReplace( shader_names_ptr[ loop_shader_start_index + loop_shader_index ], sim.loop_shader.ptr )) {
                            app.createBoltzmannPSO( false, true, false );
                        }
                    }
                }

                // update loop shader list when hovering over Combo
                if( ImGui.IsItemHovered ) {
                    if( hasShaderDirChanged ) {
                        parseShaderDirectory;   // see comment in IsItemHovered above
                        if( loop_shader_start_index != typeof( loop_shader_start_index ).max ) {
                            if(!compareShaderNamesAndReplace( shader_names_ptr[ loop_shader_start_index + loop_shader_index ], sim.loop_shader.ptr )) {
                                app.createBoltzmannPSO( false, true, false );
                            }
                        }
                    }
                }

                // parse loop shader through context menu
                if( ImGui.BeginPopupContextItem( "Loop Shader Context Menu" )) {
                    if( ImGui.Selectable( "Parse Shader" )) {
                        app.createBoltzmannPSO( false, true, false );
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
            // Values per node and their precision
            //
            ImGui.PushItemWidth( 86 );
            if( ImGui.Combo( "##Layout per Cell", cast( int* )( & sim_layout ), "D0Q0\0D2Q9\0D3Q15\0\0" )) {
                sim_layers = sim.layout_value_count[ sim_layout ];
                checkComputeParams;
            }

            // Specify precision
            int precision = sim_use_double;
            ImGui.SameLine;
            if( ImGui.Combo( "Cell Layout", & precision, feature_shader_double || use_cpu ? "Float\0Double\0\0" : "Float\0\0" )) {
                sim_use_double = precision > 0;
                checkComputeParams;
            }

            if( ImGui.DragInt( "##Values per Cell", cast( int* )( & sim_layers ), 0.1f, 1, 1024 ))
                checkComputeParams;

            ImGui.SameLine;
            if( ImGui.Combo( "Additional Values", & precision, feature_shader_double || use_cpu ? "Float\0Double\0\0" : "Float\0\0" )) {
                sim_use_double = precision > 0;
                checkComputeParams;
            }

            // inform if double precision is not available or CPU mode is deactivated
            if( !( feature_shader_double || use_cpu ))
                showTooltip( "Shader double precision is not available on the selected device." );

            ImGui.PopItemWidth;


            //
            // Grid Resolution
            //
            if( !sim_use_3_dim
                ? ImGui.DragInt2( "Grid Resolution", cast( int* )( sim_domain.ptr ), drag_step, 4, 4096 )
                : ImGui.DragInt3( "Grid Resolution", cast( int* )( sim_domain.ptr ), drag_step, 4, 4096 ))
                checkComputeParams;

            if( ImGui.BeginPopupContextItem( "Sim Domain Context Menu" )) {
                import core.stdc.stdio : sprintf;
                char[24]    label;
                char[3]     dir = [ 'X', 'Y', 'Z' ];
                float       click_range = 0.5 / ( 2 + sim_use_3_dim );
                float       mouse_pos_x = ImGui.GetMousePosOnOpeningCurrentPopup.x;

                foreach( j; 0 .. 2 + sim_use_3_dim ) {
                    if(( j * click_range * main_win_size.x < mouse_pos_x ) && ( mouse_pos_x < ( j + 1 ) * click_range * main_win_size.x )) {
                        uint dim = 8;
                        sprintf( label.ptr, "Resolution %c", dir[j] );
                        ImGui.Text( label.ptr );
                        ImGui.Separator;
                        foreach( i; 0 .. 12 ) {
                            sprintf( label.ptr, "Size %c: %d", dir[j], dim );
                            if( ImGui.Selectable( label.ptr )) {
                                sim_domain[j] = dim;
                                checkComputeParams;
                            }
                            dim *= 2;
                        }

                        if( !sim_use_3_dim ) {
                            ImGui.Separator;
                            sprintf( label.ptr, "Window Res %c",     dir[j] ); if( ImGui.Selectable( label.ptr )) { sim_domain[j] = ( j == 0 ? windowWidth : windowHeight );     checkComputeParams; }
                            sprintf( label.ptr, "Window Res %c / 2", dir[j] ); if( ImGui.Selectable( label.ptr )) { sim_domain[j] = ( j == 0 ? windowWidth : windowHeight ) / 2; checkComputeParams; }
                            sprintf( label.ptr, "Window Res %c / 4", dir[j] ); if( ImGui.Selectable( label.ptr )) { sim_domain[j] = ( j == 0 ? windowWidth : windowHeight ) / 4; checkComputeParams; }
                            sprintf( label.ptr, "Window Res %c / 8", dir[j] ); if( ImGui.Selectable( label.ptr )) { sim_domain[j] = ( j == 0 ? windowWidth : windowHeight ) / 8; checkComputeParams; }
                        }
                    }
                }

                if( 0.5 * main_win_size.x < mouse_pos_x ) {
                    uint dim = 8;
                    ImGui.Text( !sim_use_3_dim ? "Resolution XY" : "Resolution XYZ" );
                    ImGui.Separator;
                    const( char )*[2] vol = [ "XY", "XYZ" ];
                    foreach( i; 0 .. 12 ) {
                        sprintf( label.ptr, "Size %s: %d ^ %d", vol[ sim_use_3_dim ], dim, 2 + sim_use_3_dim );
                        if( ImGui.Selectable( label.ptr )) {
                            sim_domain[ 0 .. 2 + sim_use_3_dim ] = dim;
                            checkComputeParams;
                        } dim *= 2;
                    }

                    if( !sim_use_3_dim ) {
                        ImGui.Separator;
                        if( ImGui.Selectable( "Window Res"     )) { sim_domain[0] = windowWidth;     sim_domain[1] = windowHeight;     checkComputeParams; }
                        if( ImGui.Selectable( "Window Res / 2" )) { sim_domain[0] = windowWidth / 2; sim_domain[1] = windowHeight / 2; checkComputeParams; }
                        if( ImGui.Selectable( "Window Res / 4" )) { sim_domain[0] = windowWidth / 4; sim_domain[1] = windowHeight / 4; checkComputeParams; }
                        if( ImGui.Selectable( "Window Res / 8" )) { sim_domain[0] = windowWidth / 8; sim_domain[1] = windowHeight / 8; checkComputeParams; }
                    }
                } ImGui.EndPopup();
            }


            // helper function to update step size and related parameters
            uint32_t updateStepSize( uint32_t step_size ) {
                sim.step_size = step_size;
                app.createBoltzmannPSO( false, true, false );   // rebuild init pipeline, rebuild loop pipeline, reset domain
                if( vis.amplify_prop_div_steps ) {              // if the property should be scaled by the reciprocal step size, we update the display UBO
                    vis.display_ubo.amplify_property = vis.amplify_property / sim.step_size;
                    updateDisplayUBO;
                }
                return step_size;
            }


            // Apply button for all the settings within Compute Parameter
            // If more then work group size has changed rebuild sim_buffer
            // If the simulation dimensions has not changed we do not need to rebuild sim_image
            // Update the descriptor set, rebuild compute command buffers and reset cpu data if running on cpu
            // We also update the scale of the display plane and normalization factors for the velocity lines
            // Additionally if only the work group size changes, we need to update only the compute PSO (see else if)
            if( compute_dirty ) {
                if( ImGui.Button( "Apply", button_size_2 )) {

                    if(!sim_use_3_dim )
                        sim_domain[2] = 1;

                    // only if the sim domain changed we must ...
                    if( sim.domain != sim_domain ) {
                        // recreate sim image and vis_line_display push constant data
                        sim.domain = vis_line_display.sim_domain = sim_domain;
                        this.createMacroImage;

                        // recreate sim particle buffer
                        vis.particle_count = sim_domain[0] * sim_domain[1] * sim_domain[2];

                        // update trackball
                        import input : initTrackball;
                        this.initTrackball;
                    }

                    compute_dirty       = work_group_dirty = false;
                    sim.layout          = sim_layout;
                    sim.work_group_size = sim_work_group_size;
                    sim.step_size       = sim_step_size;
                    sim.layers          = sim_layers;
                    app.sim.use_double  = sim_use_double;

                    // this way to compute the particle instance count is not safe, we don't know
                    // how many cell values were added additionally on top of the sim type requriement
                    // Todo(pp): filter sim shader dropdown options with DdQq enum
                    vis.particle_instance_count = vis.particle_type == vis.Particle_Type.Debug_Popul   ?   sim.cell_val_count / 2 + 1   :   1;

                    // this must be after sim_domain_changed edits
                    this.createPopulBuffer;

                    // update descriptor, at least the sim buffer has changed, and possibly the sim image
                    this.updateDescriptorSet;

                    // recreate Lattice Boltzmann pipeline with possibly new shaders
                    app.createBoltzmannPSO( true, true, true );

                    if( use_cpu ) {
                        app.cpuReset;
                    }
                }
                ImGui.SameLine;
                ImGui.Text( "Changes" );

            } else if( work_group_dirty ) {
                if( ImGui.Button( "Apply", button_size_2 )) {
                    work_group_dirty    = false;
                    sim.work_group_size = sim_work_group_size;
                    sim.step_size       = sim_step_size;
                    app.createBoltzmannPSO( true, true, false );    // rebuild init pipeline, rebuild loop pipeline, reset domain
                }
                ImGui.SameLine;
                ImGui.Text( "Changes" );

            } else if( sim.step_size != sim_step_size ) {
                if( ImGui.Button( "Apply", button_size_2 ))
                    updateStepSize( sim_step_size );
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
            if( ImGui.DragInt( "Work Group Size X", cast( int* )( & sim_work_group_size[0] ), drag_step, 1, 1024 )) checkComputePSO;

            if( ImGui.BeginPopupContextItem( "Work Group Size Context Menu" )) {
                ImGui.Text( "Group Size X" );
                ImGui.Separator;

                char[24] label;
                uint dim = 2;
                import core.stdc.stdio;
                foreach( i; 0 .. 10 ) {
                    sprintf( label.ptr, "Size X: %d", dim );
                    if( ImGui.Selectable( label.ptr )) {
                        sim_work_group_size[0] = dim;
                        checkComputePSO;
                    } dim *= 2;
                } dim = 2;
                if( ImGui.Selectable( "Resolution X" )) { sim_work_group_size[0] = sim_domain[0]; checkComputePSO; }
                foreach( i; 0 .. 8 ) {
                    sprintf( label.ptr, "Resolution X / %d", dim );
                    if( ImGui.Selectable( label.ptr  )) { sim_work_group_size[0] = sim_domain[0] / dim; checkComputePSO; }
                    dim *= 2;
                } ImGui.EndPopup();
            }


            //
            // Display Every Nth Step
            //
            int step_size = cast( int )sim_step_size;
            if( ImGui.DragInt( "Steps per Cmd Buffer", & step_size, 0.1, 1, int.max )) {
                sim_step_size = step_size < 1 ? 1 : step_size;
            }

            // shortcut to set values
            if( ImGui.BeginPopupContextItem( "Step Size Context Menu" )) {
                if( ImGui.Selectable( "1" ))     sim_step_size = updateStepSize( 1 );
                if( ImGui.Selectable( "5" ))     sim_step_size = updateStepSize( 5 );
                if( ImGui.Selectable( "10" ))    sim_step_size = updateStepSize( 10 );
                if( ImGui.Selectable( "50" ))    sim_step_size = updateStepSize( 50 );
                if( ImGui.Selectable( "100" ))   sim_step_size = updateStepSize( 100 );
                if( ImGui.Selectable( "500" ))   sim_step_size = updateStepSize( 500 );
                if( ImGui.Selectable( "1000" ))  sim_step_size = updateStepSize( 1000 );
                if( ImGui.Selectable( "5000" ))  sim_step_size = updateStepSize( 5000 );
                if( ImGui.Selectable( "10000" )) sim_step_size = updateStepSize( 10000 );
                if( ImGui.Selectable( "50000" )) sim_step_size = updateStepSize( 50000 );
                ImGui.EndPopup();
            }

            ImGui.Separator;
            int index = cast( int )sim.compute_ubo.comp_index;
            ImGui.PushStyleColor( ImGuiCol_Text, disabled_text );
            ImGui.DragInt( "Compute Index", & index );
            ImGui.PopStyleColor( 1 );

            collapsingTerminator;
        }



        //
        // Simulation Parameters
        //
        if( ImGui.CollapsingHeader( "Simulation Parameter" )) {
            // preset settings context menu
            if( ImGui.BeginPopupContextItem( "Simulation Parameter Context Menu" )) {
                if( ImGui.Selectable( "Unit Parameter" )) {
                    sim_wall_velocity = 0.1;
                    updateWallVelocity;
                    sim.compute_ubo.wall_thickness = 1;
                    sim.compute_ubo.collision_frequency = sim_relaxation_rate = 1;
                    updateViscosity;
                    updateComputeUBO;
                }

                if( ImGui.Selectable( "Low Viscosity" ))        lowSimSettings( 0.005,  0.504   );
                if( ImGui.Selectable( "Looow Viscosity" ))      lowSimSettings( 0.001,  0.5001  );
                if( ImGui.Selectable( "Zero Visco-Velocity" ))  lowSimSettings( 0.0,    0.5     );
                //if( ImGui.Selectable( "Crazy Cascades" ))     lowSimSettings( 0.5,    0.8     );  // set resolution to 1024 * 1024

                ImGui.EndPopup();
            }

            ImGui.Separator;

            // Relaxation Rate Tau
            if( ImGui.DragFloat( "Relaxation Rate Tau", & sim_relaxation_rate, 0.001f, 0.5f, 2.0f, "%.4f" )) {
                sim.compute_ubo.collision_frequency = 1 / sim_relaxation_rate;
                updateViscosity;
                updateComputeUBO;
            }

            // wall velocity
            if( ImGui.DragFloat( "Wall Velocity", & sim_wall_velocity, 0.001f )) {
                updateWallVelocity;
                updateComputeUBO;
            }

            // wall thickness
            int wall_thickness = sim.compute_ubo.wall_thickness;
            if( ImGui.DragInt( "Wall Thickness", & wall_thickness, 0.1f, 1, 255 )) {
                sim.compute_ubo.wall_thickness = wall_thickness < 1 ? 1 : wall_thickness > 255 ? 255 : wall_thickness;
                updateComputeUBO;
            }

            // collision algorithm
            if( ImGui.Combo( "Collision Algorithm", cast( int* )( & sim.collision ), "SRT-LBGK\0TRT\0MRT\0Cascaded\0Cascaded Drag\0\0" )) {
                app.createBoltzmannPSO( false, true, false );
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
                if( ImGui.DragFloat2( "Spatial/Temporal Unit", & sim.unit_spatial, 0.001f )) {  // next value in struct is sim.unit_temporal
                    sim.speed_of_sound = sim.unit_speed_of_sound * sim.unit_spatial / sim.unit_temporal;
                    updateTauOmega;
                    updateComputeUBO;
                }

                // kinematic viscosity
                if( ImGui.DragFloat( "Kinematic Viscosity", & sim_viscosity, 0.001f, 0.0f, 1000.0f, "%.9f", 2.0f )) {
                    updateTauOmega;
                    updateComputeUBO;
                }

                // Collision Frequency Omega
                if( ImGui.DragFloat( "Collision Frequency", & sim.compute_ubo.collision_frequency, 0.001f, 0, 2 )) {
                    sim_relaxation_rate = 1 / sim.compute_ubo.collision_frequency;
                    updateViscosity;
                    updateComputeUBO;
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

                ImGui.DragFloat( "Typical Velocity U", & sim_typical_vel, 0.001f );
                if( ImGui.BeginPopupContextItem( "Typical Velocity Context Menu" )) {
                    if( ImGui.Selectable( "Wall Velocity" )) { sim_typical_vel = sim_wall_velocity; }
                    ImGui.EndPopup();
                }

                ImGui.DragFloat( "Typical Length L", & sim_typical_length, 0.001f );

                auto next_win_size = ImVec2( 200, 60 ); ImGui.SetNextWindowSize( next_win_size );
                if( ImGui.BeginPopupContextItem( "Typical Length Context Menu" )) {

                    if( ImGui.Selectable( "Spatial Lattice Unit" )) { sim_typical_length = sim.unit_spatial; }
                    ImGui.Separator;

                    ImGui.Columns( 2, "Typical Length Context Columns", true );

                    if( ImGui.Selectable( "Lattice X" )) { sim_typical_length = sim_domain[0]; }
                    ImGui.NextColumn();
                    if( ImGui.Selectable( "Lattice Y" )) { sim_typical_length = sim_domain[1]; }
                    ImGui.NextColumn();

                    if( ImGui.Selectable( "Domain X"  )) { sim_typical_length = sim_domain[0] * sim.unit_spatial; }
                    ImGui.NextColumn();
                    if( ImGui.Selectable( "Domain Y"  )) { sim_typical_length = sim_domain[1] * sim.unit_spatial; }
                    ImGui.NextColumn();

                    ImGui.EndPopup;
                }

                // editing the Reynolds number changes the viscosity and collision frequency
                float re = sim_typical_vel * sim_typical_length / sim_viscosity;
                if( ImGui.DragFloat( "Re", & re, 0.001f )) {
                    sim_viscosity = sim_typical_vel * sim_typical_length / re;
                    updateTauOmega;
                    updateComputeUBO;
                }

                ImGui.PopItemWidth;
                ImGui.TreePop;
            }

            collapsingTerminator;
        }



        //
        // Display Parameters
        //
        if( ImGui.CollapsingHeader( "Display Parameter", ImGuiTreeNodeFlags_DefaultOpen )) {
            ImGui.Separator;

            // show / hide the display plane
            ImGui.SetCursorPosX( 160 );
                ImGui.Checkbox( "Draw Display Plane", & vis.draw_display );

            if( ImGui.BeginPopupContextItem( "Display Property Context Menu" )) {
                if( ImGui.Selectable( "Parse Display Shader" )) {
                    this.createDisplayPSO;
                } ImGui.EndPopup();
            }

            // specify display parameter
            if( ImGui.Combo(
                "Display Property", cast( int* )( & vis.display_property ),
                "Density\0Velocity X\0Velocity Y\0Velocity Magnitude\0Velocity Gradient\0Velocity Curl\0Tex Coordinates\0\0"
            ))  {
                this.createDisplayPSO;
                this.createScalePSO;
            }

            if( ImGui.DragFloat( "Amp Display Property", & vis.amplify_property, 0.001f, 0, 255 )) {
                vis.display_ubo.amplify_property = vis.amplify_prop_div_steps ? vis.amplify_property / sim.step_size : vis.amplify_property;
                updateDisplayUBO;
            }

            if( ImGui.BeginPopupContextItem( "Amp Display Context " )) {
                ImGui.PushItemWidth( 60 );

                void createAmpDisplayContextItem( string_z drag_float_name, string_z selectable_name, float property_value ) {
                    if( ImGui.DragFloat( drag_float_name, & vis.amplify_property, property_value, 0, 255 )) {
                        vis.display_ubo.amplify_property = vis.amplify_prop_div_steps ? vis.amplify_property / sim.step_size : vis.amplify_property;
                        updateDisplayUBO;
                    }
                    ImGui.SameLine;
                    if( ImGui.Selectable( selectable_name )) {
                        vis.amplify_property = property_value;
                        vis.display_ubo.amplify_property = vis.amplify_prop_div_steps ? vis.amplify_property / sim.step_size : vis.amplify_property;
                        updateDisplayUBO;
                    }
                }

                createAmpDisplayContextItem( " * ##Amp_0", "0.001", 0.001f );
                createAmpDisplayContextItem( " * ##Amp_1", "0.01",  0.010f );
                createAmpDisplayContextItem( " * ##Amp_2", "0.1",   0.100f );
                createAmpDisplayContextItem( " * ##Amp_3", "1.0",   1.000f );
                createAmpDisplayContextItem( " * ##Amp_4", "10.0",  10.00f );
                createAmpDisplayContextItem( " * ##Amp_5", "100.0", 100.0f );

                ImGui.PopItemWidth;
                ImGui.EndPopup();
            }

            if( ImGui.DragInt( "Color Layers", cast( int* )( & vis.display_ubo.color_layers ), 0.1f, 0, 255 )) updateDisplayUBO;

            static int z_layer = 0;
            if( sim_use_3_dim ) {
                if( ImGui.DragInt( "Z-Layer", & z_layer, 0.1f, 0, sim_domain[2] - 1 )) {
                    z_layer = 0 > z_layer ? 0 : z_layer >= sim_domain[2] ? sim_domain[2] - 1 : z_layer;
                    vis.display_ubo.z_layer = z_layer;
                    updateDisplayUBO;
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

                ImGui.SetCursorPosX( 160 );
                ImGui.Checkbox( "Draw Velocity", & draw_velocity_lines );

                ImGui.Separator;

                int line_count = vis_line_display.repl_count;
                if( ImGui.DragInt( "Velocity Curve Count", & vis_line_display.repl_count, 0.1, 0, int.max ))
                    vis_line_display.repl_count = vis_line_display.repl_count < 0 ? 0 : vis_line_display.repl_count;

                ImGui.DragFloat2( "Line Offset / Spread", & vis_line_display.line_offset, 1.0f );  // next value in struct is repl_spread

                ImGui.BeginGroup(); // Want to use popup on the following three items
                {
                    string_z axis_label = "X\0Y\0Z\0\0";
                    int axis = cast( int )vis_line_display.velocity_axis;
                    if( ImGui.Combo( "Velocity Direction", & axis, axis_label ))
                        vis_line_display.velocity_axis = cast( Line_Axis )axis;

                    axis = cast( int )vis_line_display.repl_axis;
                    if( ImGui.Combo( "Replication Direction", & axis, axis_label ))
                        vis_line_display.repl_axis = cast( Line_Axis )axis;

                    axis = cast( int )vis_line_display.line_axis;
                    if( ImGui.Combo( "Line Direction", & axis, axis_label ))
                        vis_line_display.line_axis = cast( Line_Axis )axis;
                }
                ImGui.EndGroup();

                // line axis setup shortcut for U- and V-Velocities
                if( ImGui.BeginPopupContextItem( "Velocity Lines Context Menu" )) {
                    if( ImGui.Selectable( "U-Velocity" )) {
                        vis_line_display.line_axis      = Line_Axis.Y;
                        vis_line_display.repl_axis      = Line_Axis.X;
                        vis_line_display.velocity_axis  = Line_Axis.X;
                    }

                    if( ImGui.Selectable( "V-Velocity" )) {
                        vis_line_display.line_axis      = Line_Axis.X;
                        vis_line_display.repl_axis      = Line_Axis.Y;
                        vis_line_display.velocity_axis  = Line_Axis.Y;
                    }

                    ImGui.EndPopup();
                }

                ImGui.SetCursorPosX( 160 );
                ImGui.Checkbox( "Draw Base Lines", & draw_vel_base );

                ImGui.SetCursorPosX( 160 );
                ImGui.Checkbox( "Draw as Points", & lines_as_points );

                float plsw = point_size_line_width[1];
                if( lines_as_points )
                    ImGui.DragFloat( "Point Size##0", & plsw, 0.125, 0.25f );
                else
                    ImGui.DragFloat( "Line Width##0", & plsw, 0.125, 0.25f );
                point_size_line_width[1] = 0.125 < plsw ? plsw : 0.125;

                ImGui.PopItemWidth;
                ImGui.TreePop;
            }

            collapsingTerminator;


            //
            // particles tree node
            //
            if( ImGui.TreeNode( "Particles" )) {
                ImGui.Separator;


                // Todo(pp): extend gui and functionality of particle drawing

                // set width of items and their label - aligned visually with 8 pixels
                ImGui.PushItemWidth( ImGui.GetContentRegionAvailWidth - main_win_size.x / 2 + 8 );

                ImGui.SetCursorPosX( 160 );
                ImGui.Checkbox( "Draw Particles", & vis.draw_particles );

                // parse particle draw shader through context menu
                if( ImGui.BeginPopupContextItem( "Particle Shader Context Menu" )) {
                    if( ImGui.Selectable( "Parse Shader" )) {
                        this.createParticlePSO;
                    } ImGui.EndPopup();
                }

                // particle type, mostly for debugging
                if( ImGui.Combo( "Particle Type", cast( int* )( & vis.particle_type ), "Velocity\0Debug Density\0Debug Popul\0\0" )) {

                    // recreate sim particle buffer
                    vis.particle_count = sim_domain[0] * sim_domain[1] * sim_domain[2];

                    // this way to compute the particle instance count is not safe, we don't know
                    // how many cell values were added additionally on top of the sim type requriement
                    // // Todo(pp): filter sim shader dropdown options with DdQq enum
                    vis.particle_instance_count = vis.particle_type == vis.Particle_Type.Debug_Popul   ?   sim.cell_val_count / 2 + 1   :   1;
                    this.createParticlePSO;
                }

                // modify (shrink only) particle count
                int pc = cast( int )app.vis.particle_count;
                int pc_max = cast( int )( sim_domain[0] * sim_domain[1] * sim_domain[2] );
                ImGui.DragInt( "Particle Count", cast( int* )( & pc ));
                app.vis.particle_count = cast( uint )( pc < 1 ? 1 : pc < pc_max ? pc : pc_max );


                // blend particles normally or additive
                ImGui.SetCursorPosX( 160 );
                if( ImGui.Checkbox( "Additive Blend", & vis.particle_additive_blend )) {
                    this.createParticlePSO;
                }

                // particle color and alpha
                ImGui.ColorEdit4( "Particle Color", vis.particle_pc.point_rgba.ptr );

                // particle size and (added) velocity scale
                ImGui.DragFloat2( "Size / Speed Scale", & vis.particle_pc.point_size, 0.25f );  // next value in struct is speed_scale

                // reset particle button, same as hotkey F8
                auto button_sub_size_1 = ImVec2( 324, 20 );
                if( ImGui.Button( "Reset Particles", button_sub_size_1 )) {
                    this.resetParticleBuffer;
                }

                // temporay tets
                auto sd = app.sim.domain;
                auto sa = app.sim.compute_ubo.slide_axis;
                ImGui.DragInt4( "Slide Axis", cast( int* )( sa.ptr ));
                app.sim.compute_ubo.slide_axis[0] = sa[0] < 0 ? 0 : sa[0] >= sd[0]              ? sd[0] - 1              : sa[0];
                app.sim.compute_ubo.slide_axis[1] = sa[1] < 0 ? 0 : sa[1] >= sd[1]              ? sd[1] - 1              : sa[1];
                app.sim.compute_ubo.slide_axis[2] = sa[2] < 0 ? 0 : sa[2] >= sd[2]              ? sd[2] - 1              : sa[2];
                app.sim.compute_ubo.slide_axis[3] = sa[3] < 0 ? 0 : sa[3] >= vis.particle_count ? vis.particle_count - 1 : sa[3];

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

                // little hacky, but works - as we know the corresponding clear value index
                ImGui.ColorEdit3( "Clear Color", cast( float* )( & clear_values[ 1 ] ));

                ImGui.SetCursorPosX( 160 );
                ImGui.Checkbox( "Draw Axis", & draw_axis );

                ImGui.SetCursorPosX( 160 );
                ImGui.Checkbox( "Draw Grid", & draw_grid );

                ImGui.SetCursorPosX( 160 );
                ImGui.Checkbox( "Draw Scale", & vis.draw_scale );

                ImGui.SetCursorPosX( 160 );
                ImGui.Checkbox( "Draw Bounds", & draw_bounds );

                ImGui.PopItemWidth;
                ImGui.TreePop;
            }

            collapsingTerminator;
        }



        //
        // Profile Simulation
        //
        if( ImGui.CollapsingHeader( "Profile Simulation" )) {
            ImGui.Separator;

            //static int checkbox_offset = 160;
            //ImGui.DragInt( "Checkbox Offset", & checkbox_offset );
            ImGui.SetCursorPosX( 160 );

            if( ImGui.Checkbox( "Enable Profiling", & profile_mode )) {

                auto playing = isPlaying;
                simPause;    // currently sim is crashing we don't enter pause mode

                if( profile_mode ) {
                    play_mode = Transport.profile;
                    sim_play_cmd_buffer_count = 1;
                } else {
                    play_mode = Transport.play;
                    if( !use_cpu ) {
                        sim_play_cmd_buffer_count = 2;
                    }
                }

                if( playing ) simPlay;
            }


            ImGui.DragInt( "Profile Step Count", cast( int* )( & sim_profile_step_count ));

            int index = cast( int )sim_profile_step_index;
            ImGui.PushStyleColor( ImGuiCol_Text, disabled_text );
            ImGui.DragInt( "Profile Step Index", & index );
            ImGui.PopStyleColor( 1 );

            import core.stdc.stdio : sprintf;
            char[24] buffer;

            long duration = getStopWatch_hnsecs;
            sprintf( buffer.ptr, "%llu", duration );
            ImGui.InputText( "Duration (hnsecs)", buffer.ptr, buffer.length, ImGuiInputTextFlags_ReadOnly );

            double avg_per_step = duration / cast( double )sim_profile_step_index;
            sprintf( buffer.ptr, "%f", avg_per_step );
            ImGui.InputText( "Dur. / Step (hnsecs)", buffer.ptr, buffer.length, ImGuiInputTextFlags_ReadOnly );

            ulong  node_count = sim.domain[0] * sim.domain[1] * sim.domain[2];
            double mlups = 10.0 * node_count * sim_profile_step_index / duration;
            sprintf( buffer.ptr, "%f", mlups );
            ImGui.InputText( "Average MLups", buffer.ptr, buffer.length, ImGuiInputTextFlags_ReadOnly );

            collapsingTerminator;
        }



        //
        // Validate Simulation
        //
        if( ImGui.CollapsingHeader( "Validate Simulation" )) {
            ImGui.Separator;

            ImGui.SetCursorPosX( 160 );
            ImGui.Checkbox( "Draw as Points", & lines_as_points );

            if( lines_as_points )
                ImGui.DragFloat2( "Point Size##1", point_size_line_width.ptr, 0.125f, 0.25f );
            else
                ImGui.DragFloat2( "Line Width##1", point_size_line_width.ptr, 0.125f, 0.25f );

            collapsingTerminator;

            //
            // Ghia tree node
            //
            if( ImGui.TreeNode( "Ghia et. all - Lid Driven Cavity" )) {
                ImGui.Separator;

                // set width of items and their label - aligned visually with 8 pixels
                ImGui.PushItemWidth( ImGui.GetContentRegionAvailWidth - main_win_size.x / 2 + 8 );

                int axis = cast( int )( vis_line_display.velocity_axis ) % 2;

                ImGui.SetCursorPosX( 160 );

                // setup parameter for profiling, sim_domain must be set manually
                ImGui.SetCursorPosX( 160 );
                if( ImGui.Checkbox( "Draw Ghia Profile", & validate_ghia )) {
                    if( validate_ghia ) {

                        bool update_descriptor = false;

                        sim_domain[0] = 127;
                        sim_domain[1] = 127;
                        sim_domain[2] = 1;

                        // only if the sim domain changed we must ...
                        if( sim.domain != sim_domain ) {
                            // recreate sim image, update trackball and vis_line_display push constant data
                            sim.domain = vis_line_display.sim_domain = sim_domain;
                            this.createMacroImage;
                            update_descriptor = true;
                            import input : initTrackball;
                            this.initTrackball;
                        }

                        sim_work_group_size[0]  = 127;
                        sim_use_double          = false;
                        sim_layers              = 17;

                        // only if work group size or sim layers don't correspond to shader requirement
                        if( sim.work_group_size[0] != 127 || sim.layers     != 17 ) {
                            sim.work_group_size[0]  = sim_work_group_size[0] = 127;
                            sim.layers              = sim_layers             = 17;

                            // this must be after sim_domain_changed edits
                            this.createPopulBuffer;
                            update_descriptor = true;

                        }

                        // update descriptor if necessary
                        if( update_descriptor )
                            this.updateDescriptorSet;

                        bool update_sim_psos = false;

                        if( app.sim.use_double ) {
                            if( sim.init_shader != "shader\\init_D2Q9_double.comp" ) {
                                sim.init_shader  = "shader\\init_D2Q9_double.comp";
                                update_sim_psos  = true;
                            }
                            if( sim.loop_shader != "shader\\loop_D2Q9_ldc_double.comp" ) {
                                sim.loop_shader  = "shader\\loop_D2Q9_ldc_double.comp";
                                update_sim_psos  = true;
                            }
                        } else {
                            if( sim.init_shader != "shader\\init_D2Q9.comp" ) {
                                sim.init_shader  = "shader\\init_D2Q9.comp";
                                update_sim_psos  = true;
                            }
                            if( sim.loop_shader != "shader\\loop_D2Q9_ldc.comp" ) {
                                sim.loop_shader  = "shader\\loop_D2Q9_ldc.comp";
                                update_sim_psos  = true;
                            }
                        }

                        // possibly recreate lattice boltzmann pipeline
                        if( update_sim_psos || update_descriptor ) {
                            app.createBoltzmannPSO( true, true, true );
                        }

                        // set additional gui data like velocity and reynolds number
                        sim_typical_length = 127;
                        sim_typical_vel = sim_wall_velocity  = 0.1;
                        updateWallVelocity;
                        sim.compute_ubo.wall_thickness = 1;

                        immutable float[7] re = [ 100, 400, 1000, 3200, 5000, 7500, 10000 ];
                        sim_viscosity = sim_wall_velocity * sim_typical_length / re[ ghia_type ];   // typical_vel * sim_typical_length
                        updateTauOmega;
                        updateComputeUBO;
                    }
                }


                ImGui.SetCursorPosX( 160 );
                ImGui.Checkbox( "Draw Velocity Profile", & validate_velocity );

                ImGui.SetCursorPosX( 160 );
                ImGui.Checkbox( "Draw Velocity Base", & validate_vel_base );

                if( ImGui.Combo( "Re Number", cast( int* )( & ghia_type ), "   100\0   400\0  1000\0  3200\0  5000\0  7500\0 10000\0\0" )) {
                    immutable float[7] re = [ 100, 400, 1000, 3200, 5000, 7500, 10000 ];
                    sim_viscosity = sim_wall_velocity * sim_typical_length / re[ ghia_type ];   // typical_vel * sim_typical_length
                    updateTauOmega;
                    updateComputeUBO;
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
                if( ImGui.Checkbox( "Draw Profile##1", & validate_poiseuille_flow )) {
                    if( validate_poiseuille_flow ) {
                        vis_line_display.velocity_axis  = Line_Axis.X;
                        vis_line_display.repl_axis      = Line_Axis.X;
                        vis_line_display.line_axis      = Line_Axis.Y;
                        vis_line_display.repl_count     = 5;
                        vis_line_display.line_offset    = sim_domain[0] / 10;
                        vis_line_display.repl_spread    = sim_domain[0] / 5;
                    } else {
                        vis_line_display.repl_count     = 0;
                    }
                }


                ImGui.PopItemWidth;
                ImGui.TreePop;
            }

            collapsingTerminator;

            /*
            //
            // taylor-green tree node
            //
            if( ImGui.TreeNode( "Taylor Green" )) {
                ImGui.Separator;

                // set width of items and their label - aligned visually with 8 pixels
                ImGui.PushItemWidth( ImGui.GetContentRegionAvailWidth - main_win_size.x / 2 + 8 );

                ImGui.SetCursorPosX( 160 );
                ImGui.Checkbox( "Draw Profile##2", & validate_taylor_green );


                ImGui.PopItemWidth;
                ImGui.TreePop;
            }

            collapsingTerminator;
            */
        }



        //
        // Export Ensight
        //
        if( ImGui.CollapsingHeader( "Export Ensight" )) {
            ImGui.Separator;

            if( use_cpu ) {
                ImGui.Text( "Export from CPU is not available" );
            } else {

                int index = cast( int )sim.index;
                ImGui.PushStyleColor( ImGuiCol_Text, disabled_text );
                ImGui.DragInt( "Simulation Index", & index );
                ImGui.PopStyleColor( 1 );
                ImGui.Separator;

                ImGui.DragInt( "Start Index", & exp.start_index,  0.1, 0 );
                ImGui.DragInt( "Step Count",  & exp.step_count,   0.1, 1 );
                ImGui.DragInt( "Every Nth Step", & exp.step_size, 0.1, 1 );
                ImGui.Separator;

                ImGui.InputText( "Case File Name", exp.case_file_name.ptr, exp.case_file_name.length );
                ImGui.InputText( "Var Name",  exp.variable_name.ptr, 9 );
                ImGui.SameLine;
                ImGui.SetCursorPosX( 10 + ImGui.GetCursorPosX );
                ImGui.Checkbox( "is Vector", & app.exp.as_vector );
                ImGui.Combo( "File Format", & cast( int )exp.file_format, "Ascii\0Binary\0\0" );
                ImGui.Separator;


                ImGui.Spacing;
                ImGui.Text( "Export Shader" );

                // select export shader
                ImGui.PushItemWidth( ImGui.GetWindowWidth * 0.75 );
                if( ImGui.Combo( "Export", & port_shader_index, //"shader/export_from_image.comp\0\0" )
                    port_shader_start_index == typeof( port_shader_start_index ).max
                        ? "None found!"
                        : shader_names_ptr[ port_shader_start_index ] )
                    ) {
                    if( port_shader_start_index != typeof( port_shader_start_index ).max ) {
                        auto export_shader_dirty = !compareShaderNamesAndReplace(
                            shader_names_ptr[ port_shader_start_index + port_shader_index ], exp.export_shader.ptr
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
                        if( port_shader_start_index != typeof( port_shader_start_index ).max ) {     // might all have been deleted
                            auto export_shader_dirty = !compareShaderNamesAndReplace(
                                shader_names_ptr[ port_shader_start_index + port_shader_index ], exp.export_shader.ptr
                            );
                        }
                    }
                } collapsingTerminator;


                // Execute the data export
                if( ImGui.Button( "Export Data", button_size_1 )) {

                    // reset simulation if we past the export step index
                    if( exp.start_index < sim.compute_ubo.comp_index ) {
                        simReset;
                    }

                    // create export related gpu data and setup export function
                    // gpu export is always float
                    this.createExportResources;

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
            ImGui.Begin( "Another Window", & show_another_window );
            ImGui.Text( "Hello" );
            ImGui.End();
        }

        // 3. Show the ImGui test window. Most of the sample code is in ImGui.ShowTestWindow()
        if( show_test_window ) {
            auto next_win_pos = ImVec2( 650, 20 ); ImGui.SetNextWindowPos( next_win_pos, ImGuiCond_FirstUseEver );
            ImGui.ShowTestWindow( & show_test_window );
        }

        if( show_style_editor ) {
            ImGui.Begin( "Style Editor", & show_style_editor );
            ImGui.ShowStyleEditor();
            ImGui.End();
        }


        ImGui.Render;
    }


    //
    // helper
    //
    void checkComputeParams() {
        compute_dirty =
            ( sim.use_double != sim_use_double )
        ||  ( sim.domain     != sim_domain )
        ||  ( sim.layout     != sim_layout )
        ||  ( sim.layers     != sim_layers );
    }

    void checkComputePSO() {
        work_group_dirty = sim.work_group_size != sim_work_group_size;
    }

    void updateTauOmega() {
        //float speed_of_sound_squared = sim.speed_of_sound * sim.speed_of_sound;
        //sim.compute_ubo.collision_frequency =
        //    2 * speed_of_sound_squared /
        //    ( sim.unit_temporal * ( 2 * sim_viscosity + speed_of_sound_squared ));
        //sim_relaxation_rate = 1 / sim.compute_ubo.collision_frequency;
        sim_relaxation_rate = 3 * sim_viscosity + 0.5;
        sim.compute_ubo.collision_frequency = 1 / sim_relaxation_rate;
    }

    void updateWallVelocity() {
        //float speed_of_sound_squared = sim.speed_of_sound * sim.speed_of_sound;
        sim.compute_ubo.wall_velocity_soss = sim_wall_velocity * 3.0f;// / speed_of_sound_squared;
    }

    void updateViscosity() {
        //sim_viscosity = sim.speed_of_sound * sim.speed_of_sound * ( sim_relaxation_rate / sim.unit_temporal - 0.5 );
        sim_viscosity = 1.0 / 6 * ( 2 * sim_relaxation_rate - 1 );
    }

    void lowSimSettings( float wall_velocity, float relaxation_rate ) {
        sim_wall_velocity = wall_velocity;
        updateWallVelocity;
        sim.compute_ubo.wall_thickness = 3;
        sim_relaxation_rate = relaxation_rate;
        sim.compute_ubo.collision_frequency = 1 / sim_relaxation_rate;
        updateViscosity;
        updateComputeUBO;
        if( sim.collision != Sim_State.Collision.CSC_DRAG ) {
            sim.collision  = Sim_State.Collision.CSC_DRAG;
            app.createBoltzmannPSO( false, true, false );
        }
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

    void showTooltip( string_z text, float wrap_position = 300 ) {
        //ImGui.TextDisabled("(?)");    // this should be called before showTooltip so we can customize it
        if( ImGui.IsItemHovered ) {
            ImGui.BeginTooltip;
            ImGui.PushTextWrapPos( wrap_position );
            ImGui.TextUnformatted( text );
            ImGui.PopTextWrapPos;
            ImGui.EndTooltip;
        }
    }


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

    auto scale_win_pos              = ImVec2( 1540, 710 );
    immutable auto scale_win_size   = ImVec2(   60,  20 );

    immutable auto button_size_1    = ImVec2( 344, 20 );
    immutable auto button_size_2    = ImVec2( 176, 20 );
    immutable auto button_size_3    = ImVec2( 112, 20 );
    immutable auto button_size_4    = ImVec2(  85, 20 );

    immutable auto disabled_text    = ImVec4( 0.4, 0.4, 0.4, 1 );

    ubyte   device_count = 1;       // initialize with one being the CPU
    char*   device_names;           // store all names of physical devices consecutively
    int     compute_device = 1;     // select compute device, 0 = CPU


    //
    // collect available devices
    //
    void getAvailableDevices() {

        // This code here is a stub, as we have no opportunity to test on systems with multiple devices
        // Only the device which was selected in module initialize will be listed here
        // Selection is based on ability to present a swapchain while a discrete gpu is prioritized

        // get available devices, store their names concatenated in private devices pointer
        // with this we can list them in an ImGui.Combo and make them selectable
        size_t devices_char_count = 4;
        auto gpus = this.instance.listPhysicalDevices( false );
        device_count += cast( ubyte )gpus.length;
        //devices_char_count += device_count * size_t.sizeof;  // sizeof( some_pointer );

        import core.stdc.string : strlen;

        /*  // Use this loop to list all available vulkan devices
        foreach( ref gpu; gpus ) {
            devices_char_count += strlen( gpu.listProperties.deviceName.ptr ) + 1;
        }
        /*/ // Use this code to append the selected device in module initialize
        devices_char_count += strlen( this.gpu.listProperties.deviceName.ptr ) + 1;
        //*/

        import core.stdc.stdlib : malloc;
        device_names = cast( char* )malloc( devices_char_count + 1 );   // + 1 for second terminating zero
        device_names[ 0 .. 4 ] = "CPU\0";

        char* device_name_target = device_names + 4;    // offset and store the device names pointer with 4 chars for CPU\0
        import core.stdc.string : strcpy;

        /*  // Use this loop to append all device names to the device_names char pointer
        foreach( ref gpu; gpus ) {
            strcpy( device_name_target, gpu.listProperties.deviceName.ptr );
            device_name_target += strlen( gpu.listProperties.deviceName.ptr ) + 1;
        }
        /*/ // Use this code to append the device name of the selected device in module initialize
        strcpy( device_name_target, this.gpu.listProperties.deviceName.ptr );
        device_name_target += strlen( this.gpu.listProperties.deviceName.ptr ) + 1;
        //*/


        // even though the allocated memory range seems to be \0 initialized we set the last char to \0 to be sure
        device_names[ devices_char_count ] = '\0';  // we allocated devices_char_count + 1, hence no -1 required
    }


    //
    // store available shader names concatenated and pointer into it as dynamic arrays
    //
    DArray!string_z shader_names_ptr;
    DArray!char     shader_names_combined;


    // any of the following will be set to size_t max
    // if no shader of corresponding type is found
    int init_shader_start_index = 0;
    int loop_shader_start_index;
    int draw_shader_start_index;
    int port_shader_start_index;

    // directory shader file index realative to shader_start_indexes
    int init_shader_index = 3; // 0;  // 0-based default init shader index, from all shaders in shader dir starting with init
    int loop_shader_index = 5; // 1;  // 0-based default loop shader index, from all shaders in shader dir starting with loop
    int port_shader_index = 0;


    // parse shader directory
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
            .toPtrArray!( DArray!string_z, DArray!char )( shader_names_ptr, shader_names_combined, '\0' );


        // if shader_names_combined reallocates, shader_names_ptr has invalid pointers afterward
        // hence we cast each pointer to the distance to his successor
        // the last appending operation will have valid pointers and we can use the
        // distances to reconstruct the correct pointers

        // store the last valid start pointer
        string_z last_start_pointer = null;
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
            init_shader_start_index = typeof( init_shader_start_index ).max;


        //
        // append loop shader
        //
        loop_shader_start_index = cast( typeof( loop_shader_start_index ))dirEntries( path_to_dir, SpanMode.shallow )
            .filter!( f => f.name.startsWith( "shader\\loop_" ))
            .filter!( f => f.name.endsWith( ".comp" ))
            .map!( f => f.name.stripExtension )
            .array
            .toPtrArray!( DArray!string_z, DArray!char )( shader_names_ptr, shader_names_combined, '\0' );

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
            loop_shader_start_index = typeof( loop_shader_start_index ).max;


        //
        // append draw display shader
        //
        draw_shader_start_index = cast( typeof( draw_shader_start_index ))dirEntries( path_to_dir, SpanMode.shallow )
            .filter!( f => f.name.startsWith( "shader\\display_" ))
            .filter!( f => f.name.endsWith( ".frag" ))
            .map!( f => f.name.stripExtension )
            .array
            .toPtrArray!( DArray!string_z, DArray!char )( shader_names_ptr, shader_names_combined, '\0' );


        // store the last valid start pointer
        if( last_shader_count  < shader_names_ptr.length ) {
            last_start_pointer = shader_names_ptr[ last_shader_count ];

            // get distances of draw display shaders
            foreach( i, ptr; shader_names_ptr.data[ last_shader_count + 1 .. $ ] )
                shader_names_ptr[ last_shader_count + i ] = cast( string_z )( ptr - shader_names_ptr[ last_shader_count + i ] );
            shader_names_ptr[ $ - 1 ] = cast( const( char* ))( & shader_names_combined[ $ - 1 ] + 1 - shader_names_ptr[ $ - 1 ] );

            // store the current shader count, should be the same as draw_shader_start_index
            last_shader_count = shader_names_ptr.length;
        } else
            draw_shader_start_index = typeof( draw_shader_start_index ).max;

        //
        // append export shader
        //
        port_shader_start_index = cast( typeof( port_shader_start_index ))dirEntries( path_to_dir, SpanMode.shallow )
            .filter!( f => f.name.startsWith( "shader\\export_" ))
            .filter!( f => f.name.endsWith( ".comp" ))
            .map!( f => f.name.stripExtension )
            .array
            .toPtrArray!( DArray!string_z, DArray!char )( shader_names_ptr, shader_names_combined, '\0' );

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
            port_shader_start_index = typeof( port_shader_start_index ).max;

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

    // compare shader names of currently used shader and currently selected shader
    bool compareShaderNamesAndReplace( string_z gui_shader, char* sim_shader ) {
		import core.stdc.string : strncmp, strlen;
		size_t gui_shader_length = gui_shader.strlen;

		bool equal = strncmp( gui_shader, sim_shader, gui_shader_length ) == 0;
        if( !equal ) {

			// We intend to copy the gui_shader string_z to the sim_shader string_z,
			// which is backed by char[64] storage while the former excludes its extension
			// We first must copy the extension stored in sim_shader to its new location
			// which happens to be at gui_shader_length
			// we now must be careful to not overwrite the extension itself while copying it
			// if gui_shader_length > sim_shader extension start we copy by char forward
			// if gui_shader_length < sim_shader extension start we copy by char backwards
			// else extension can stay where it is, and we just need to copy gui_shader chars

			size_t sim_shader_length = sim_shader.strlen;
			size_t extension_start;

			// find index of last '.' character in sim_shader
			foreach_reverse( i, c; sim_shader[ 0 .. sim_shader_length ] ) {
				if( c == '.' ) {
					extension_start = i;
					break;
				}
			}

			// prepare data for copy operation
			size_t extension_length = sim_shader_length - extension_start;
			char[] old_extension = sim_shader[ extension_start .. sim_shader_length ];
			char[] new_extension = sim_shader[ gui_shader_length .. gui_shader_length + extension_length ];

			// now copy the extension to its proper location
			if( gui_shader_length < extension_start )
				foreach( i; 0 .. extension_length )
					new_extension[ i ] = old_extension[ i ];
			else if( gui_shader_length > extension_start )
				foreach_reverse( i; 0 .. extension_length )
					new_extension[ i ] = old_extension[ i ];

			// finally we copy the gui_shader (base name) into the sim_shader location infront of the
			// new extension location and also add a terminating '\0' character after the extension
			sim_shader[ 0 .. gui_shader_length ] = gui_shader[ 0 .. gui_shader_length ];
			sim_shader[ gui_shader_length + extension_length ] = '\0';


            printf( "%s\n", sim_shader );
		}
        return equal;
    }

    // get the directory shader file index of passed in shader relative to a certain shader start index
    int getShaderFileIndexFromName( string_z sim_shader, string_z[] gui_shaders ) {
        import core.stdc.string : strncmp, strlen;
        foreach( i, gui_shader; gui_shaders ) {
            size_t gui_shader_length = gui_shader.strlen;
            if( strncmp( gui_shader, sim_shader, gui_shader_length ) == 0 ) {
                return cast( int )i;
            }
        }
        return 0;
    }

    // detect if shader directory was modified
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
}



//
// create vulkan related command and synchronization objects and data updated for gui usage //
//
void createCommandObjects( ref Gui_State gui ) {
    resources.createCommandObjects( gui, VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT );
}



//
// create simulation and gui related memory objects //
//
void createMemoryObjects( ref Gui_State gui ) {

    // first forward to resources.allocateResources
    resources.createMemoryObjects( gui );

    // get imgui font atlas data
    ubyte* pixels;
    int width, height;
    auto io = & ImGui.GetIO();
    io.Fonts.GetTexDataAsRGBA32( & pixels, & width, & height );
    size_t upload_size = width * height * 4 * ubyte.sizeof;

    // create upload buffer and upload the data
    auto stage_buffer = Meta_Buffer( gui )
        .usage( VK_BUFFER_USAGE_TRANSFER_SRC_BIT )
        .bufferSize( upload_size )
        .construct( VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT )
        .copyData( pixels[ 0 .. upload_size ] );

    // create image, image view abd sampler to sample the font atlas texture
    auto meta_gui_font_tex = Meta_Image_Memory_Sampler( gui )
        .format( VK_FORMAT_R8G8B8A8_UNORM )
        .extent( width, height )
        .addUsage( VK_IMAGE_USAGE_SAMPLED_BIT )
        .addUsage( VK_IMAGE_USAGE_TRANSFER_DST_BIT )

        // combines construct image, allocate required memory, construct image view and sampler (can be called separetelly)
        .construct( VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT )

        // extract instead of reset to keep the temp Meta_Image_Memory_Sampler to use some its extended properties, in this function scope only
        .extractCore( gui.gui_font_tex );

    // use one command buffer for device resource initialization
    auto cmd_buffer = gui.allocateCommandBuffer( gui.cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY );
    auto cmd_buffer_bi = createCmdBufferBI( VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT );
    vkBeginCommandBuffer( cmd_buffer, & cmd_buffer_bi );

    // record image layout transition to VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
    cmd_buffer.recordTransition(
        gui.gui_font_tex.image,
        meta_gui_font_tex.subresourceRange,
        VK_IMAGE_LAYOUT_UNDEFINED,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        0,  // no access mask required here
        VK_ACCESS_TRANSFER_WRITE_BIT,
        VK_PIPELINE_STAGE_HOST_BIT,
        VK_PIPELINE_STAGE_TRANSFER_BIT );

    // record a buffer to image copy
    auto subresource_range = meta_gui_font_tex.subresourceRange;
    VkBufferImageCopy buffer_image_copy = {
        imageSubresource: {
            aspectMask      : subresource_range.aspectMask,
            baseArrayLayer  : subresource_range.baseArrayLayer,
            layerCount      : subresource_range.layerCount },
        imageExtent     : meta_gui_font_tex.extent,
    };
    cmd_buffer.vkCmdCopyBufferToImage( stage_buffer.buffer, meta_gui_font_tex.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, & buffer_image_copy );

    // record image layout transition to VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
    cmd_buffer.recordTransition(
        meta_gui_font_tex.image,
        meta_gui_font_tex.image_view_ci.subresourceRange,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        VK_ACCESS_TRANSFER_WRITE_BIT,
        VK_ACCESS_SHADER_READ_BIT,
        VK_PIPELINE_STAGE_TRANSFER_BIT,
        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT );


    // store the texture id in imgui io struct
    io.Fonts.TexID = cast( void* )( gui.gui_font_tex.image );

    // finish recording
    cmd_buffer.vkEndCommandBuffer;

    // submit info stays local in this function scope
    auto submit_info = cmd_buffer.queueSubmitInfo;

    // submit the command buffer with one depth and one color image transitions
    gui.graphics_queue.vkQueueSubmit( 1, & submit_info, VK_NULL_HANDLE ).vkAssert;

    // wait on finished submission befor destroying the staging buffer
    gui.graphics_queue.vkQueueWaitIdle;   // equivalent using a fence per Spec v1.0.48
    stage_buffer.destroyResources;

    // command pool will be reset in resources.resizeRenderResources
    //gui.device.vkResetCommandPool( gui.cmd_pool, 0 ); // second argument is VkCommandPoolResetFlags
}



//
// create simulation and gui related descriptor set //
//
void createDescriptorSet( ref Gui_State gui ) {

    // start configuring descriptor set, pass the temporary meta_descriptor
    // as a pointer to references.createDescriptorSet, where additional
    // descriptors will be added, the set constructed and stored in
    // app.descriptor of type Core_Descriptor

    auto meta_descriptor = Meta_Descriptor_T!(9,3,8,4,3,2)( gui )
        .addImmutableSamplerImageBinding( 1, VK_SHADER_STAGE_FRAGMENT_BIT )
        .addSamplerImage( gui.gui_font_tex.sampler, gui.gui_font_tex.view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL );

    // forward to appstate createDescriptorSet with the currently being configured meta_descriptor
    resources.createDescriptorSet_T( gui, meta_descriptor );
}



//
// create appstate and gui related render resources //
//
void createRenderResources( ref Gui_State gui ) {

    // first forward to resources.createRenderResources
    resources.createRenderResources( gui );

    // create pipeline for gui rendering
    gui.gui_graphics_pso = Meta_Graphics_T!(2,1,3,1,1,1,2,1,1)( gui )
        .addShaderStageCreateInfo( gui.createPipelineShaderStage( "shader/imgui.vert" ))// auto-detect shader stage through file extension
        .addShaderStageCreateInfo( gui.createPipelineShaderStage( "shader/imgui.frag" ))// auto-detect shader stage through file extension
        .addBindingDescription( 0, ImDrawVert.sizeof, VK_VERTEX_INPUT_RATE_VERTEX )     // add vertex binding and attribute descriptions
        .addAttributeDescription( 0, 0, VK_FORMAT_R32G32_SFLOAT,  0 )                   // interleaved attributes of ImDrawVert ...
        .addAttributeDescription( 1, 0, VK_FORMAT_R32G32_SFLOAT,  ImDrawVert.uv.offsetof  )
        .addAttributeDescription( 2, 0, VK_FORMAT_R8G8B8A8_UNORM, ImDrawVert.col.offsetof )
        .inputAssembly( VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST )                           // set the input assembly
        .addViewportAndScissors( VkOffset2D( 0, 0 ), gui.swapchain.image_extent )       // add viewport and scissor state, necessary even if we use dynamic state
        .cullMode( VK_CULL_MODE_NONE )                                                  // set rasterization state cull mode
        .depthState                                                                     // set depth state - enable depth test with default attributes
        .addColorBlendState( VK_TRUE )                                                  // color blend state - append common (default) color blend attachment state
        .addDynamicState( VK_DYNAMIC_STATE_VIEWPORT )                                   // add dynamic states viewport
        .addDynamicState( VK_DYNAMIC_STATE_SCISSOR )                                    // add dynamic states scissor
        .addDescriptorSetLayout( gui.descriptor.descriptor_set_layout )                 // describe pipeline layout
        .addPushConstantRange( VK_SHADER_STAGE_VERTEX_BIT, 0, 16 )                      // specify push constant range
        .renderPass( gui.render_pass_bi.renderPass )                                    // describe compatible render pass
        .construct                                                                      // construct the PSO
        .destroyShaderModules                                                           // shader modules compiled into pipeline, not shared, can be deleted now
        .reset;

    debug {
        gui.setDebugName( gui.gui_graphics_pso.pipeline,        "Gui Graphics Pipeline" );
        gui.setDebugName( gui.gui_graphics_pso.pipeline_layout, "Gui Graphics Pipeline Layout" );
    }
}


//
// register glfw callbacks //
//
void registerCallbacks( ref Gui_State gui ) {

    // first forward to input.registerCallbacks
    import input : input_registerCallbacks = registerCallbacks;
    input_registerCallbacks( gui.app ); // here we use gui.app to ensure that only the wrapped VDrive State struct becomes the user pointer

    // now overwrite some of the input callbacks (some of them also forward to input callbacks)
    glfwSetWindowSizeCallback(  gui.window, & guiWindowSizeCallback );
    glfwSetMouseButtonCallback( gui.window, & guiMouseButtonCallback );
    glfwSetCursorPosCallback(   gui.window, & guiCursorPosCallback );
    glfwSetScrollCallback(      gui.window, & guiScrollCallback );
    glfwSetCharCallback(        gui.window, & guiCharCallback );
    glfwSetKeyCallback(         gui.window, & guiKeyCallback );
}



//
// (re)create window size dependent resources //
//
void resizeRenderResources( ref Gui_State gui, VkPresentModeKHR request_present_mode = VK_PRESENT_MODE_MAX_ENUM_KHR ) {
    // forward to appstate resizeRenderResources
    resources.resizeRenderResources( gui, request_present_mode );

    // if we use gui (default) than resources.createResizedCommands is not being called
    // there we would have reset the command pool which was used to initialize GPU memory objects
    // hence we reset it now here and rerecord the two command buffers each frame

    // reset the command pool to start recording drawing commands
    gui.graphics_queue.vkQueueWaitIdle;   // equivalent using a fence per Spec v1.0.48
    gui.device.vkResetCommandPool( gui.cmd_pool, 0 ); // second argument is VkCommandPoolResetFlags

    // allocate swapchain image count command buffers
    gui.allocateCommandBuffers( gui.cmd_pool, gui.cmd_buffers[ 0 .. gui.swapchain.image_count ] );

    debug {
        // set debug name of each command buffer in use
        import core.stdc.stdio : sprintf;
        char[ 24 ] debug_name = "Gui Command Buffer ";
        foreach( i; 0 .. gui.swapchain.image_count ) {
            sprintf( debug_name.ptr + 19, "%u", i );
            gui.setDebugName( gui.cmd_buffers[ i ], debug_name.ptr );
        }
    }

    // as we have reset the command pool, we must allocate the particle reset command buffer
    gui.createParticleResetCmdBuffer;

    // gui io display size from swapchain extent
    auto io = & ImGui.GetIO();
    io.DisplaySize = ImVec2( gui.windowWidth, gui.windowHeight );
}



//
// (re)create draw loop commands, convenienece forwarding to module resources //
//
void createResizedCommands( ref Gui_State gui ) {
    // forward to appstate createResizedCommands
    resources.createResizedCommands( gui );
}



//
// exit destroying all resources //
//
void destroyResources( ref Gui_State gui ) {

    // forward to appstate destroyResources, this also calls device.vkDeviceWaitIdle;
    resources.destroyResources( gui );

    // now destroy all remaining gui resources
    foreach( ref draw_buffer; gui.gui_draw_buffers )
        gui.vk.destroy( draw_buffer );


    // descriptor set and layout is destroyed in module resources
    gui.destroy( gui.cmd_pool );
    gui.destroy( gui.gui_graphics_pso );
    gui.destroy( gui.gui_font_tex );

    import core.stdc.stdlib : free;
    free( gui.device_names );

    ImGui.Shutdown;
}



//
// callback for C++ ImGui lib, in particular draw function //
//

extern( C++ ):

//
// main rendering function which draws all data including gui //
//
void drawGuiData( ImDrawData* draw_data ) {

    // get Gui_State pointer from ImGuiIO.UserData
    auto gui = cast( Gui_State* )( & ImGui.GetIO()).UserData;
    uint32_t next_image_index = gui.next_image_index;

    //
    // begin command buffer recording
    //

    // first attach the swapchain image related framebuffer to the render pass
    gui.render_pass_bi.framebuffer = gui.framebuffers[ next_image_index ];

    // convenience copy
    auto cmd_buffer = gui.cmd_buffers[ next_image_index ];

    // begin the command buffer
    VkCommandBufferBeginInfo cmd_buffer_bi = { flags : VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    cmd_buffer.vkBeginCommandBuffer( & cmd_buffer_bi );


    //
    // Copy CPU buffer data to the gpu image
    //
    if( gui.use_cpu && ( *gui ).isPlaying ) {

        // record image layout transition to VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
        cmd_buffer.recordTransition(
            gui.sim.macro_image.image,
            gui.cpu.sim_macro_image_subresourceRange,
            VK_IMAGE_LAYOUT_GENERAL,
            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            VK_ACCESS_SHADER_READ_BIT,
            VK_ACCESS_TRANSFER_WRITE_BIT,
            VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            VK_PIPELINE_STAGE_TRANSFER_BIT,
        );

        // record a buffer to image copy
        VkBufferImageCopy buffer_image_copy = {
            imageSubresource: {
                aspectMask      : gui.cpu.sim_macro_image_subresourceRange.aspectMask,
                baseArrayLayer  : 0,
                layerCount      : 1 },
            imageExtent     : gui.cpu.sim_macro_image_extent,
        };
        cmd_buffer.vkCmdCopyBufferToImage( gui.cpu.sim_stage_buffer.buffer, gui.sim.macro_image.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, & buffer_image_copy );

        // record image layout transition to VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
        cmd_buffer.recordTransition(
            gui.sim.macro_image.image,
            gui.cpu.sim_macro_image_subresourceRange,
            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            VK_IMAGE_LAYOUT_GENERAL,
            VK_ACCESS_TRANSFER_WRITE_BIT,
            VK_ACCESS_SHADER_READ_BIT,
            VK_PIPELINE_STAGE_TRANSFER_BIT,
            VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT
        );
    }


    // begin the render pass
    cmd_buffer.vkCmdBeginRenderPass( & gui.render_pass_bi, VK_SUBPASS_CONTENTS_INLINE );

    /*
    //
    // bind gui pipeline - we know that this is the last activated pipeline, so we don't need to use bindPipeline any more and bind it directly
    //
    cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_GRAPHICS, gui.gui_graphics_pso.pipeline );

    // bind vertex and index buffer
    VkDeviceSize vertex_offset = 0;
    cmd_buffer.vkCmdBindVertexBuffers( 0, 1, & gui.gui_draw_buffers[ next_image_index ].buffer, & vertex_offset );
    cmd_buffer.vkCmdBindIndexBuffer( gui.gui_draw_buffers[ next_image_index ].buffer, vrts_data_size, VK_INDEX_TYPE_UINT16 );

    // setup scale and translation
    float[2] scale = [ 2.0f / gui.windowWidth, 2.0f / gui.windowHeight ];
    float[2] trans = [ -1.0f, -1.0f ];
    cmd_buffer.vkCmdPushConstants( gui.gui_graphics_pso.pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT,            0, scale.sizeof, scale.ptr );
    cmd_buffer.vkCmdPushConstants( gui.gui_graphics_pso.pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, scale.sizeof, trans.sizeof, trans.ptr );

    // take care of remaining dynamic state
    cmd_buffer.vkCmdSetViewport( 0, 1, & gui.viewport );

    // record the command lists
    int vtx_offset = 0;
    int idx_offset = 0;
    for( int i = 0; i < draw_data.CmdListsCount; ++i ) {
        ImDrawList* cmd_list = draw_data.CmdLists[ i ];

        for( int cmd_i = 0; cmd_i < cmd_list.CmdBuffer.Size; ++cmd_i ) {
            ImDrawCmd* pcmd = & cmd_list.CmdBuffer[ cmd_i ];

            if( pcmd.UserCallback ) {
                pcmd.UserCallback( cmd_list, pcmd );
            } else {
                VkRect2D scissor;
                scissor.offset.x = cast( int32_t )( pcmd.ClipRect.x );
                scissor.offset.y = cast( int32_t )( pcmd.ClipRect.y );
                scissor.extent.width  = cast( uint32_t )( pcmd.ClipRect.z - pcmd.ClipRect.x );
                scissor.extent.height = cast( uint32_t )( pcmd.ClipRect.w - pcmd.ClipRect.y + 1 ); // TODO: + 1??????
                cmd_buffer.vkCmdSetScissor( 0, 1, & scissor );
                cmd_buffer.vkCmdDrawIndexed( pcmd.ElemCount, 1, idx_offset, vtx_offset, 0 );
            }
            idx_offset += pcmd.ElemCount;
        }
        vtx_offset += cmd_list.VtxBuffer.Size;
    }


    */
    // take care of remaining dynamic state
    cmd_buffer.vkCmdSetViewport( 0, 1, & gui.viewport );
    cmd_buffer.vkCmdSetScissor(  0, 1, & gui.scissors );


    //
    // avoid rerecording binding of identical pipelines
    //

    // initialize current pso with default values, a bind pipeline command will be recorded only if the current pso differs from the new pso
    gui.current_pso = Core_Pipeline.init;

    // helper function which checks if the new pipeline is the same as the last bound one
    void bindPipeline( ref Core_Pipeline pso ) {    // bind pipeline helper
        if( gui.current_pso != pso ) {
            gui.current_pso  = pso;
            cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_GRAPHICS, gui.current_pso.pipeline );

            // bind descriptor set - we should not have to rebind this for other pipelines as long as the pipeline layouts are compatible, but validation layers claim otherwise
            cmd_buffer.vkCmdBindDescriptorSets(         // VkCommandBuffer              commandBuffer
                VK_PIPELINE_BIND_POINT_GRAPHICS,        // VkPipelineBindPoint          pipelineBindPoint
                pso.pipeline_layout,                    // VkPipelineLayout             layout
                0,                                      // uint32_t                     firstSet
                1,                                      // uint32_t                     descriptorSetCount
                & gui.descriptor.descriptor_set,        // const( VkDescriptorSet )*    pDescriptorSets
                0,                                      // uint32_t                     dynamicOffsetCount
                null                                    // const( uint32_t )*           pDynamicOffsets
            );
        }
    }



    //
    // bind lbmd graphics pso which was assigned to current pso before
    //
    if( gui.vis.draw_display ) {
        bindPipeline( gui.vis.display_pso );

        // push constant the sim display scale
        cmd_buffer.vkCmdPushConstants( gui.current_pso.pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, 2 * uint32_t.sizeof, gui.sim.domain.ptr );

        // buffer-less draw with build in gl_VertexIndex exclusively to generate position and tex_coord data
        cmd_buffer.vkCmdDraw( 4, 1, 0, 0 ); // vertex count, instance count, first vertex, first instance
    }



    //
    // bind lbmd data scale pso
    //
    if( gui.vis.draw_scale && gui.vis.display_property != Vis_State.Property.VEL_GRAD ) {
        bindPipeline( gui.vis.scale_pso );

        // push constant the sim display scale
        cmd_buffer.vkCmdPushConstants( gui.current_pso.pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, 2 * float.sizeof, gui.recip_window_size.ptr );

        // buffer-less draw with build in gl_VertexIndex exclusively to generate position and tex_coord data
        cmd_buffer.vkCmdDraw( 4, 1, 0, 0 ); // vertex count, instance count, first vertex, first instance
    }




    //
    // set push constants and record draw commands for axis drawing
    //

    bool line_width_recorded = false;
    if( gui.draw_axis ) {
        bindPipeline( gui.vis.lines_pso[ 0 ] );
        gui.vis_line_display.line_type = gui.Line_Type.axis;

        if( gui.feature_wide_lines ) {
            cmd_buffer.vkCmdSetLineWidth( 1 );
            line_width_recorded = true;
        }

        // Recent VulkanSDK 1.2.162.1 Debug Utils complaint about the push constants not being initialized. Hence we update it fully now.
        cmd_buffer.vkCmdPushConstants( gui.current_pso.pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, Gui_State.Vis_Line_Display.sizeof, & gui.vis_line_display );
        cmd_buffer.vkCmdDraw( 2, 3, 0, 0 ); // vertex count, instance count, first vertex, first instance
    }


    //
    // set push constants and record draw commands for grid drawing
    //
    if( gui.draw_grid ) {
        bindPipeline( gui.vis.lines_pso[ 0 ] );
        gui.vis_line_display.line_type = gui.Line_Type.grid;

        if( gui.feature_wide_lines && !line_width_recorded ) {
            cmd_buffer.vkCmdSetLineWidth( 1 );
        }

        // draw lines repeating in X direction
        gui.vis_line_display.line_axis = gui.Line_Axis.X;
        cmd_buffer.vkCmdPushConstants( gui.current_pso.pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, Gui_State.Vis_Line_Display.sizeof, & gui.vis_line_display );
        cmd_buffer.vkCmdDraw( 2, gui.sim_domain[0] + 1, 0, 0 );     // vertex count, instance count, first vertex, first instance

        // draw lines repeating in Y direction
        gui.vis_line_display.line_axis = gui.Line_Axis.Y;
        cmd_buffer.vkCmdPushConstants( gui.current_pso.pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, gui.vis_line_display.line_type.offsetof, uint32_t.sizeof, & gui.vis_line_display.line_type );
        cmd_buffer.vkCmdDraw( 2, gui.sim_domain[1] + 1, 0, 0 );     // vertex count, instance count, first vertex, first instance
    }


    //
    // set push constants and record draw commands for boundary drawing
    //
    if( gui.draw_bounds ) {
        bindPipeline( gui.vis.lines_pso[ 0 ] );
        gui.vis_line_display.line_type = gui.Line_Type.bounds;

        //import std.stdio;
        //printf( "Sim_Dom: %d, %d, %d\n", gui.vis_line_display.sim_domain[0], gui.vis_line_display.sim_domain[1], gui.vis_line_display.sim_domain[2] );

        if( gui.feature_wide_lines ) {
            cmd_buffer.vkCmdSetLineWidth( 1 );
            line_width_recorded = true;
        }
        cmd_buffer.vkCmdPushConstants( gui.current_pso.pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, Gui_State.Vis_Line_Display.sizeof, & gui.vis_line_display );
        cmd_buffer.vkCmdDraw( 2, 4 + gui.sim_use_3_dim * 8, 0, 0 ); // vertex count, instance count, first vertex, first instance
    }



    // set point size or line width dependent on the corresponding features exist and weather line or point drawing is active
    void setPointSizeLineWidth( size_t index ) {
        if( gui.lines_as_points ) {
            if( gui.feature_large_points ) {
                gui.vis_line_display.point_size = gui.point_size_line_width[ index ];
            }
        } else {
            if( gui.feature_wide_lines ) {
                cmd_buffer.vkCmdSetLineWidth( gui.point_size_line_width[ index ] );
            }
        }
    }



    //
    // draw ghia validation profiles
    //
    if( gui.validate_ghia ) {

        //
        // setup pipeline, either lines or points drawing
        //
        bindPipeline( gui.vis.lines_pso[ gui.lines_as_points.toUint ] );
        auto pipeline_layout = gui.current_pso.pipeline_layout;


        //
        // tempory store UI Values
        //
        int             repl_count      = gui.vis_line_display.repl_count;
        gui.Line_Axis   line_axis       = gui.vis_line_display.line_axis;
        gui.Line_Axis   repl_axis       = gui.vis_line_display.repl_axis;
        gui.Line_Axis   velocity_axis   = gui.vis_line_display.velocity_axis;
        float           line_offset     = gui.vis_line_display.line_offset;


        //
        // vertical lines
        //
        gui.vis_line_display.repl_count     = cast( int )gui.ghia_type;  // choose Re
        gui.vis_line_display.line_axis      = gui.Line_Axis.Y;
        gui.vis_line_display.repl_axis      = gui.Line_Axis.X;
        gui.vis_line_display.velocity_axis  = gui.Line_Axis.X;
        gui.vis_line_display.line_offset    = 63;
        setPointSizeLineWidth( 0 );

        // push constant the whole vis_line_display struct and draw
        gui.vis_line_display.line_type = gui.Line_Type.ghia;
        cmd_buffer.vkCmdPushConstants( pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, Gui_State.Vis_Line_Display.sizeof, & gui.vis_line_display );
        cmd_buffer.vkCmdDraw( 17, 1, 0, 0 ); // vertex count, instance count, first vertex, first instance

        if( gui.validate_velocity ) {
            // adjust push constants and draw velocity line
            setPointSizeLineWidth( 1 );
            gui.vis_line_display.line_type = gui.Line_Type.vel_curves;
            cmd_buffer.vkCmdPushConstants( pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, Gui_State.Vis_Line_Display.sizeof, & gui.vis_line_display );
            cmd_buffer.vkCmdDraw( gui.sim.domain[ gui.vis_line_display.line_axis ], 1, 0, 0 ); // vertex count, instance count, first vertex, first instance
        }

        if( gui.validate_vel_base ) {
            setPointSizeLineWidth( 2 );
            // adjust push constants and draw velocity line
            gui.vis_line_display.line_type = gui.Line_Type.vel_base;
            cmd_buffer.vkCmdPushConstants( pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, Gui_State.Vis_Line_Display.sizeof, & gui.vis_line_display );
            cmd_buffer.vkCmdDraw( gui.sim.domain[ gui.vis_line_display.line_axis ], 1, 0, 0 ); // vertex count, instance count, first vertex, first instance
        }


        //
        // horizontal lines
        //
        gui.vis_line_display.line_type      = gui.Line_Type.ghia;
        gui.vis_line_display.velocity_axis  = gui.Line_Axis.Y;
        gui.vis_line_display.repl_axis      = gui.Line_Axis.Y;
        gui.vis_line_display.line_axis      = gui.Line_Axis.X;
        setPointSizeLineWidth( 0 );

        cmd_buffer.vkCmdPushConstants( pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, Gui_State.Vis_Line_Display.sizeof, & gui.vis_line_display );
        cmd_buffer.vkCmdDraw( 17, 1, 0, 0 );    // vertex count, instance count, first vertex, first instance

        if( gui.validate_velocity ) {
            // adjust push constants and draw velocity line
            setPointSizeLineWidth( 1 );
            gui.vis_line_display.line_type = gui.Line_Type.vel_curves;
            cmd_buffer.vkCmdPushConstants( pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, Gui_State.Vis_Line_Display.sizeof, & gui.vis_line_display );
            cmd_buffer.vkCmdDraw( gui.sim.domain[ gui.vis_line_display.line_axis ], 1, 0, 0 );  // vertex count, instance count, first vertex, first instance
        }

        if( gui.validate_vel_base ) {
            // adjust push constants and draw velocity base line
            setPointSizeLineWidth( 2 );
            gui.vis_line_display.line_type = gui.Line_Type.vel_base;
            cmd_buffer.vkCmdPushConstants( pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, Gui_State.Vis_Line_Display.sizeof, & gui.vis_line_display );
            cmd_buffer.vkCmdDraw( gui.sim.domain[ gui.vis_line_display.line_axis ], 1, 0, 0 );  // vertex count, instance count, first vertex, first instance
        }


        //
        // restore UI values
        //
        gui.vis_line_display.repl_count     = repl_count;
        gui.vis_line_display.line_axis      = line_axis;
        gui.vis_line_display.repl_axis      = repl_axis;
        gui.vis_line_display.velocity_axis  = velocity_axis;
        gui.vis_line_display.line_offset    = line_offset;
    }



    //
    // draw algorithmic poiseuille flow profile
    //
    if( gui.validate_poiseuille_flow ) {

        // setup pipeline, either lines or points drawing
        bindPipeline( gui.vis.lines_pso[ gui.lines_as_points.toUint ] );
        auto pipeline_layout = gui.current_pso.pipeline_layout;

        // push constant the whole vis_line_display struct and draw
        setPointSizeLineWidth( 0 );
        gui.vis_line_display.line_type = gui.Line_Type.poiseuille;
        cmd_buffer.vkCmdPushConstants( pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, Gui_State.vis_line_display.sizeof, & gui.vis_line_display );
        cmd_buffer.vkCmdDraw(
            gui.sim.domain[ gui.vis_line_display.line_axis ], gui.vis_line_display.repl_count, 0, 0 );  // vertex count, instance count, first vertex, first instance
    }



    //
    // setup velocity curves and base lines drawing
    //
    if( gui.vis_line_display.repl_count ) {

        // setup pipeline, either lines or points drawing
        bindPipeline( gui.vis.lines_pso[ gui.lines_as_points.toUint ] );
        auto pipeline_layout = gui.current_pso.pipeline_layout;

        if( gui.draw_vel_base ) {
            // push constant the whole vis_line_display struct
            setPointSizeLineWidth( 2 );
            gui.vis_line_display.line_type = gui.Line_Type.vel_base;
            cmd_buffer.vkCmdPushConstants( pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, Gui_State.vis_line_display.sizeof, & gui.vis_line_display );
            cmd_buffer.vkCmdDraw(
                gui.sim.domain[ gui.vis_line_display.line_axis ], gui.vis_line_display.repl_count, 0, 0 );  // vertex count, instance count, first vertex, first instance
        }

        // push constant the whole vis_line_display struct and draw
        setPointSizeLineWidth( 1 );
        gui.vis_line_display.line_type = gui.Line_Type.vel_curves;
        cmd_buffer.vkCmdPushConstants( pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, Gui_State.vis_line_display.sizeof, & gui.vis_line_display );
        cmd_buffer.vkCmdDraw( gui.sim.domain[ gui.vis_line_display.line_axis ], gui.vis_line_display.repl_count, 0, 0 );    // vertex count, instance count, first vertex, first instance
    }



    //
    // setup velocity lines
    //
    if( gui.draw_velocity_lines ) {
        bindPipeline( gui.vis.lines_pso[ 0 ] );
        gui.vis_line_display.line_type = gui.Line_Type.velocity;
        setPointSizeLineWidth( 1 );
        cmd_buffer.vkCmdPushConstants( gui.current_pso.pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, Gui_State.Vis_Line_Display.sizeof, & gui.vis_line_display );
        cmd_buffer.vkCmdDraw( gui.vis.particle_count * 2, 3, 0, 0 ); // vertex count, instance count, first vertex, first instance
    }


    //
    // bind particle pipeline and draw
    //
    if( gui.vis.draw_particles ) {
        bindPipeline( gui.vis.particle_pso );
        gui.vis.particle_pc.ping_pong = 1 - gui.sim.ping_pong;

        //cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_GRAPHICS, gui.vis.particle_pso.pipeline );
        cmd_buffer.vkCmdPushConstants( gui.vis.particle_pso.pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, gui.vis.particle_pc.sizeof, & gui.vis.particle_pc );
        cmd_buffer.vkCmdDraw( gui.vis.particle_count, gui.vis.particle_instance_count, 0, 0 );    // vertex count, instance count, first vertex, first instance
    }


    //
    // create gui index and vertex data buffer as one buffer, align the index buffer on 16 bytes
    //
    import vdrive.util.util : aligned;
    size_t vrts_data_size = aligned( draw_data.TotalVtxCount * ImDrawVert.sizeof, 16 );
    {
        auto draw_buffer = & gui.gui_draw_buffers[ next_image_index ];
        size_t draw_data_size = vrts_data_size + draw_data.TotalIdxCount * ImDrawIdx.sizeof;
        size_t draw_buffer_size = draw_buffer.size;
        if( draw_buffer_size < draw_data_size ) {
            gui.vk.destroy( *draw_buffer );
            Meta_Buffer_T!( Gui_State.Gui_Draw_Buffer )( gui.vk )
                .addUsage( VK_BUFFER_USAGE_VERTEX_BUFFER_BIT )
                .addUsage( VK_BUFFER_USAGE_INDEX_BUFFER_BIT )
                .bufferSize( draw_data_size + ( draw_data_size >> 4 ))  // add draw_data_size / 16 to required size so that we need to reallocate less often
                .construct( VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT )
                .mapMemory( draw_buffer.ptr )
                .reset( *draw_buffer );
        }

        // upload vertex and index data
        //draw_buffer.ptr = gui.vk.mapMemory( draw_buffer.memory );
        auto vert_ptr = cast( ImDrawVert* )( draw_buffer.ptr );
        auto elem_ptr = cast( ImDrawIdx*  )( draw_buffer.ptr + vrts_data_size );

        import core.stdc.string : memcpy;
        int cmd_lists_count = draw_data.CmdListsCount;
        for( int i = 0; i < cmd_lists_count; ++i ) {
            const ImDrawList* cmd_list = draw_data.CmdLists[ i ];
            memcpy( vert_ptr, cmd_list.VtxBuffer.Data, cmd_list.VtxBuffer.Size * ImDrawVert.sizeof );
            memcpy( elem_ptr, cmd_list.IdxBuffer.Data, cmd_list.IdxBuffer.Size * ImDrawIdx.sizeof  );
            vert_ptr += cmd_list.VtxBuffer.Size;
            elem_ptr += cmd_list.IdxBuffer.Size;
        }

        gui.vk.flushMappedMemoryRange( draw_buffer.memory );    // draw_buffer.flushMappedMemoryRange;
    }


    //
    // bind gui pipeline
    //
    bindPipeline( gui.gui_graphics_pso );

    // bind vertex and index buffer
    VkDeviceSize vertex_offset = 0;
    cmd_buffer.vkCmdBindVertexBuffers( 0, 1, & gui.gui_draw_buffers[ next_image_index ].buffer, & vertex_offset );
    cmd_buffer.vkCmdBindIndexBuffer( gui.gui_draw_buffers[ next_image_index ].buffer, vrts_data_size, VK_INDEX_TYPE_UINT16 );

    // setup scale and translation
    float[2] scale = [ 2.0f / gui.windowWidth, 2.0f / gui.windowHeight ];
    float[2] trans = [ -1.0f, -1.0f ];
    cmd_buffer.vkCmdPushConstants( gui.gui_graphics_pso.pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT,            0, scale.sizeof, scale.ptr );
    cmd_buffer.vkCmdPushConstants( gui.gui_graphics_pso.pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, scale.sizeof, trans.sizeof, trans.ptr );

    // record the command lists
    int vtx_offset = 0;
    int idx_offset = 0;
    for( int i = 0; i < draw_data.CmdListsCount; ++i ) {
        ImDrawList* cmd_list = draw_data.CmdLists[ i ];

        for( int cmd_i = 0; cmd_i < cmd_list.CmdBuffer.Size; ++cmd_i ) {
            ImDrawCmd* pcmd = & cmd_list.CmdBuffer[ cmd_i ];

            if( pcmd.UserCallback ) {
                pcmd.UserCallback( cmd_list, pcmd );
            } else {
                VkRect2D scissor;
                scissor.offset.x = cast( int32_t )( pcmd.ClipRect.x );
                scissor.offset.y = cast( int32_t )( pcmd.ClipRect.y );
                scissor.extent.width  = cast( uint32_t )( pcmd.ClipRect.z - pcmd.ClipRect.x );
                scissor.extent.height = cast( uint32_t )( pcmd.ClipRect.w - pcmd.ClipRect.y + 1 ); // TODO: + 1??????
                cmd_buffer.vkCmdSetScissor( 0, 1, & scissor );
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



//
// imgui get clipboard function pointer implementation //
//
private string_z getClipboardString( void* user_data ) {
    return glfwGetClipboardString( cast( GLFWwindow* )user_data );
}



//
// imgui set clipboard function pointer implementation //
//
private void setClipboardString( void* user_data, string_z text ) {
    glfwSetClipboardString( cast( GLFWwindow* )user_data, text );
}



//
// glfw C callbacks for C GLFW lib //
//

extern( C ) nothrow:

// Callback function for capturing mouse button events
void guiMouseButtonCallback( GLFWwindow* window, int button, int val, int mod ) {
    auto io = & ImGui.GetIO();
    auto gui = cast( Gui_State* )io.UserData; // get Gui_State pointer from ImGuiIO.UserData

    if( io.WantCaptureMouse ) {
        if( button >= 0 && button < 3 ) {
            if( val == GLFW_PRESS ) {
                gui.mouse_pressed[ button ] = true;
            } else if ( val == GLFW_RELEASE ) {
                gui.mouse_pressed[ button ] = true;
            }
        }
    } else {
        // forward to input.mouseButtonCallback
        import input : mouseButtonCallback;
        mouseButtonCallback( window, button, val, mod );
    }
}

// Callback function for capturing mouse scroll wheel events
void guiScrollCallback( GLFWwindow* window, double xoffset, double yoffset ) {
    auto io = & ImGui.GetIO();
    auto gui = cast( Gui_State* )io.UserData; // get Gui_State pointer from ImGuiIO.UserData

    if( io.WantCaptureMouse ) {
        gui.mouse_wheel += cast( float )yoffset;     // Use fractional mouse wheel, 1.0 unit 5 lines.
    } else {
        // forward to input.scrollCallback
        import input : scrollCallback;
        scrollCallback( window, xoffset, yoffset );
    }
}

// Callback function for capturing character input events
void guiCharCallback( GLFWwindow*, uint c ) {
    auto io = & ImGui.GetIO();
    if( c > 0 && c < 0x10000 ) {
        io.AddInputCharacter( cast( ImWchar )c );
    }
}

// Callback function for capturing keyboard events
void guiKeyCallback( GLFWwindow* window, int key, int scancode, int val, int mod ) {
    auto io = & ImGui.GetIO();
    io.KeysDown[ key ] = val > 0;

    // interpret KP Enter as Key Enter
    if( key == GLFW_KEY_KP_ENTER )
        io.KeysDown[ GLFW_KEY_ENTER ] = val > 0;

    //( void )mods; // Modifiers are not reliable across systems
    io.KeyCtrl  = io.KeysDown[ GLFW_KEY_LEFT_CONTROL    ] || io.KeysDown[ GLFW_KEY_RIGHT_CONTROL    ];
    io.KeyShift = io.KeysDown[ GLFW_KEY_LEFT_SHIFT      ] || io.KeysDown[ GLFW_KEY_RIGHT_SHIFT      ];
    io.KeyAlt   = io.KeysDown[ GLFW_KEY_LEFT_ALT        ] || io.KeysDown[ GLFW_KEY_RIGHT_ALT        ];
    io.KeySuper = io.KeysDown[ GLFW_KEY_LEFT_SUPER      ] || io.KeysDown[ GLFW_KEY_RIGHT_SUPER      ];

    // return here on key up events, all functionality bellow requires key up events only
    if( val == 0 ) return;

    // forward to input.keyCallback
    import input : keyCallback;
    keyCallback( window, key, scancode, val, mod );

    // if window fullscreen event happened we will not be notified, we must catch the key itself
    auto gui = cast( Gui_State* )io.UserData; // get Gui_State pointer from ImGuiIO.UserData

    if( key == GLFW_KEY_KP_ENTER && mod == GLFW_MOD_ALT ) {
        io.DisplaySize = ImVec2( gui.windowWidth, gui.windowHeight );
        gui.main_win_size.y = gui.windowHeight;       // this sets the window gui height to the window height
    } else

    // turn gui on or off with tab key
    switch( key ) {
        case GLFW_KEY_F1    : gui.draw_gui ^= 1;                                        break;
        case GLFW_KEY_F2    : gui.show_imgui_examples ^= 1;                             break;
        case GLFW_KEY_L     : try { gui.app.createLinePSO;      } catch( Exception ) {} break;
        case GLFW_KEY_D     : try { gui.app.createDisplayPSO;   } catch( Exception ) {} break;
        case GLFW_KEY_P     : try { gui.app.createParticlePSO;  } catch( Exception ) {} break;
        default             :                                                           break;
    }
}

// Callback function for capturing window resize events
void guiWindowSizeCallback( GLFWwindow * window, int w, int h ) {
    auto io = & ImGui.GetIO();
    auto gui = cast( Gui_State* )io.UserData; // get Gui_State pointer from ImGuiIO.UserData
    io.DisplaySize  = ImVec2( w, h );

    //import std.stdio;
    //printf( "WindowSize: %d, %d\n", w, h );

    gui.scale_win_pos.x = w -  60;     // set x - position of scale window
    gui.scale_win_pos.y = h - 190;     // set y - position of scale window
    gui.main_win_size.y = h;           // this sets the window gui height to the window height

    gui.recip_window_size[0] = 2.0f / w;
    gui.recip_window_size[1] = 2.0f / h;

    // the extent might change at swapchain creation when the specified extent is not usable
    gui.swapchainExtent( w, h );
    gui.window_resized = true;
}

// Callback Function for capturing mouse motion events
void guiCursorPosCallback( GLFWwindow * window, double x, double y ) {
    auto io = & ImGui.GetIO();
    //if( !io.WantCaptureMouse ) {
        // forward to input.cursorPosCallback
        import input : cursorPosCallback;
        cursorPosCallback( window, x, y );
    //}
}




