//module input;

import dlsl.vector;
import dlsl.trackball;
import derelict.glfw3.glfw3;

import appstate;



void registerCallbacks( ref VDrive_State vd ) {
    glfwSetWindowUserPointer(   vd.window, & vd );
    glfwSetWindowSizeCallback(  vd.window, & windowSizeCallback );
    glfwSetMouseButtonCallback( vd.window, & mouseButtonCallback );
    glfwSetCursorPosCallback(   vd.window, & cursorPosCallback );
    glfwSetScrollCallback(      vd.window, & scrollCallback );
    glfwSetKeyCallback(         vd.window, & keyCallback );
}

// wrap dlsl.Trackball and extracted glfw mouse buttons
struct TrackballButton {
    Trackball tb;
    alias tb this;
    ubyte button;
}


void initTrackball(
    ref     VDrive_State vd,
    float   perspective_fovy    = 60,
    float   window_height       = 1080,
    float   cam_pos_x           =  3,
    float   cam_pos_y           =  3,
    float   cam_pos_z           = -6,
    float   cam_target_x        =  0,
    float   cam_target_y        =  0,
    float   cam_target_z        =  0,
    ) {
    home_pos_x = cam_pos_x;
    home_pos_y = cam_pos_y;
    home_pos_z = cam_pos_z;
    home_trg_x = cam_target_x;
    home_trg_y = cam_target_y;
    home_trg_z = cam_target_z;

    vd.tb.camHome;
    vd.tb.perspectiveFovyWindowHeight( perspective_fovy, window_height );
    //vd.registerCallbacks;
}



void initTrackball( ref VDrive_State vd ) {

    import std.math : tan;
    enum deg2rad = 0.0174532925199432957692369076849f;
    home_pos_x = - 0.5f * vd.vs.sim_domain[0];     // Todo(pp): this seems to be a bug in the trackball manipulator
    home_pos_y = - 0.5f * vd.vs.sim_domain[1];     // both the values should be positive, confirm if we are creating an inverse matrix
    home_pos_z = 0.5 / tan( 0.5 * deg2rad * vd.projection_fovy );   // this is not finished yet and will be scaled bellow
    home_trg_x = home_pos_x;
    home_trg_y = home_pos_y;
    home_trg_z = 0;

    // if the aspect of the sim domain is smaller than the aspect of the window
    // we fit the height of the display plane to the window, otherwise the width of the plane
    if( cast( float )vd.vs.sim_domain[0] / vd.vs.sim_domain[1] < cast( float )vd.windowWidth / vd.windowHeight ) {
        home_pos_z *= vd.vs.sim_domain[1];
    } else {
        home_pos_z *= vd.vs.sim_domain[0] * cast( float )vd.windowHeight / vd.windowWidth;
    }

    vd.tb.camHome;
    vd.tb.perspectiveFovyWindowHeight( vd.projection_fovy, vd.windowHeight );
    //vd.registerCallbacks;
}


/// Callback Function for capturing window resize events
extern( C ) void windowSizeCallback( GLFWwindow * window, int w, int h ) nothrow {
    // the extent might change at swapchain creation when the specified extent is not usable
    auto vd = cast( VDrive_State* )window.glfwGetWindowUserPointer;
    vd.swapchainExtent( w, h );
    vd.window_resized = true;
}


/// Callback Function for capturing mouse motion events
extern( C ) void cursorPosCallback( GLFWwindow * window, double x, double y ) nothrow {
    auto vd = cast( VDrive_State* )window.glfwGetWindowUserPointer;
    if( vd.tb.button == 0 || glfwGetKey( window, GLFW_KEY_LEFT_ALT ) != GLFW_PRESS ) return;
    switch( vd.tb.button ) {
        case 1  : /*if( vd.sim_use_3_dim )*/ vd.tb.orbit( x, y ); break;
        case 2  : vd.tb.xform( x, y ); break;
        case 4  : vd.tb.dolly( x, y ); break;
        default : break;
    }
}


/// Callback Function for capturing mouse motion events
extern( C ) void mouseButtonCallback( GLFWwindow * window, int button, int val, int mod ) nothrow {
    auto vd = cast( VDrive_State* )window.glfwGetWindowUserPointer;
    // compute mouse button bittfield flags
    switch( button ) {
        case 0  : vd.tb.button += 2 * val - 1; break;
        case 1  : vd.tb.button += 8 * val - 4; break;
        case 2  : vd.tb.button += 4 * val - 2; break;
        default : vd.tb.button  = 0;
    }

    if( vd.tb.button == 0 ) return;

    // set trackball reference if any mouse button is pressed
    double xpos, ypos;
    glfwGetCursorPos( window, &xpos, &ypos );
    vd.tb.reference( xpos, ypos );
}


/// Callback Function for capturing mouse wheel events
extern( C ) void scrollCallback( GLFWwindow * window, double x, double y ) nothrow {
    auto vd = cast( VDrive_State* )window.glfwGetWindowUserPointer;
    vd.tb.reference( 0, 0 );
    vd.tb.dolly( 5 * x, - 10 * y );
}


/// Callback Function for capturing keyboard events
extern( C ) void keyCallback( GLFWwindow * window, int key, int scancode, int val, int mod ) nothrow {
    auto vd = cast( VDrive_State* )window.glfwGetWindowUserPointer;
    // use key press results only
    if( val != GLFW_PRESS ) return;
    import visualize : resetParticleBuffer;
    import resources : createResizedCommands; 
    switch( key ) {
        case GLFW_KEY_ESCAPE    : glfwSetWindowShouldClose( window, GLFW_TRUE );        break;
        case GLFW_KEY_HOME      : vd.tb.camHome;                                        break;
        case GLFW_KEY_KP_ENTER  : if( mod == GLFW_MOD_ALT ) window.toggleFullscreen;    break;
        case GLFW_KEY_F1        : vd.draw_gui ^= 1 ; (*vd).createResizedCommands;       break;
        case GLFW_KEY_F5        : if( vd.isPlaying ) vd.simPause; else vd.simPlay;      break;
        case GLFW_KEY_F6        : vd.simStep;                                           break;
        case GLFW_KEY_F7        : vd.simReset;                                          break;
        case GLFW_KEY_F8        : (*vd).resetParticleBuffer;                            break;
        case GLFW_KEY_F9        : vd.draw_particles ^= 1; (*vd).createResizedCommands;  break;
        case GLFW_KEY_F12       : vd.draw_display ^= 1; (*vd).createResizedCommands;    break;
        default                 :                                                       break;
    }
}

private:
float home_pos_x, home_pos_y, home_pos_z;   // camera home position, defined when initializing the trackball
float home_trg_x, home_trg_y, home_trg_z;   // camera home target, same as above

bool fb_fullscreen = false;                 // keep track if we are in fullscreen mode
int win_x, win_y, win_w, win_h;             // remember position and size of window when switching to fullscreen mode

// set camera back to its initial state
void camHome( ref TrackballButton tb ) nothrow @nogc {
    tb.lookAt( home_pos_x, home_pos_y, home_pos_z, home_trg_x, home_trg_y, home_trg_z );
}

// toggle fullscreen state of window
void toggleFullscreen( GLFWwindow * window ) nothrow @nogc {
    if( fb_fullscreen ) {
        fb_fullscreen = false;
        glfwSetWindowMonitor( window, null, win_x, win_y, win_w, win_h, GLFW_DONT_CARE );
    } else {
        fb_fullscreen = true;
        glfwGetWindowPos(  window, &win_x, &win_y );
        glfwGetWindowSize( window, &win_w, &win_h );
        auto monitor = glfwGetPrimaryMonitor();
        auto vidmode = glfwGetVideoMode( monitor );
        glfwSetWindowPos(  window, 0, 0 );
        glfwSetWindowSize( window, vidmode.width, vidmode.height );
        glfwSetWindowMonitor( window, glfwGetPrimaryMonitor(), 0, 0, vidmode.width, vidmode.height, vidmode.refreshRate );
    }
}