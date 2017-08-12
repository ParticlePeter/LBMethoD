
// enum for the storage format of ensight geo and ensight variable format

import erupted;
import vdrive;
import gui;
import appstate;
import resources;
import ensight;
import data_grid;

struct VDrive_Export_State {
    Data_Grid       grid;
    int             start_index     = 0;
    int             step_count      = 200;
    int             step_size       = 4;
    int             store_index     = -1;
    char[256]       case_file_name  = "ensight/LDC_D2Q9";
    char[12]        variable_name   = "velocity\0\0\0\0";
    Export_Format   file_format     = Export_Format.binary;
    private int     export_index    = 0;
    char[256]       var_file_buffer;
    char[]          var_file_name;       
}



void drawExportWait( ref VDrive_Gui_State vg ) nothrow @system {
    // draw the normal simulation before we hit the start index
    if( vg.sim_index < vg.ve.start_index ) {
        vg.vd.drawSim;
    // now draw with the export version
    } else {
        setDrawFuncSim( & drawExport );
        setDrawFunc( & drawExport );
        vg.createExportCommands;        // create export commands now
        //vg.drawExport;                  // call once as this would be the expected step now
    }
}


void drawExport( ref VDrive_Gui_State vg ) nothrow @system {

    // call the export command buffers step_count times
    // use ve.export_index counter to keeo track of steps
    // store sim_index in ve.sim_index to compute modulo
    // vd.ping_pong is still based on vd.sim_index
    // but we recompute sim_index differently
    // - vd.ping_pong = ve.sim_index % 2;
    // - vd.sim_index = ve.start_index + ve.export_index * ve.step_size;

    // it should be possible to replace vd.sim_command_buffers with our once
    // and simply call vd.draw

    if( vg.ve.export_index < vg.ve.step_count ) {
        
        // here we must draw explicitely appstate draw func! othervise we would loop, as gui.draw calls drawExport
        vg.vd.draw;

        // invlidate
        vg.export_buffer.invalidateMappedMemoryRange;

        // now we have to export the data
        // best way is to write it out raw
        vg.export_data[ 0 .. vg.export_memory.memSize ]
            .ensRawWriteBinaryVarFile( vg.ve.var_file_name, vg.ve.export_index );

        // update indexes and ping pong
        vg.sim_index = vg.ve.start_index + vg.ve.export_index * vg.ve.step_size;
        vg.sim_ping_pong = ( vg.ve.start_index + vg.ve.export_index ) % 2;
        vg.ve.export_index++;

    } else {
        // recreate original vd.sim_cmd_buffers
        // don't reset or recreate the pipeline
        // attach set vd.draw as new draw_func
        try { vg.createCompBoltzmannPipeline( false, false, false ); } catch( Exception ) {}
        vg.drawCmdBufferCount = 1;  // don't draw compute buffers
        setDrawFuncSim;             // this assigns the default     sim drawFunc
        setDrawFunc;                // this assigns the default non-sim drawFunc
        vg.vd.draw;                 // draw once as expected here

    }
}


auto ref exportSim( ref VDrive_Gui_State vg ) {
    
    // create vulkan resources
    vg.drawCmdBufferCount = 1;
    vg.createExportBuffer;
    vg.createExportPipeline;
    vg.createExportCommands;
    
    setDrawFunc( & drawExportWait );
    setDrawFuncSim( & drawExportWait );
    vg.drawCmdBufferCount = 2;

    // check if target directory exists and possibly create it
//    import std.stdio;
//    import std.path : dirName, pathSplitter;
//    import std.file : exists, mkdir, mkdirRecurse;
//    
//    if(!vg.ve.case_file_name.dirName.exists )
//        //vg.ve.case_file_name.dirName.mkdir;
//        vg.ve.case_file_name.dirName.mkdirRecurse;

    // setup ensight options
    import std.string : fromStringz;
    import std.conv : to;
    Export_Options options = {
        output      : vg.ve.case_file_name.ptr.fromStringz.to!string,
        variable    : vg.ve.variable_name,
        format      : vg.ve.file_format,
        overwrite   : true,
    };options.set_default_options;

    // setup domain parameter
    if( vg.sim_use_3_dim ) vg.sim_domain[2] = 1;
    float[3] minDomain = [ 0, 0, 0 ];
    float[3] maxDomain = [ vg.sim_domain[0], vg.sim_domain[1], vg.sim_domain[2] ];
    float[3] incDomain = [ 1, 1, 1 ];
    uint [3] cellCount = vg.sim_domain[ 0..3 ];

    // export case and geo file
    options.ensStoreCase( vg.ve.start_index, vg.ve.step_count, vg.ve.step_size );
    options.ensStoreGeo( minDomain, maxDomain, incDomain, cellCount );

    // get var file name from options

    auto length = options.outVar.length;
    //vg.ve.var_file_buffer[ ] = '\0';
    vg.ve.var_file_buffer[ 0 .. length ] = options.outVar[];
    vg.ve.var_file_buffer[ length .. length + 3 ] = cast( char )( 48 );

    // assign the prepared buffer to the name slice 
    vg.ve.var_file_name = vg.ve.var_file_buffer[ 0 .. length + 3 ];
    vg.ve.export_index = 0;

    // set a Export_Binary_Variable_Header in the beginning
    vg.ve.variable_name.ptr.ensGetBinaryVarHeader( vg.export_data );

    return vg;

}





auto ref createExportBuffer( ref VDrive_State vd ) {

    uint32_t buffer_size = vd.sim_domain[0] * vd.sim_domain[1] * ( vd.sim_use_3_dim ? vd.sim_domain[2] : 1 );
    uint32_t buffer_mem_size = buffer_size * (( vd.export_as_vector ? 3 : 1 ) * float.sizeof ).toUint; 
    auto header_size = ensGetBinaryVarHeaderSize;
    //
    // exit early if memory is sufficiently large
    //
    if( header_size + buffer_mem_size <= vd.export_memory.memSize )
        return vd;

    
    vd.graphics_queue.vkQueueWaitIdle;
    //
    // (re)create memory, buffer and buffer view
    //
    if( vd.export_memory.memory != VK_NULL_HANDLE )
        vd.export_memory.destroyResources;             // destroy old memory

    if( vd.export_buffer.buffer != VK_NULL_HANDLE )
        vd.export_buffer.destroyResources;          // destroy old buffer

    if( vd.export_buffer_view   != VK_NULL_HANDLE )
        vd.destroy( vd.export_buffer_view );        // destroy old buffer view


    // create memory less buffer and get its alignment requirement
    auto aligned_offset = vd.export_buffer( vd )
        .create( VK_BUFFER_USAGE_STORAGE_TEXEL_BUFFER_BIT, buffer_mem_size )
        .alignedOffset( header_size );

    // create memory with additional space for header
    vd.export_memory( vd )
        .create( VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, aligned_offset + buffer_mem_size );

    // bind memory with offset to buffer
    vd.export_buffer( vd )
        .bindMemory( vd.export_memory.memory, aligned_offset );

    // bind buffer to buffer view
    vd.export_buffer_view = vd.createBufferView( vd.export_buffer.buffer, VK_FORMAT_R32_SFLOAT );

    // update the descriptor with buffer 
    vd.export_descriptor_update.texel_buffer_views[0] = vd.export_buffer_view;  // export target buffer
    vd.export_descriptor_update.update;

    // map the whole memory 
    vd.export_data = vd.export_memory.mapMemory;

    return vd;

}


auto ref createExportPipeline( ref VDrive_State vd ) {

    if( vd.comp_export_pso.is_constructed ) {
        vd.graphics_queue.vkQueueWaitIdle;          // wait for queue idle as we need to destroy the pipeline
        vd.destroy( vd.comp_export_pso );
    }
    
    Meta_Compute meta_compute;                      // use temporary Meta_Compute struct to specify and create the pso
    vd.comp_export_pso = meta_compute( vd )         // extracting the core items after construction with reset call
        .shaderStageCreateInfo( vd.createPipelineShaderStage( VK_SHADER_STAGE_COMPUTE_BIT, vd.export_shader ))
        .addDescriptorSetLayout( vd.descriptor.descriptor_set_layout )
        .addPushConstantRange( VK_SHADER_STAGE_COMPUTE_BIT, 0, 8 )
        .construct( vd.compute_cache )              // construct using pipeline cache
        .destroyShaderModule
        .reset;
}


auto ref createExportCommands( ref VDrive_Gui_State vd ) {

    ///////////////////////////////////////////////////////////////////////////
    // create two reusable compute command buffers with export functionality //
    ///////////////////////////////////////////////////////////////////////////

    // reset the command pool to start recording drawing commands
    vd.graphics_queue.vkQueueWaitIdle;   // equivalent using a fence per Spec v1.0.48
    vd.device.vkResetCommandPool( vd.sim_cmd_pool, 0 ); // second argument is VkCommandPoolResetFlags

    // two command buffers for compute loop, one ping and one pong buffer
    vd.allocateCommandBuffers( vd.sim_cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, vd.sim_cmd_buffers );
    auto sim_cmd_buffers_bi = createCmdBufferBI;

    // barrier for population access from export shader
    VkBufferMemoryBarrier sim_buffer_memory_barrier = {
        srcAccessMask       : VK_ACCESS_SHADER_WRITE_BIT,
        dstAccessMask       : VK_ACCESS_SHADER_READ_BIT,
        srcQueueFamilyIndex : vd.graphics_queue_family_index,
        dstQueueFamilyIndex : vd.graphics_queue_family_index,
        buffer              : vd.sim_buffer.buffer,
        offset              : 0,
        size                : VK_WHOLE_SIZE,
    };

    // barrier for velocity access from export shader
    VkImageMemoryBarrier sim_image_memory_barrier = {
        srcAccessMask       : VK_ACCESS_SHADER_WRITE_BIT,
        dstAccessMask       : VK_ACCESS_SHADER_READ_BIT,
        oldLayout           : VK_IMAGE_LAYOUT_GENERAL,
        newLayout           : VK_IMAGE_LAYOUT_GENERAL,
        srcQueueFamilyIndex : vd.graphics_queue_family_index,
        dstQueueFamilyIndex : vd.graphics_queue_family_index,
        image               : vd.sim_image.image,
        subresourceRange    : {
            aspectMask          : VK_IMAGE_ASPECT_COLOR_BIT,    // VkImageAspectFlags  aspectMask;
            baseMipLevel        : 0,                            // uint32_t            baseMipLevel;
            levelCount          : 1,                            // uint32_t            levelCount;
            baseArrayLayer      : 0,                            // uint32_t            baseArrayLayer;
            layerCount          : 1,                            // uint32_t            layerCount;
        }
    };

    // barrier for exported data access from host
    VkBufferMemoryBarrier export_buffer_memory_barrier = {
        srcAccessMask       : VK_ACCESS_SHADER_WRITE_BIT,
        dstAccessMask       : VK_ACCESS_HOST_READ_BIT,
        srcQueueFamilyIndex : vd.graphics_queue_family_index,
        dstQueueFamilyIndex : vd.graphics_queue_family_index,
        buffer              : vd.export_buffer.buffer,
        offset              : 0,
        size                : VK_WHOLE_SIZE,
    };


    uint32_t dispatch_x = vd.sim_domain[0] * vd.sim_domain[1] * vd.sim_domain[2] / vd.sim_work_group_size[0];



    // record commands in loop, only difference is the push constant
    foreach( i, ref cmd_buffer; vd.sim_cmd_buffers ) {

        // - vd.ping_pong = ve.sim_index % 2;
        // - vd.sim_index = ve.start_index + ve.export_index * ve.step_size;

        //uint32_t[2] push_constant = [ (( vd.ve.start_index + i ) % 2 ).toUint, vd.sim_layers ];
        uint32_t[2] push_constant = [ i.toUint % vd.MAX_FRAMES, vd.sim_layers ];

        cmd_buffer.vkBeginCommandBuffer( &sim_cmd_buffers_bi );  // begin command buffer recording


        //
        // First export the current frame!
        //
        cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_COMPUTE, vd.comp_export_pso.pipeline );    // bind compute vd.comp_export_pso.pipeline

        cmd_buffer.vkCmdBindDescriptorSets(             // VkCommandBuffer              commandBuffer
            VK_PIPELINE_BIND_POINT_COMPUTE,             // VkPipelineBindPoint          pipelineBindPoint
            vd.comp_export_pso.pipeline_layout,         // VkPipelineLayout             layout
            0,                                          // uint32_t                     firstSet
            1,                                          // uint32_t                     descriptorSetCount
            &vd.descriptor.descriptor_set,              // const( VkDescriptorSet )*    pDescriptorSets
            0,                                          // uint32_t                     dynamicOffsetCount
            null                                        // const( uint32_t )*           pDynamicOffsets
        );

        cmd_buffer.vkCmdPushConstants( vd.comp_export_pso.pipeline_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, 8, push_constant.ptr ); // push constant

        cmd_buffer.vkCmdDispatch( dispatch_x, 1, 1 );   // dispatch compute command

        cmd_buffer.vkCmdPipelineBarrier(
            VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,       // VkPipelineStageFlags                 srcStageMask,                                    
            VK_PIPELINE_STAGE_HOST_BIT,                 // VkPipelineStageFlags                 dstStageMask,                        
            0,                                          // VkDependencyFlags                    dependencyFlags,
            0, null,                                    // uint32_t memoryBarrierCount,         const VkMemoryBarrier*  pMemoryBarriers,        
            1, & export_buffer_memory_barrier,          // uint32_t bufferMemoryBarrierCount,   const VkBufferMemoryBarrier* pBufferMemoryBarriers,                                
            0, null,                                    // uint32_t imageMemoryBarrierCount,    const VkImageMemoryBarrier*  pImageMemoryBarriers,        
        );

        //
        // Now do step_size count simulations
        //

        foreach( s; 0 .. vd.ve.step_size ) {

            //push_constant[0] = (( ve.sim_index + i + s ) % 2 ).toUint;
            push_constant[0] = (( i + s ) % vd.MAX_FRAMES ).toUint;

            cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_COMPUTE, vd.comp_loop_pso.pipeline );    // bind compute vd.comp_loop_pso.pipeline

            cmd_buffer.vkCmdBindDescriptorSets(             // VkCommandBuffer              commandBuffer
                VK_PIPELINE_BIND_POINT_COMPUTE,             // VkPipelineBindPoint          pipelineBindPoint
                vd.comp_loop_pso.pipeline_layout,           // VkPipelineLayout             layout
                0,                                          // uint32_t                     firstSet
                1,                                          // uint32_t                     descriptorSetCount
                &vd.descriptor.descriptor_set,              // const( VkDescriptorSet )*    pDescriptorSets
                0,                                          // uint32_t                     dynamicOffsetCount
                null                                        // const( uint32_t )*           pDynamicOffsets
            );

            cmd_buffer.vkCmdPushConstants( vd.comp_loop_pso.pipeline_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, 8, push_constant.ptr ); // push constant

            cmd_buffer.vkCmdDispatch( dispatch_x, 1, 1 );   // dispatch compute command

            cmd_buffer.vkCmdPipelineBarrier(
                VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,       // VkPipelineStageFlags                 srcStageMask,
                VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,       // VkPipelineStageFlags                 dstStageMask,
                0,                                          // VkDependencyFlags                    dependencyFlags,
                0, null,                                    // uint32_t memoryBarrierCount,         const VkMemoryBarrier* pMemoryBarriers,
                1, & sim_buffer_memory_barrier,             // uint32_t bufferMemoryBarrierCount,   const VkBufferMemoryBarrier* pBufferMemoryBarriers,
                0, null,                                    // uint32_t imageMemoryBarrierCount,    const VkImageMemoryBarrier*  pImageMemoryBarriers,
            );
        }

        // one barrier for the image as we access it next step
        cmd_buffer.vkCmdPipelineBarrier(
            VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,       // VkPipelineStageFlags                 srcStageMask,
            VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,       // VkPipelineStageFlags                 dstStageMask,
            0,                                          // VkDependencyFlags                    dependencyFlags,
            0, null,                                    // uint32_t memoryBarrierCount,         const VkMemoryBarrier* pMemoryBarriers,
            0, null, //& sim_buffer_memory_barrier,     // uint32_t bufferMemoryBarrierCount,   const VkBufferMemoryBarrier* pBufferMemoryBarriers,
            1, & sim_image_memory_barrier,              // uint32_t imageMemoryBarrierCount,    const VkImageMemoryBarrier*  pImageMemoryBarriers,
        );

        cmd_buffer.vkEndCommandBuffer;                  // finish recording and submit the command
    }

    // init_pso ping pong variable to 1
    // it will be switched to 0 ( pp = 1 - pp ) befor submitting compute commands
    //vd.sim_ping_pong = 1;
} 



auto ref destroyExport( ref VDrive_State vd ) {
    // export resources
    if( vd.comp_export_pso.is_constructed ) vd.destroy( vd.comp_export_pso );
    if( vd.export_memory.is_constructed ) vd.export_memory.destroyResources;
    if( vd.export_buffer.is_constructed ) vd.export_buffer.destroyResources;
    if( vd.export_buffer_view != VK_NULL_HANDLE ) vd.destroy( vd.export_buffer_view );
}