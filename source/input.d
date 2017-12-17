//module input;

import dlsl.vector;
import dlsl.trackball;
import derelict.glfw3.glfw3;

import appstate;



void registerCallbacks( ref VDrive_State app ) {
    glfwSetWindowUserPointer(   app.window, & app );
    glfwSetWindowSizeCallback(  app.window, & windowSizeCallback );
    glfwSetMouseButtonCallback( app.window, & mouseButtonCallback );
    glfwSetCursorPosCallback(   app.window, & cursorPosCallback );
    glfwSetScrollCallback(      app.window, & scrollCallback );
    glfwSetKeyCallback(         app.window, & keyCallback );
}

// wrap dlsl.Trackball and extracted glfw mouse buttons
struct TrackballButton {
    Trackball tb;
    alias tb this;
    ubyte button;
}


void initTrackball(
    ref     VDrive_State app,
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

    app.tbb.camHome;
    app.tbb.perspectiveFovyWindowHeight( perspective_fovy, window_height );
    //app.registerCallbacks;
}



void initTrackball( ref VDrive_State app ) {

    import std.math : tan;
    enum deg2rad = 0.0174532925199432957692369076849f;
    home_pos_x = - 0.5f * app.sim.domain[0];    // Todo(pp): this seems to be a bug in the trackball manipulator
    home_pos_y = - 0.5f * app.sim.domain[1];    // both the values should be positive, confirm if we are creating an inverse matrix
    home_pos_z = 0.5 / tan( 0.5 * deg2rad * app.projection_fovy );   // this is not finished yet and will be scaled bellow
    home_trg_x = home_pos_x;
    home_trg_y = home_pos_y;
    home_trg_z = 0;

    // if the aspect of the sim domain is smaller than the aspect of the window
    // we fit the height of the display plane to the window, otherwise the width of the plane
    if( cast( float )app.sim.domain[0] / app.sim.domain[1] < cast( float )app.windowWidth / app.windowHeight ) {
        home_pos_z *= app.sim.domain[1];
    } else {
        home_pos_z *= app.sim.domain[0] * cast( float )app.windowHeight / app.windowWidth;
    }

    app.tbb.camHome;
    app.tbb.perspectiveFovyWindowHeight( app.projection_fovy, app.windowHeight );
    //app.registerCallbacks;
}


/// Callback Function for capturing window resize events
extern( C ) void windowSizeCallback( GLFWwindow * window, int w, int h ) nothrow {
    // the extent might change at swapchain creation when the specified extent is not usable
    auto app = cast( VDrive_State* )window.glfwGetWindowUserPointer;
    app.swapchainExtent( w, h );
    app.window_resized = true;
}


/// Callback Function for capturing mouse motion events
extern( C ) void cursorPosCallback( GLFWwindow * window, double x, double y ) nothrow {
    auto app = cast( VDrive_State* )window.glfwGetWindowUserPointer;
    if( app.tbb.button == 0 || glfwGetKey( window, GLFW_KEY_LEFT_ALT ) != GLFW_PRESS ) return;
    switch( app.tbb.button ) {
        case 1  : /*if( app.sim_use_3_dim )*/ app.tbb.orbit( x, y ); break;
        case 2  : app.tbb.xform( x, y ); break;
        case 4  : app.tbb.dolly( x, y ); break;
        default : break;
    }
}


/// Callback Function for capturing mouse motion events
extern( C ) void mouseButtonCallback( GLFWwindow * window, int button, int val, int mod ) nothrow {
    auto app = cast( VDrive_State* )window.glfwGetWindowUserPointer;
    // compute mouse button bittfield flags
    switch( button ) {
        case 0  : app.tbb.button += 2 * val - 1; break;
        case 1  : app.tbb.button += 8 * val - 4; break;
        case 2  : app.tbb.button += 4 * val - 2; break;
        default : app.tbb.button  = 0;
    }

    if( app.tbb.button == 0 ) return;

    // set trackball reference if any mouse button is pressed
    double xpos, ypos;
    glfwGetCursorPos( window, & xpos, & ypos );
    app.tbb.reference( xpos, ypos );
}


/// Callback Function for capturing mouse wheel events
extern( C ) void scrollCallback( GLFWwindow * window, double x, double y ) nothrow {
    auto app = cast( VDrive_State* )window.glfwGetWindowUserPointer;
    app.tbb.reference( 0, 0 );
    app.tbb.dolly( 5 * x, - 10 * y );
}


/// Callback Function for capturing keyboard events
extern( C ) void keyCallback( GLFWwindow * window, int key, int scancode, int val, int mod ) nothrow {
    auto app = cast( VDrive_State* )window.glfwGetWindowUserPointer;
    // use key press results only
    if( val != GLFW_PRESS ) return;
    import visualize : resetParticleBuffer;
    import resources : createResizedCommands; 
    switch( key ) {
        case GLFW_KEY_ESCAPE    : glfwSetWindowShouldClose( window, GLFW_TRUE );        break;
        case GLFW_KEY_HOME      : app.tbb.camHome;                                        break;
        case GLFW_KEY_KP_ENTER  : if( mod == GLFW_MOD_ALT ) window.toggleFullscreen;    break;
        case GLFW_KEY_F1        : app.draw_gui ^= 1 ; (*app).createResizedCommands;       break;
        case GLFW_KEY_F5        : if( app.isPlaying ) app.simPause; else app.simPlay;      break;
        case GLFW_KEY_F6        : app.simStep;                                           break;
        case GLFW_KEY_F7        : app.simReset;                                          break;
        case GLFW_KEY_F8        : (*app).resetParticleBuffer;                            break;
        case GLFW_KEY_F9        : app.draw_particles ^= 1; (*app).createResizedCommands;  break;
        case GLFW_KEY_F12       : app.draw_display ^= 1; (*app).createResizedCommands;    break;
        default                 :                                                       break;
    }
}

private:
float home_pos_x, home_pos_y, home_pos_z;   // camera home position, defined when initializing the trackball
float home_trg_x, home_trg_y, home_trg_z;   // camera home target, same as above

bool fb_fullscreen = false;                 // keep track if we are in fullscreen mode
int win_x, win_y, win_w, win_h;             // remember position and size of window when switching to fullscreen mode

// set camera back to its initial state
void camHome( ref TrackballButton tbb ) nothrow @nogc {
    tbb.lookAt( home_pos_x, home_pos_y, home_pos_z, home_trg_x, home_trg_y, home_trg_z );
}

// toggle fullscreen state of window
void toggleFullscreen( GLFWwindow * window ) nothrow @nogc {
    if( fb_fullscreen ) {
        fb_fullscreen = false;
        glfwSetWindowMonitor( window, null, win_x, win_y, win_w, win_h, GLFW_DONT_CARE );
    } else {
        fb_fullscreen = true;
        glfwGetWindowPos(  window, & win_x, & win_y );
        glfwGetWindowSize( window, & win_w, & win_h );
        auto monitor = glfwGetPrimaryMonitor();
        auto vidmode = glfwGetVideoMode( monitor );
        glfwSetWindowPos(  window, 0, 0 );
        glfwSetWindowSize( window, vidmode.width, vidmode.height );
        glfwSetWindowMonitor( window, glfwGetPrimaryMonitor(), 0, 0, vidmode.width, vidmode.height, vidmode.refreshRate );
    }
}