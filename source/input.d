//module input;

import dlsl.vector;
import dlsl.trackball;
import derelict.glfw3.glfw3;

import gui;
import appstate;

private VDrive_State* vd;

void registerCallbacks( GLFWwindow* window, void* user_pointer = null ) {
    vd = cast( VDrive_State* )user_pointer;
    glfwSetWindowUserPointer( window, user_pointer );
    glfwSetWindowSizeCallback( window, &windowSizeCallback );
    glfwSetMouseButtonCallback( window, &mouseButtonCallback );
    glfwSetCursorPosCallback( window, &cursorPosCallback );
    glfwSetScrollCallback( window, &ImGui_ImplGlfwVulkan_ScrollCallback ); //&scrollCallback );
    glfwSetCharCallback( window, &ImGui_ImplGlfwVulkan_CharCallback );
    glfwSetKeyCallback( window, &keyCallback );
}

// wrap dlsl.Trackball and extracted glfw mouse buttons
struct TrackballButton {
    Trackball tb;
    alias tb this;
    ubyte button;
}


auto ref initTrackball(
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
    vd.window.registerCallbacks( &vd );
    return vd;
}


/// Callback Function for capturing window resize events
extern( C ) void windowSizeCallback( GLFWwindow * window, int w, int h ) nothrow {
    // the extent might change at swapchain creation when the specified extent is not usable
    vd.swapchainExtent( w, h );
    vd.window_resized = true;
}


/// Callback Function for capturing mouse motion events
extern( C ) void cursorPosCallback( GLFWwindow * window, double x, double y ) nothrow {
    if( vd.tb.button == 0 ) return;
    switch( vd.tb.button ) {
        //case 1  : vd.tb.orbit( x, y ); break;
        case 2  : vd.tb.xform( x, y ); break;
        case 4  : vd.tb.dolly( x, y ); break;
        default : break;
    }
}


/// Callback Function for capturing mouse motion events
extern( C ) void mouseButtonCallback( GLFWwindow * window, int key, int val, int mod ) nothrow {
    // compute mouse button bittfield flags
    switch( key ) {
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

    // forward to imgui
    ImGui_ImplGlfwVulkan_MouseButtonCallback( window, key, val, mod );

}


/// Callback Function for capturing mouse wheel events
extern( C ) void scrollCallback( GLFWwindow * window, double x, double y ) nothrow {

}


/// Callback Function for capturing keyboard events
extern( C ) void keyCallback( GLFWwindow * window, int key, int scancode, int val, int mod ) nothrow {

    // forward to imgui
    ImGui_ImplGlfwVulkan_KeyCallback( window, key, scancode, val, mod );

    // use key press results only
    if( val != GLFW_PRESS ) return;
    switch( key ) {
        case GLFW_KEY_ESCAPE    : glfwSetWindowShouldClose( window, GLFW_TRUE ); break;
        case GLFW_KEY_HOME      : vd.tb.camHome; break;
        case GLFW_KEY_KP_ENTER  : if( mod == GLFW_MOD_ALT ) window.toggleFullscreen; break;
        default : break;
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
        glfwSetWindowMonitor( window, glfwGetPrimaryMonitor(), 0, 0, vidmode.width, vidmode.height, vidmode.refreshRate );
    }
}