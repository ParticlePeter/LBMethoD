
import erupted;

import vdrive;
import appstate;




/*  // Todo(pp): Is this usefull ??
/// create general texel buffer
void createTexelBuffer(
    ref Meta_Buffer         buffer,
    ref VkBufferView        buffer_view,
    VkBufferUsageFlags      buffer_usage_flags,
    VkMemoryPropertyFlags   buffer_memory_flags,
    VkDeviceSize            buffer_mem_size,
    VkFormat                buffer_format
    ) {

    // (re)create buffer and buffer view
    if( buffer.buffer   != VK_NULL_HANDLE )
        buffer.destroyResources;          // destroy old buffer

    if( buffer_view     != VK_NULL_HANDLE )
        vd.destroy( buffer_view );        // destroy old buffer view

    buffer_view = buffer
        .create( buffer_usage_flags, buffer_mem_size )
        .createMemory( buffer_memory_flags );
        .createBufferView( buffer.buffer, buffer_format );

}
*/



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
        .create( VK_BUFFER_USAGE_STORAGE_TEXEL_BUFFER_BIT, buffer_mem_size )
        .createMemory( VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT/*VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT*/ );

    vd.sim_particle_buffer_view =
        vd.createBufferView( vd.sim_particle_buffer.buffer, VK_FORMAT_R32G32B32A32_SFLOAT );

    
    auto data = cast( float* )vd.sim_particle_buffer.mapMemory;
    auto data_slice = data[ 0 .. 4 * vd.sim_particle_count ];
    data_slice[] = -1.0f;
    vd.sim_particle_buffer.flushMappedMemoryRange.unmapMemory;
    
}




/// create particle resources
void createParticleResources( ref VDrive_State vd ) {

    vd.createParticleDrawPSO;
    //vd.createParticleCompPSO( true, true );
}



void createParticleDrawPSO( ref VDrive_State vd ) {

    // if we are recreating an old pipeline exists already, destroy it first
    if( vd.draw_part_pso.pipeline != VK_NULL_HANDLE ) {
        vd.graphics_queue.vkQueueWaitIdle;
        vd.destroy( vd.draw_part_pso );
    }

    //////////////////////////////
    // create particle pipeline //
    //////////////////////////////

    Meta_Graphics meta_graphics;
    vd.draw_part_pso = meta_graphics( vd )
        .addShaderStageCreateInfo( vd.createPipelineShaderStage( "shader/particle.vert" ))
        .addShaderStageCreateInfo( vd.createPipelineShaderStage( "shader/particle.frag" ))
        .inputAssembly( VK_PRIMITIVE_TOPOLOGY_POINT_LIST )                          // set the inputAssembly
    //  .addBindingDescription( 0, 4 * float.sizeof, VK_VERTEX_INPUT_RATE_VERTEX )  // add vertex binding and attribute descriptions
    //  .addAttributeDescription( 0, 0, VK_FORMAT_R32G32B32A32_SFLOAT, 0 )          // interleaved attributes of ImDrawVert ...
        .addViewportAndScissors( VkOffset2D( 0, 0 ), vd.swapchain.imageExtent )     // add viewport and scissor state, necessary even if we use dynamic state
        .cullMode( VK_CULL_MODE_BACK_BIT )                                          // set rasterization state
    //  .depthState                                                                 // set depth state - enable depth test with default attributes
        .addColorBlendState( VK_TRUE )                                             // color blend state - append common (default) color blend attachment state
        .addDynamicState( VK_DYNAMIC_STATE_VIEWPORT )                               // add dynamic states viewport
        .addDynamicState( VK_DYNAMIC_STATE_SCISSOR )                                // add dynamic states scissor
        .addDescriptorSetLayout( vd.descriptor.descriptor_set_layout )              // describe pipeline layout
        .addPushConstantRange( VK_SHADER_STAGE_VERTEX_BIT , 0, 12 )                 // specify push constant range
        .renderPass( vd.render_pass.render_pass )                                   // describe compatible render pass
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