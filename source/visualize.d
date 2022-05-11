
import erupted;

import vdrive;
import appstate;

import settings : setting;



/////////////////////////////////////////
// visualize state and resource struct //
/////////////////////////////////////////
struct Vis_State {

    // display resources
    struct Display_UBO {        // diplay ubo struct
        float                   amplify_property    = 1;    // display param amplify param
        @setting uint32_t       color_layers        = 0;
        @setting uint32_t       z_layer             = 0;
    //  uint32_t                padding;
    //  float[3]                background_color    =
    } @setting Display_UBO* display_ubo;

    enum Property           : uint32_t { DENSITY, VEL_X, VEL_Y, VEL_MAG, VEL_GRAD, VEL_CURL, TEX_COORD };
    @setting Property       display_property = Property.VEL_MAG;
    VDrive_State.Ubo_Buffer display_ubo_buffer;
    Core_Pipeline           display_pso;

    // particle resources
    struct Particle_PC {    // push constant struct
        @setting float[4]       point_rgba  = [ 1, 0.25, 0, 1 ]; // [ 1, 0.5, 0, 0.375 ];
        @setting float          point_size  = 8.0f; // 2.0f
        @setting float          speed_scale = 2.0f;
        uint32_t                ping_pong   = 512;
    } @setting Particle_PC  particle_pc;

    Core_Pipeline           particle_pso;
    Core_Buffer_Memory_View particle_buffer;
    VkCommandBuffer         particle_reset_cmd_buffer;
    enum Particle_Type      : uint32_t { Velocity, Debug_Density, Debug_Popul };

    uint32_t                particle_count  = 400 * 225;
    uint32_t                particle_instance_count = 1;

    // line resources
    Core_Pipeline[2]        lines_pso;      // lines_pso[0] draws as lines, lines_pso[1] draws as points

    // scale resources
    Core_Pipeline           scale_pso;

    // pipeline cache
    VkPipelineCache         graphics_cache;

    @setting float          amplify_property        = 1.0f;
    @setting bool           amplify_prop_div_steps  = true;
    @setting bool           draw_scale              = true;
    @setting bool           draw_display            = true;
    @setting bool           draw_particles          = false;
    @setting bool           particle_additive_blend = false;    // true;
    @setting Particle_Type  particle_type = Particle_Type.Velocity;
}



/////////////////////////////////////////////////////////////////////////////////////////
// create compute pipelines and compute command buffers to initialize and simulate LBM //
/////////////////////////////////////////////////////////////////////////////////////////
void createVisResources( ref VDrive_State app ) {
    app.vis.graphics_cache = app.createPipelineCache;
    app.createDisplayPSO;        // to draw the display plane
    app.createScalePSO;
    app.createParticlePSO;       // particle pso to visualize influnece of velocity field
    app.createLinePSO;           // line /  PSO to draw velocity lines coordinate axis, grid and 3D bounding box

    app.vis.particle_instance_count = app.vis.particle_type == app.vis.Particle_Type.Debug_Popul
        ? app.sim.layout_value_count[ app.sim.layout ] / 2 + 1
        : 1;
}



/////////////////////////////////
// create display graphics PSO //
/////////////////////////////////
void createDisplayPSO( ref VDrive_State app ) {

    // create meta_Specialization struct to specify display shader property display
    Meta_Specialization_T!( 1 ) meta_sc;
    meta_sc
        .addMapEntry( MapEntry32( cast( uint32_t )app.vis.display_property ))
        .construct;

    // if we are recreating an old pipeline exists already, destroy it first
    if( app.vis.display_pso.pipeline != VK_NULL_HANDLE ) {
        app.graphics_queue.vkQueueWaitIdle;
        app.destroy( app.vis.display_pso );
    }

    // create the pso
    app.vis.display_pso = Meta_Graphics_T!(2,0,0,1,1,1,2,1,1)( app )
        .addShaderStageCreateInfo( app.createPipelineShaderStage( "shader/draw_display.vert" ))
        .addShaderStageCreateInfo( app.createPipelineShaderStage( "shader/draw_display.frag", & meta_sc.specialization_info ))
        .inputAssembly( VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP )                      // set the inputAssembly
        .addViewportAndScissors( VkOffset2D( 0, 0 ), app.swapchain.image_extent )   // add viewport and scissor state, necessary even if we use dynamic state
        .cullMode( VK_CULL_MODE_BACK_BIT )                                          // set rasterization state
        .depthState                                                                 // set depth state - enable depth test with default attributes
        .addColorBlendState( VK_TRUE )                                             // color blend state - append common (default) color blend attachment state
        .addDynamicState( VK_DYNAMIC_STATE_VIEWPORT )                               // add dynamic states viewport
        .addDynamicState( VK_DYNAMIC_STATE_SCISSOR )                                // add dynamic states scissor
        .addDescriptorSetLayout( app.descriptor.descriptor_set_layout )             // describe pipeline layout
        .addPushConstantRange( VK_SHADER_STAGE_VERTEX_BIT, 0, 8 )                   // specify push constant range
        .renderPass( app.render_pass_bi.renderPass )                                // describe compatible render pass
        .construct( app.vis.graphics_cache )                                        // construct the Pipleine Layout and Pipleine State Object (PSO) with a Pipeline Cache
        .destroyShaderModules                                                       // shader modules compiled into pipeline, not shared, can be deleted now
        .reset;                                                                     // extract core data into Core_Pipeline struct

    debug {
        app.setDebugName( app.vis.display_pso.pipeline,        "Display Pipeline" );
        app.setDebugName( app.vis.display_pso.pipeline_layout, "Display Pipeline Layout" );
    }
    //import std.stdio;
    //writeln( meta_graphics.static_config );
    //app.vis.display_pso = meta_graphics.destroyShaderModules.reset;
}



///////////////////////////////
// create scale graphics PSO //
///////////////////////////////
void createScalePSO( ref VDrive_State app ) {

    // create meta_Specialization struct to specify display shader property display
    Meta_Specialization_T!( 1 ) meta_sc;
    meta_sc
        .addMapEntry( MapEntry32( cast( uint32_t )app.vis.display_property ))
        .construct;

    // if we are recreating an old pipeline exists already, destroy it first
    if( app.vis.scale_pso.pipeline != VK_NULL_HANDLE ) {
        app.graphics_queue.vkQueueWaitIdle;
        app.destroy( app.vis.scale_pso );
    }

    // create the pso
    app.vis.scale_pso = Meta_Graphics_T!(2,0,0,1,1,1,2,1,1)( app )
        .addShaderStageCreateInfo( app.createPipelineShaderStage( "shader/draw_scale.vert" ))
        .addShaderStageCreateInfo( app.createPipelineShaderStage( "shader/draw_scale.frag", & meta_sc.specialization_info ))
        .inputAssembly( VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP )                      // set the inputAssembly
        .addViewportAndScissors( VkOffset2D( 0, 0 ), app.swapchain.image_extent )   // add viewport and scissor state, necessary even if we use dynamic state
        .cullMode( VK_CULL_MODE_BACK_BIT )                                          // set rasterization state
        .depthState                                                                 // set depth state - enable depth test with default attributes
        .addColorBlendState( VK_FALSE )                                             // color blend state - append common (default) color blend attachment state
        .addDynamicState( VK_DYNAMIC_STATE_VIEWPORT )                               // add dynamic states viewport
        .addDynamicState( VK_DYNAMIC_STATE_SCISSOR )                                // add dynamic states scissor
        .addDescriptorSetLayout( app.descriptor.descriptor_set_layout )             // describe pipeline layout
        .addPushConstantRange( VK_SHADER_STAGE_VERTEX_BIT, 0, 8 )                   // specify push constant range
        .renderPass( app.render_pass_bi.renderPass )                                // describe compatible render pass
        .construct( app.vis.graphics_cache )                                        // construct the Pipleine Layout and Pipleine State Object (PSO) with a Pipeline Cache
        .destroyShaderModules                                                       // shader modules compiled into pipeline, not shared, can be deleted now
        .reset;                                                                     // extract core data into Core_Pipeline struct

    debug {
        app.setDebugName( app.vis.scale_pso.pipeline,        "Scale Pipeline" );
        app.setDebugName( app.vis.scale_pso.pipeline_layout, "Scale Pipeline Layout" );
    }

    //import std.stdio;
    //writeln( meta_graphics.static_config );
    //app.vis.scale_pso = meta_graphics.destroyShaderModules.reset;
}



////////////////////////////
// create particle buffer //
////////////////////////////
void createParticleBuffer( ref VDrive_State app ) {

    // (re)create buffer and buffer view
    if(!app.vis.particle_buffer.is_null ) {
        app.graphics_queue.vkQueueWaitIdle;
        app.destroy( app.vis.particle_buffer );       // destroy old buffer and view
    }

    app.vis.particle_buffer = Meta_Buffer_Memory_View( app )
        .usage( VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_STORAGE_TEXEL_BUFFER_BIT )
        .bufferSize( app.vis.particle_count * ( 4 * float.sizeof ).toUint )
        .viewFormat( VK_FORMAT_R32G32B32A32_SFLOAT )
        .construct( VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT )
        .reset;

    // initialize buffer
    app.createParticleResetCmdBuffer;
    app.resetParticleBuffer;
}



/////////////////////////////////////////////////
// create particle buffer reset command buffer //
/////////////////////////////////////////////////
void createParticleResetCmdBuffer( ref VDrive_State app ) nothrow {
    //app.graphics_queue.vkQueueWaitIdle;
    //app.device.vkResetCommandPool( app.cmd_pool, 0 );

    app.vis.particle_reset_cmd_buffer = app.allocateCommandBuffer( app.cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY );
    app.vis.particle_reset_cmd_buffer.vdBeginCommandBuffer;
    app.vis.particle_reset_cmd_buffer.vkCmdFillBuffer( app.vis.particle_buffer.buffer, 0, VK_WHOLE_SIZE, 0 );
    app.vis.particle_reset_cmd_buffer.vkEndCommandBuffer;

    debug app.setDebugName( app.vis.particle_reset_cmd_buffer, "Particle Reset Command Buffer" );
}



//////////////////////////////////////////
// submit particle reset command buffer //
//////////////////////////////////////////
void resetParticleBuffer( ref VDrive_State app ) nothrow {
    auto submit_info = app.vis.particle_reset_cmd_buffer.queueSubmitInfo;
    app.graphics_queue.vkQueueSubmit( 1, & submit_info, VK_NULL_HANDLE ).vkAssert;
}



/////////////////////////
// create particle PSO //
/////////////////////////
void createParticlePSO( ref VDrive_State app ) {

    // create meta_Specialization struct to specify display shader property display
    Meta_Specialization_T!( 1 ) meta_sc;
    meta_sc
        .addMapEntry( MapEntry32( cast( uint32_t )app.vis.particle_type ))
        .construct;

    // if we are recreating an old pipeline exists already, destroy it first
    if( app.vis.particle_pso.pipeline != VK_NULL_HANDLE ) {
        app.graphics_queue.vkQueueWaitIdle;
        app.destroy( app.vis.particle_pso );
    }

    //
    // create particle pipeline
    //
    auto meta_graphics = Meta_Graphics_T!(2,0,0,1,1,1,2,1,1)( app )
        .addShaderStageCreateInfo( app.createPipelineShaderStage( "shader/particle.vert", & meta_sc.specialization_info ))
        .addShaderStageCreateInfo( app.createPipelineShaderStage( "shader/particle.frag" ))
        .inputAssembly( VK_PRIMITIVE_TOPOLOGY_POINT_LIST )                          // set the inputAssembly
        .addViewportAndScissors( VkOffset2D( 0, 0 ), app.swapchain.image_extent )   // add viewport and scissor state, necessary even if we use dynamic state
        .cullMode( VK_CULL_MODE_BACK_BIT )                                          // set rasterization state
    //  .depthState                                                                 // set depth state - enable depth test with default attributes
        .addDynamicState( VK_DYNAMIC_STATE_VIEWPORT )                               // add dynamic states viewport
        .addDynamicState( VK_DYNAMIC_STATE_SCISSOR )                                // add dynamic states scissor
        .addDescriptorSetLayout( app.descriptor.descriptor_set_layout )             // describe pipeline layout
        .addPushConstantRange( VK_SHADER_STAGE_VERTEX_BIT , 0, 28 )                 // specify push constant range
        .renderPass( app.render_pass_bi.renderPass );                               // describe compatible render pass

    if( app.vis.particle_additive_blend ) {
        meta_graphics
            .addColorBlendState( VK_TRUE )
            .setColorBlendState( VK_BLEND_FACTOR_SRC_ALPHA, VK_BLEND_FACTOR_ONE )
            .setAlphaBlendState( VK_BLEND_FACTOR_SRC_ALPHA, VK_BLEND_FACTOR_DST_ALPHA );
    } else {
        meta_graphics.addColorBlendState( VK_TRUE );
    }

    //import std.stdio;
    //writeln( meta_graphics.static_config );

    app.vis.particle_pso = meta_graphics
        .construct( app.vis.graphics_cache )                                        // construct the Pipleine Layout and Pipleine State Object (PSO) with a Pipeline Cache
        .destroyShaderModules                                                       // shader modules compiled into pipeline, not shared, can be deleted now
        .reset;                                                                     // extract core data into Core_Pipeline struct


    debug {
        app.setDebugName( app.vis.particle_pso.pipeline,        "Particle Pipeline" );
        app.setDebugName( app.vis.particle_pso.pipeline_layout, "Particle Pipeline Layout" );
    }
}



//////////////////////////////////////////////////////////////////////////
// create line/point PSOs for velocity, axis, grid and validation lines //
//////////////////////////////////////////////////////////////////////////
void createLinePSO( ref VDrive_State app ) {

    // if we are recreating an old pipeline exists already, destroy it first
    foreach( ref pso; app.vis.lines_pso ) {
        if(!pso.is_null ) {
            app.graphics_queue.vkQueueWaitIdle;
            app.destroy( pso );
        }
    }

    // first create PSO to draw lines
    auto meta_graphics = Meta_Graphics_T!(2,0,0,1,1,1,3,1,1)( app )
        .addShaderStageCreateInfo( app.createPipelineShaderStage( "shader/draw_line.vert" ))
        .addShaderStageCreateInfo( app.createPipelineShaderStage( "shader/draw_line.frag" ))
        .inputAssembly( VK_PRIMITIVE_TOPOLOGY_POINT_LIST )                          // set the inputAssembly
        .addViewportAndScissors( VkOffset2D( 0, 0 ), app.swapchain.image_extent )   // add viewport and scissor state, necessary even if we use dynamic state
        .cullMode( VK_CULL_MODE_BACK_BIT )                                          // set rasterization state
    //  .depthState                                                                 // set depth state - enable depth test with default attributes
        .addColorBlendState( VK_TRUE )                                              // color blend state - append common (default) color blend attachment state
        .addDynamicState( VK_DYNAMIC_STATE_VIEWPORT )                               // add dynamic states viewport
        .addDynamicState( VK_DYNAMIC_STATE_SCISSOR )                                // add dynamic states scissor
        .addDescriptorSetLayout( app.descriptor.descriptor_set_layout )             // describe pipeline layout
        .addPushConstantRange( VK_SHADER_STAGE_VERTEX_BIT, 0, 32 )                  // specify push constant range
        .renderPass( app.render_pass_bi.renderPass )                                // describe compatible render pass
        .construct( app.vis.graphics_cache );                                       // construct the Pipeline Layout and Pipeline State Object (PSO) with a Pipeline Cache

    app.vis.lines_pso[ 1 ] = meta_graphics.extractCore;                             // extract core data into Core_Pipeline struct

    // now edit the Meta_Pipeline to create an alternate points PSO
    meta_graphics.inputAssembly( VK_PRIMITIVE_TOPOLOGY_LINE_STRIP );
    meta_graphics.inputAssembly( VK_PRIMITIVE_TOPOLOGY_LINE_LIST );

    if( app.feature_wide_lines )
        meta_graphics.addDynamicState( VK_DYNAMIC_STATE_LINE_WIDTH );

    //import std.stdio;
    //writeln( meta_graphics.static_config );

    app.vis.lines_pso[ 0 ] = meta_graphics
        .construct( app.vis.graphics_cache )                                        // construct the Pipeline Layout and Pipeline State Object (PSO) with a Pipeline Cache
        .destroyShaderModules                                                       // shader modules compiled into pipeline, not shared, can be deleted now
        .reset;                                                                     // extract core data into Core_Pipeline struct and delete temporary data


    debug {
        app.setDebugName( app.vis.lines_pso[ 0 ].pipeline,        "Lines [ 0 ] as Lines Pipeline" );
        app.setDebugName( app.vis.lines_pso[ 0 ].pipeline_layout, "Lines [ 0 ] as Lines Pipeline Layout" );

        app.setDebugName( app.vis.lines_pso[ 1 ].pipeline,        "Lines [ 1 ] as Points Pipeline" );
        app.setDebugName( app.vis.lines_pso[ 1 ].pipeline_layout, "Lines [ 1 ] as Points Pipeline Layout" );
    }
}



//////////////////////////////
// destroy vulkan resources //
//////////////////////////////
void destroyVisResources( ref VDrive_State app ) {

    // display resources
    app.destroy( app.vis.scale_pso );
    app.destroy( app.vis.display_pso );
    app.destroy( app.vis.display_ubo_buffer );

    // particle resources
    app.destroy( app.vis.particle_pso );
    app.destroy( app.vis.particle_buffer );

    // line resources
    if(!app.vis.lines_pso[0].is_null ) app.destroy( app.vis.lines_pso[0] );
    if(!app.vis.lines_pso[1].is_null ) app.destroy( app.vis.lines_pso[1] );

    // graphics cache
    app.destroy( app.vis.graphics_cache );
}