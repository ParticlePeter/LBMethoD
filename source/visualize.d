
import erupted;

import vdrive;
import appstate;



/////////////////////////////////////////
// visualize state and resource struct //
/////////////////////////////////////////
struct VDrive_Visualize_State {

    // display resources
    struct Display_UBO {    // diplay ubo struct
        uint32_t            display_property    = 0;    // display param display
        float               amplify_property    = 1;    // display param amplify param
        uint32_t            color_layers        = 0;
        uint32_t            z_layer             = 0;
    } Display_UBO*      display_ubo;
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

    // pipeline cahe
    VkPipelineCache     graphics_cache;
}



/////////////////////////////////////////////////////////////////////////////////////////
// create compute pipelines and compute command buffers to initialize and simulate LBM //
/////////////////////////////////////////////////////////////////////////////////////////
void createVisResources( ref VDrive_State vd ) {
    vd.vv.graphics_cache = vd.createPipelineCache;
    vd.createDisplayPSO;        // to draw the display plane
    vd.createParticlePSO;       // particle pso to visualize influnece of velocity field
    vd.createLinePSO;           // line /  PSO to draw velocity lines coordinate axis, grid and 3D bounding box
}



/////////////////////////////////
// create display graphics PSO //
/////////////////////////////////
void createDisplayPSO( ref VDrive_State vd ) {

    // if we are recreating an old pipeline exists already, destroy it first
    if( vd.vv.display_pso.pipeline != VK_NULL_HANDLE ) {
        vd.graphics_queue.vkQueueWaitIdle;
        vd.destroy( vd.vv.display_pso );
    }

    // create the pso
    Meta_Graphics meta_graphics;
    vd.vv.display_pso = meta_graphics( vd )
        .addShaderStageCreateInfo( vd.createPipelineShaderStage( "shader/draw_display.vert" ))
        .addShaderStageCreateInfo( vd.createPipelineShaderStage( "shader/draw_display.frag" ))
        .inputAssembly( VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP )                      // set the inputAssembly
        .addViewportAndScissors( VkOffset2D( 0, 0 ), vd.swapchain.imageExtent )     // add viewport and scissor state, necessary even if we use dynamic state
        .cullMode( VK_CULL_MODE_BACK_BIT )                                          // set rasterization state
        .depthState                                                                 // set depth state - enable depth test with default attributes
        .addColorBlendState( VK_FALSE )                                             // color blend state - append common (default) color blend attachment state
        .addDynamicState( VK_DYNAMIC_STATE_VIEWPORT )                               // add dynamic states viewport
        .addDynamicState( VK_DYNAMIC_STATE_SCISSOR )                                // add dynamic states scissor
        .addDescriptorSetLayout( vd.descriptor.descriptor_set_layout )              // describe pipeline layout
        .addPushConstantRange( VK_SHADER_STAGE_VERTEX_BIT, 0, 8 )                   // specify push constant range
        .renderPass( vd.render_pass.render_pass )                                   // describe compatible render pass
        .construct( vd.vv.graphics_cache )                                             // construct the Pipleine Layout and Pipleine State Object (PSO) with a Pipeline Cache
        .destroyShaderModules                                                       // shader modules compiled into pipeline, not shared, can be deleted now
        .reset;                                                                     // extract core data into Core_Pipeline struct
}



////////////////////////////
// create particle buffer //
////////////////////////////
void createParticleBuffer( ref VDrive_State vd ) {

    // (re)create buffer and buffer view
    if( vd.vv.particle_buffer.buffer   != VK_NULL_HANDLE ) {
        vd.graphics_queue.vkQueueWaitIdle;
        vd.vv.particle_buffer.destroyResources;          // destroy old buffer
    }
    if( vd.vv.particle_buffer_view != VK_NULL_HANDLE ) {
        vd.graphics_queue.vkQueueWaitIdle;
        vd.destroy( vd.vv.particle_buffer_view );        // destroy old buffer view
    }

    uint32_t buffer_mem_size = vd.vv.particle_count * ( 4 * float.sizeof ).toUint;

    vd.vv.particle_buffer( vd )
        .create( VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_STORAGE_TEXEL_BUFFER_BIT, buffer_mem_size )
        .createMemory( VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT );

    vd.vv.particle_buffer_view =
        vd.createBufferView( vd.vv.particle_buffer.buffer, VK_FORMAT_R32G32B32A32_SFLOAT );

    // initialize buffer
    vd.createParticleResetCmdBuffer;
    vd.resetParticleBuffer;
}



/////////////////////////////////////////////////
// create particle buffer reset command buffer //
/////////////////////////////////////////////////
void createParticleResetCmdBuffer( ref VDrive_State vd ) nothrow {
    vd.vv.particle_reset_cmd_buffer = vd.allocateCommandBuffer( vd.cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY );
    vd.vv.particle_reset_cmd_buffer.vdBeginCommandBuffer;
    vd.vv.particle_reset_cmd_buffer.vkCmdFillBuffer( vd.vv.particle_buffer.buffer, 0, VK_WHOLE_SIZE, 0 );
    vd.vv.particle_reset_cmd_buffer.vkEndCommandBuffer;
}



//////////////////////////////////////////
// submit particle reset command buffer //
//////////////////////////////////////////
void resetParticleBuffer( ref VDrive_State vd ) nothrow {
    auto submit_info = vd.vv.particle_reset_cmd_buffer.queueSubmitInfo;
    vd.graphics_queue.vkQueueSubmit( 1, &submit_info, VK_NULL_HANDLE ).vkAssert;
}



/////////////////////////
// create particle PSO //
/////////////////////////
void createParticlePSO( ref VDrive_State vd ) {

    // if we are recreating an old pipeline exists already, destroy it first
    if( vd.vv.particle_pso.pipeline != VK_NULL_HANDLE ) {
        vd.graphics_queue.vkQueueWaitIdle;
        vd.destroy( vd.vv.particle_pso );
    }

    //
    // create particle pipeline
    //
    Meta_Graphics meta_graphics;
    meta_graphics( vd )
        .addShaderStageCreateInfo( vd.createPipelineShaderStage( "shader/particle.vert" ))
        .addShaderStageCreateInfo( vd.createPipelineShaderStage( "shader/particle.frag" ))
        .inputAssembly( VK_PRIMITIVE_TOPOLOGY_POINT_LIST )                          // set the inputAssembly
        .addViewportAndScissors( VkOffset2D( 0, 0 ), vd.swapchain.imageExtent )     // add viewport and scissor state, necessary even if we use dynamic state
        .cullMode( VK_CULL_MODE_BACK_BIT )                                          // set rasterization state
    //  .depthState                                                                 // set depth state - enable depth test with default attributes
        .addDynamicState( VK_DYNAMIC_STATE_VIEWPORT )                               // add dynamic states viewport
        .addDynamicState( VK_DYNAMIC_STATE_SCISSOR )                                // add dynamic states scissor
        .addDescriptorSetLayout( vd.descriptor.descriptor_set_layout )              // describe pipeline layout
        .addPushConstantRange( VK_SHADER_STAGE_VERTEX_BIT , 0, 24 )                 // specify push constant range
        .renderPass( vd.render_pass.render_pass );                                  // describe compatible render pass

    if( vd.additive_particle_blend ) {
        meta_graphics
            .setColorBlendState( VK_BLEND_FACTOR_SRC_ALPHA, VK_BLEND_FACTOR_ONE )
            .setAlphaBlendState( VK_BLEND_FACTOR_SRC_ALPHA, VK_BLEND_FACTOR_DST_ALPHA );
    } else {
        meta_graphics.addColorBlendState( VK_TRUE );
    }

    vd.vv.particle_pso = meta_graphics
        .construct( vd.vv.graphics_cache )                                          // construct the Pipleine Layout and Pipleine State Object (PSO) with a Pipeline Cache
        .destroyShaderModules                                                       // shader modules compiled into pipeline, not shared, can be deleted now
        .reset;                                                                     // extract core data into Core_Pipeline struct
}



//////////////////////////////////////////////////////////////////////////
// create line/point PSOs for velocity, axis, grid and validation lines //
//////////////////////////////////////////////////////////////////////////
void createLinePSO( ref VDrive_State vd ) {

    // if we are recreating an old pipeline exists already, destroy it first
    foreach( ref pso; vd.vv.lines_pso ) {
        if( pso.is_constructed ) {
            vd.graphics_queue.vkQueueWaitIdle;
            vd.destroy( pso );
        }
    }

    // first create PSO to draw lines
    Meta_Graphics meta_graphics;
    vd.vv.lines_pso[ 1 ] = meta_graphics( vd )
        .addShaderStageCreateInfo( vd.createPipelineShaderStage( "shader/draw_axis.vert" ))
        .addShaderStageCreateInfo( vd.createPipelineShaderStage( "shader/draw_line.frag" ))
        .inputAssembly( VK_PRIMITIVE_TOPOLOGY_POINT_LIST )                          // set the inputAssembly
        .addViewportAndScissors( VkOffset2D( 0, 0 ), vd.swapchain.imageExtent )     // add viewport and scissor state, necessary even if we use dynamic state
        .cullMode( VK_CULL_MODE_BACK_BIT )                                          // set rasterization state
    //  .depthState                                                                 // set depth state - enable depth test with default attributes
        .addColorBlendState( VK_TRUE )                                              // color blend state - append common (default) color blend attachment state
        .addDynamicState( VK_DYNAMIC_STATE_VIEWPORT )                               // add dynamic states viewport
        .addDynamicState( VK_DYNAMIC_STATE_SCISSOR )                                // add dynamic states scissor
        .addDescriptorSetLayout( vd.descriptor.descriptor_set_layout )              // describe pipeline layout
        .addPushConstantRange( VK_SHADER_STAGE_VERTEX_BIT, 0, 32 )                  // specify push constant range
        .renderPass( vd.render_pass.render_pass )                                   // describe compatible render pass
        .construct( vd.vv.graphics_cache )                                          // construct the Pipeline Layout and Pipeline State Object (PSO) with a Pipeline Cache
        .extractCore;                                                               // extract core data into Core_Pipeline struct

    // now edit the Meta_Pipeline to create an alternate points PSO
    meta_graphics.inputAssembly( VK_PRIMITIVE_TOPOLOGY_LINE_STRIP );

    if( vd.feature_wide_lines )
        meta_graphics.addDynamicState( VK_DYNAMIC_STATE_LINE_WIDTH );

    vd.vv.lines_pso[ 0 ] = meta_graphics
        .construct( vd.vv.graphics_cache )                                          // construct the Pipeline Layout and Pipeline State Object (PSO) with a Pipeline Cache
        .destroyShaderModules                                                       // shader modules compiled into pipeline, not shared, can be deleted now
        .reset;                                                                     // extract core data into Core_Pipeline struct and delete temporary data
}



//////////////////////////////
// destroy vulkan resources //
//////////////////////////////
void destroyVisResources( ref VDrive_State vd ) {

    // display resources
    vd.destroy( vd.vv.display_pso );
    vd.vv.display_ubo_buffer.destroyResources;

    // particle resources
    vd.destroy( vd.vv.particle_pso );
    vd.destroy( vd.vv.particle_buffer_view );
    vd.vv.particle_buffer.destroyResources;

    // line resources
    if( vd.vv.lines_pso[0].is_constructed ) vd.destroy( vd.vv.lines_pso[0] );
    if( vd.vv.lines_pso[1].is_constructed ) vd.destroy( vd.vv.lines_pso[1] );

    // graphics cache
    vd.destroy( vd.vv.graphics_cache );
}