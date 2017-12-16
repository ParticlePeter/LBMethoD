
import erupted;

import vdrive;
import appstate;



/////////////////////////////////////////
// visualize state and resource struct //
/////////////////////////////////////////
struct VDrive_Visualize_State {

    // display resources
    struct Display_UBO {    // diplay ubo struct
        float               amplify_property    = 1;    // display param amplify param
        uint32_t            color_layers        = 0;
        uint32_t            z_layer             = 0;
    } Display_UBO*      display_ubo;

    enum Property       : uint32_t { DENSITY, VEL_X, VEL_Y, VEL_MAG, VEL_GRAD, VEL_CURL };
    Property            display_property = Property.VEL_MAG;
    Meta_Buffer         display_ubo_buffer;
    VkMappedMemoryRange display_ubo_flush;
    Core_Pipeline       display_pso;
    
    // particle resources
    struct Particle_PC {    // push constant struct
        float[4]            point_rgba  = [ 1, 0.5, 0, 0.375 ];
        float               point_size  = 2.0f;
        float               speed_scale = 2.0f;
    } Particle_PC       particle_pc;

    uint32_t            particle_count = 400 * 225;
    Meta_Buffer         particle_buffer;
    VkBufferView        particle_buffer_view;
    VkCommandBuffer     particle_reset_cmd_buffer;
    Core_Pipeline       particle_pso;
    
    // line resources
    Core_Pipeline[2]    lines_pso;

    // scale resources
    Core_Pipeline       scale_pso;

    // pipeline cache
    VkPipelineCache     graphics_cache;
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
}



/////////////////////////////////
// create display graphics PSO //
/////////////////////////////////
void createDisplayPSO( ref VDrive_State app ) {

    // create meta_Specialization struct to specify display shader property display
    Meta_SC!( 1 ) meta_sc;
    meta_sc
        .addMapEntry( MapEntry32( cast( uint32_t )app.vis.display_property ))
        .construct;

    // if we are recreating an old pipeline exists already, destroy it first
    if( app.vis.display_pso.pipeline != VK_NULL_HANDLE ) {
        app.graphics_queue.vkQueueWaitIdle;
        app.destroy( app.vis.display_pso );
    }

    // create the pso
    Meta_Graphics meta_graphics;
    app.vis.display_pso = meta_graphics( app )
        .addShaderStageCreateInfo( app.createPipelineShaderStage( "shader/draw_display.vert" ))
        .addShaderStageCreateInfo( app.createPipelineShaderStage( "shader/draw_display.frag", & meta_sc.specialization_info ))
        .inputAssembly( VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP )                      // set the inputAssembly
        .addViewportAndScissors( VkOffset2D( 0, 0 ), app.swapchain.imageExtent )    // add viewport and scissor state, necessary even if we use dynamic state
        .cullMode( VK_CULL_MODE_BACK_BIT )                                          // set rasterization state
        .depthState                                                                 // set depth state - enable depth test with default attributes
        .addColorBlendState( VK_FALSE )                                             // color blend state - append common (default) color blend attachment state
        .addDynamicState( VK_DYNAMIC_STATE_VIEWPORT )                               // add dynamic states viewport
        .addDynamicState( VK_DYNAMIC_STATE_SCISSOR )                                // add dynamic states scissor
        .addDescriptorSetLayout( app.descriptor.descriptor_set_layout )             // describe pipeline layout
        .addPushConstantRange( VK_SHADER_STAGE_VERTEX_BIT, 0, 8 )                   // specify push constant range
        .renderPass( app.render_pass.render_pass )                                  // describe compatible render pass
        .construct( app.vis.graphics_cache )                                        // construct the Pipleine Layout and Pipleine State Object (PSO) with a Pipeline Cache
        .destroyShaderModules                                                       // shader modules compiled into pipeline, not shared, can be deleted now
        .reset;                                                                     // extract core data into Core_Pipeline struct
}



///////////////////////////////
// create scale graphics PSO //
///////////////////////////////
void createScalePSO( ref VDrive_State app ) {

    // create meta_Specialization struct to specify display shader property display
    Meta_SC!( 1 ) meta_sc;
    meta_sc
        .addMapEntry( MapEntry32( cast( uint32_t )app.vis.display_property ))
        .construct;
        
    // if we are recreating an old pipeline exists already, destroy it first
    if( app.vis.scale_pso.pipeline != VK_NULL_HANDLE ) {
        app.graphics_queue.vkQueueWaitIdle;
        app.destroy( app.vis.scale_pso );
    }

    // create the pso
    Meta_Graphics meta_graphics;
    app.vis.scale_pso = meta_graphics( app )
        .addShaderStageCreateInfo( app.createPipelineShaderStage( "shader/draw_scale.vert" ))
        .addShaderStageCreateInfo( app.createPipelineShaderStage( "shader/draw_scale.frag", & meta_sc.specialization_info ))
        .inputAssembly( VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP )                      // set the inputAssembly
        .addViewportAndScissors( VkOffset2D( 0, 0 ), app.swapchain.imageExtent )    // add viewport and scissor state, necessary even if we use dynamic state
        .cullMode( VK_CULL_MODE_BACK_BIT )                                          // set rasterization state
        .depthState                                                                 // set depth state - enable depth test with default attributes
        .addColorBlendState( VK_FALSE )                                             // color blend state - append common (default) color blend attachment state
        .addDynamicState( VK_DYNAMIC_STATE_VIEWPORT )                               // add dynamic states viewport
        .addDynamicState( VK_DYNAMIC_STATE_SCISSOR )                                // add dynamic states scissor
        .addDescriptorSetLayout( app.descriptor.descriptor_set_layout )             // describe pipeline layout
        .addPushConstantRange( VK_SHADER_STAGE_VERTEX_BIT, 0, 8 )                   // specify push constant range
        .renderPass( app.render_pass.render_pass )                                  // describe compatible render pass
        .construct( app.vis.graphics_cache )                                        // construct the Pipleine Layout and Pipleine State Object (PSO) with a Pipeline Cache
        .destroyShaderModules                                                       // shader modules compiled into pipeline, not shared, can be deleted now
        .reset;                                                                     // extract core data into Core_Pipeline struct
}



////////////////////////////
// create particle buffer //
////////////////////////////
void createParticleBuffer( ref VDrive_State app ) {

    // (re)create buffer and buffer view
    if( app.vis.particle_buffer.buffer   != VK_NULL_HANDLE ) {
        app.graphics_queue.vkQueueWaitIdle;
        app.vis.particle_buffer.destroyResources;          // destroy old buffer
    }
    if( app.vis.particle_buffer_view != VK_NULL_HANDLE ) {
        app.graphics_queue.vkQueueWaitIdle;
        app.destroy( app.vis.particle_buffer_view );        // destroy old buffer view
    }

    uint32_t buffer_mem_size = app.vis.particle_count * ( 4 * float.sizeof ).toUint;

    app.vis.particle_buffer( app )
        .create( VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_STORAGE_TEXEL_BUFFER_BIT, buffer_mem_size )
        .createMemory( VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT );

    app.vis.particle_buffer_view =
        app.createBufferView( app.vis.particle_buffer.buffer, VK_FORMAT_R32G32B32A32_SFLOAT );

    // initialize buffer
    app.createParticleResetCmdBuffer;
    app.resetParticleBuffer;
}



/////////////////////////////////////////////////
// create particle buffer reset command buffer //
/////////////////////////////////////////////////
void createParticleResetCmdBuffer( ref VDrive_State app ) nothrow {
    app.vis.particle_reset_cmd_buffer = app.allocateCommandBuffer( app.cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY );
    app.vis.particle_reset_cmd_buffer.vdBeginCommandBuffer;
    app.vis.particle_reset_cmd_buffer.vkCmdFillBuffer( app.vis.particle_buffer.buffer, 0, VK_WHOLE_SIZE, 0 );
    app.vis.particle_reset_cmd_buffer.vkEndCommandBuffer;
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

    // if we are recreating an old pipeline exists already, destroy it first
    if( app.vis.particle_pso.pipeline != VK_NULL_HANDLE ) {
        app.graphics_queue.vkQueueWaitIdle;
        app.destroy( app.vis.particle_pso );
    }

    //
    // create particle pipeline
    //
    Meta_Graphics meta_graphics;
    meta_graphics( app )
        .addShaderStageCreateInfo( app.createPipelineShaderStage( "shader/particle.vert" ))
        .addShaderStageCreateInfo( app.createPipelineShaderStage( "shader/particle.frag" ))
        .inputAssembly( VK_PRIMITIVE_TOPOLOGY_POINT_LIST )                          // set the inputAssembly
        .addViewportAndScissors( VkOffset2D( 0, 0 ), app.swapchain.imageExtent )    // add viewport and scissor state, necessary even if we use dynamic state
        .cullMode( VK_CULL_MODE_BACK_BIT )                                          // set rasterization state
    //  .depthState                                                                 // set depth state - enable depth test with default attributes
        .addDynamicState( VK_DYNAMIC_STATE_VIEWPORT )                               // add dynamic states viewport
        .addDynamicState( VK_DYNAMIC_STATE_SCISSOR )                                // add dynamic states scissor
        .addDescriptorSetLayout( app.descriptor.descriptor_set_layout )             // describe pipeline layout
        .addPushConstantRange( VK_SHADER_STAGE_VERTEX_BIT , 0, 24 )                 // specify push constant range
        .renderPass( app.render_pass.render_pass );                                 // describe compatible render pass

    if( app.additive_particle_blend ) {
        meta_graphics
            .setColorBlendState( VK_BLEND_FACTOR_SRC_ALPHA, VK_BLEND_FACTOR_ONE )
            .setAlphaBlendState( VK_BLEND_FACTOR_SRC_ALPHA, VK_BLEND_FACTOR_DST_ALPHA );
    } else {
        meta_graphics.addColorBlendState( VK_TRUE );
    }

    app.vis.particle_pso = meta_graphics
        .construct( app.vis.graphics_cache )                                        // construct the Pipleine Layout and Pipleine State Object (PSO) with a Pipeline Cache
        .destroyShaderModules                                                       // shader modules compiled into pipeline, not shared, can be deleted now
        .reset;                                                                     // extract core data into Core_Pipeline struct
}



//////////////////////////////////////////////////////////////////////////
// create line/point PSOs for velocity, axis, grid and validation lines //
//////////////////////////////////////////////////////////////////////////
void createLinePSO( ref VDrive_State app ) {

    // if we are recreating an old pipeline exists already, destroy it first
    foreach( ref pso; app.vis.lines_pso ) {
        if( pso.is_constructed ) {
            app.graphics_queue.vkQueueWaitIdle;
            app.destroy( pso );
        }
    }

    // first create PSO to draw lines
    Meta_Graphics meta_graphics;
    app.vis.lines_pso[ 1 ] = meta_graphics( app )
        .addShaderStageCreateInfo( app.createPipelineShaderStage( "shader/draw_line.vert" ))
        .addShaderStageCreateInfo( app.createPipelineShaderStage( "shader/draw_line.frag" ))
        .inputAssembly( VK_PRIMITIVE_TOPOLOGY_POINT_LIST )                          // set the inputAssembly
        .addViewportAndScissors( VkOffset2D( 0, 0 ), app.swapchain.imageExtent )    // add viewport and scissor state, necessary even if we use dynamic state
        .cullMode( VK_CULL_MODE_BACK_BIT )                                          // set rasterization state
    //  .depthState                                                                 // set depth state - enable depth test with default attributes
        .addColorBlendState( VK_TRUE )                                              // color blend state - append common (default) color blend attachment state
        .addDynamicState( VK_DYNAMIC_STATE_VIEWPORT )                               // add dynamic states viewport
        .addDynamicState( VK_DYNAMIC_STATE_SCISSOR )                                // add dynamic states scissor
        .addDescriptorSetLayout( app.descriptor.descriptor_set_layout )             // describe pipeline layout
        .addPushConstantRange( VK_SHADER_STAGE_VERTEX_BIT, 0, 32 )                  // specify push constant range
        .renderPass( app.render_pass.render_pass )                                  // describe compatible render pass
        .construct( app.vis.graphics_cache )                                        // construct the Pipeline Layout and Pipeline State Object (PSO) with a Pipeline Cache
        .extractCore;                                                               // extract core data into Core_Pipeline struct

    // now edit the Meta_Pipeline to create an alternate points PSO
    meta_graphics.inputAssembly( VK_PRIMITIVE_TOPOLOGY_LINE_STRIP );

    if( app.feature_wide_lines )
        meta_graphics.addDynamicState( VK_DYNAMIC_STATE_LINE_WIDTH );

    app.vis.lines_pso[ 0 ] = meta_graphics
        .construct( app.vis.graphics_cache )                                        // construct the Pipeline Layout and Pipeline State Object (PSO) with a Pipeline Cache
        .destroyShaderModules                                                       // shader modules compiled into pipeline, not shared, can be deleted now
        .reset;                                                                     // extract core data into Core_Pipeline struct and delete temporary data
}



//////////////////////////////
// destroy vulkan resources //
//////////////////////////////
void destroyVisResources( ref VDrive_State app ) {

    // display resources
    app.destroy( app.vis.scale_pso );
    app.destroy( app.vis.display_pso );
    app.vis.display_ubo_buffer.destroyResources;

    // particle resources
    app.destroy( app.vis.particle_pso );
    app.destroy( app.vis.particle_buffer_view );
    app.vis.particle_buffer.destroyResources;

    // line resources
    if( app.vis.lines_pso[0].is_constructed ) app.destroy( app.vis.lines_pso[0] );
    if( app.vis.lines_pso[1].is_constructed ) app.destroy( app.vis.lines_pso[1] );

    // graphics cache
    app.destroy( app.vis.graphics_cache );
}