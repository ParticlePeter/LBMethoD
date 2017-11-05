
import erupted;

import vdrive;
import appstate;


///////////////////////////////////////////////
// push constant struct for particle drawing //
///////////////////////////////////////////////
struct Particle_PC {
    float[4]    point_rgba = [ 1, 0.5, 0, 0.375 ];
    float       point_size  = 2.0f;
    float       speed_scale = 2.0f;
}



/// create particle buffer
void createParticleBuffer( ref VDrive_State vd ) {

    // (re)create buffer and buffer view
    if( vd.sim_particle_buffer.buffer   != VK_NULL_HANDLE ) {
        vd.graphics_queue.vkQueueWaitIdle;
        vd.sim_particle_buffer.destroyResources;          // destroy old buffer
    }
    if( vd.sim_particle_buffer_view != VK_NULL_HANDLE ) {
        vd.graphics_queue.vkQueueWaitIdle;
        vd.destroy( vd.sim_particle_buffer_view );        // destroy old buffer view
    }

    uint32_t buffer_mem_size = vd.sim_particle_count * ( 4 * float.sizeof ).toUint;

    vd.sim_particle_buffer( vd )
        .create( VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_STORAGE_TEXEL_BUFFER_BIT, buffer_mem_size )
        .createMemory( VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT );

    vd.sim_particle_buffer_view =
        vd.createBufferView( vd.sim_particle_buffer.buffer, VK_FORMAT_R32G32B32A32_SFLOAT );

    // initialize buffer
    auto init_cmd_buffer = vd.allocateCommandBuffer( vd.cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY );
    auto init_cmd_buffer_bi = createCmdBufferBI( VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT );
    init_cmd_buffer.vkBeginCommandBuffer( &init_cmd_buffer_bi );

    init_cmd_buffer.vkCmdFillBuffer( vd.sim_particle_buffer.buffer, 0, VK_WHOLE_SIZE, 0 );
    init_cmd_buffer.vkEndCommandBuffer;                     // finish recording and submit the command
    auto submit_info = init_cmd_buffer.queueSubmitInfo;     // submit the command buffer
    vd.graphics_queue.vkQueueSubmit( 1, &submit_info, VK_NULL_HANDLE ).vkAssert;
    
}






/// create particle resources
void createParticleResources( ref VDrive_State vd ) {

    vd.createParticleDrawPSO;
    //vd.createParticleCompPSO( true, true );
}



/////////////////////////
// create particle PSO //
/////////////////////////
void createParticlePSO( ref VDrive_State vd ) {

    // if we are recreating an old pipeline exists already, destroy it first
    if( vd.draw_part_pso.pipeline != VK_NULL_HANDLE ) {
        vd.graphics_queue.vkQueueWaitIdle;
        vd.destroy( vd.draw_part_pso );
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

    vd.draw_part_pso = meta_graphics
        .construct( vd.graphics_cache )                                             // construct the Pipleine Layout and Pipleine State Object (PSO) with a Pipeline Cache
        .destroyShaderModules                                                       // shader modules compiled into pipeline, not shared, can be deleted now
        .reset;                                                                     // extract core data into Core_Pipeline struct
}



/////////////////////////////////////////////
// create velocity, axis or grid lines PSO //
/////////////////////////////////////////////

void createLinePSO( ref VDrive_State vd ) {

    // if we are recreating an old pipeline exists already, destroy it first
    foreach( ref pso; vd.draw_line_pso ) {
        if( pso.is_constructed ) {
            vd.graphics_queue.vkQueueWaitIdle;
            vd.destroy( pso );
        }
    }

    // first create PSO to draw lines
    Meta_Graphics meta_graphics;
    vd.draw_line_pso[ 1 ] = meta_graphics( vd )
        .addShaderStageCreateInfo( vd.createPipelineShaderStage( "shader/draw_line.vert" ))
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
        .construct( vd.graphics_cache )                                             // construct the Pipeline Layout and Pipeline State Object (PSO) with a Pipeline Cache
        .extractCore;                                                               // extract core data into Core_Pipeline struct

    // now edit the Meta_Pipeline to create an alternate points PSO
    meta_graphics.inputAssembly( VK_PRIMITIVE_TOPOLOGY_LINE_STRIP );

    if( vd.feature_wide_lines )
        meta_graphics.addDynamicState( VK_DYNAMIC_STATE_LINE_WIDTH );

    vd.draw_line_pso[ 0 ] = meta_graphics
        .construct( vd.graphics_cache )                                             // construct the Pipeline Layout and Pipeline State Object (PSO) with a Pipeline Cache
        .destroyShaderModules                                                       // shader modules compiled into pipeline, not shared, can be deleted now
        .reset;                                                                     // extract core data into Core_Pipeline struct and delete temporary data
}



void destroyVisualizeResources( ref VDrive_State vd ) {

    // particle resources
    vd.destroy( vd.comp_part_pso );
    vd.destroy( vd.draw_part_pso );
    vd.destroy( vd.sim_particle_buffer_view );
    vd.sim_particle_buffer.destroyResources;

    // line resources
    foreach( ref pso; vd.draw_line_pso )
        if( pso.is_constructed )
            vd.destroy( pso );

}