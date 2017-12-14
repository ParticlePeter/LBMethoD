import erupted;
import vdrive;
import gui;
import appstate;
import resources;
import ensight;



/////////////////////////
// export state struct //
/////////////////////////
struct VDrive_Export_State {
    int             start_index     = 0;
    int             step_count      = 21;
    int             step_size       = 10001;
    int             store_index     = -1;
    char[256]       case_file_name  = "ensight/LDC_D2Q9";
    char[12]        variable_name   = "velocity\0\0\0\0";
    Export_Format   file_format     = Export_Format.binary;
    private int     export_index    = 0;
    char[256]       var_file_buffer;
    char[]          var_file_name;
}



void drawExportWait( ref VDrive_State vd ) nothrow @system {
    // draw the normal simulation before we hit the start index
    if( vd.sim_index < vd.ve.start_index ) {
        vd.drawSim;
    // now draw with the export version
    } else {
        setSimFuncPlay( & drawExport );
        vd.drawCmdBufferCount = vd.sim_play_cmd_buffer_count = 1;
        vd.createExportCommands;        // create export commands now
        vd.drawExport;                  // call once as we skipped drawSim above
    }
}


void drawExport( ref VDrive_State vd ) nothrow @system {

    // call the export command buffers step_count times
    // use ve.export_index counter to keeo track of steps
    // store sim_index in ve.sim_index to compute modulo
    // vd.ping_pong is still based on vd.sim_index
    // but we recompute sim_index differently
    // - vd.ping_pong = ve.sim_index % 2;
    // - vd.sim_index = ve.start_index + ve.export_index * ve.step_size;

    // it should be possible to replace vd.sim_command_buffers with our once
    // and simply call vd.draw

    if( vd.ve.export_index < vd.ve.step_count ) {

        vd.sim_profile_step_index += vd.ve.step_size;
        vd.profileSim;  // allways use profilSim to observe MLups when mass exporting

        // invlidate
        vd.export_buffer[ vd.ve.export_index % 2 ].invalidateMappedMemoryRange;

        // now we have to export the data
        // best way is to write it out raw
        vd.export_data[ vd.ve.export_index % 2 ][ 0 .. vd.export_size ]
            .ensRawWriteBinaryVarFile( vd.ve.var_file_name, vd.ve.export_index );

        // update indexes and ping pong
        vd.sim_ping_pong = ( vd.ve.start_index + vd.ve.export_index ) % 2;
        ++vd.ve.export_index;
        vd.sim_index = vd.ve.start_index + vd.ve.export_index * vd.ve.step_size;

    } else {
        // recreate original vd.sim_cmd_buffers
        // don't reset or recreate the pipeline
        try {
            vd.createBoltzmannPSO( false, false, false );
        } catch( Exception ) {}

        // set default function pointer for play and profile and pause the playback
        vd.setDefaultSimFuncs;
        vd.simPause;

        // draw the graphics display once
        // otherwisethis draw would be omitted, and the gui rebuild immediatelly
        vd.drawSim;

    }
}



void createExportResources( ref VDrive_State vd ) {

    // create vulkan resources
    vd.createExportBuffer;
    vd.createExportPipeline;
    vd.createExportCommands;

    // setup export draw function
    setSimFuncPlay( & drawExportWait );

    // initialize profile data
    vd.sim_profile_step_index = 0;
    vd.resetStopWatch;


    // setup ensight options
    import std.string : fromStringz;
    import std.conv : to;
    Export_Options options = {
        output      : vd.ve.case_file_name.ptr.fromStringz.to!string,
        variable    : vd.ve.variable_name,
        format      : vd.ve.file_format,
        overwrite   : true,
    };
    options.set_default_options;

    // setup domain parameter
    if( vd.use_3_dim ) vd.sim_domain[2] = 1;
    float[3] minDomain = [ 0, 0, 0 ];
    float[3] maxDomain = [ vd.sim_domain[0], vd.sim_domain[1], vd.sim_domain[2] ];
    float[3] incDomain = [ 1, 1, 1 ];
    uint [3] cellCount = vd.sim_domain[ 0..3 ];

    // export case and geo file
    options.ensStoreCase( vd.ve.start_index, vd.ve.step_count, vd.ve.step_size );
    options.ensStoreGeo( minDomain, maxDomain, incDomain, cellCount );

    // get var file name from options

    auto length = options.outVar.length;
    //vd.ve.var_file_buffer[ ] = '\0';
    vd.ve.var_file_buffer[ 0 .. length ] = options.outVar[];
    vd.ve.var_file_buffer[ length .. length + 3 ] = cast( char )( 48 );

    // assign the prepared buffer to the name slice
    vd.ve.var_file_name = vd.ve.var_file_buffer[ 0 .. length + 3 ];
    vd.ve.export_index = 0;

    // set a Export_Binary_Variable_Header in the beginning
    vd.ve.variable_name.ptr.ensGetBinaryVarHeader( vd.export_data[0] );
    vd.ve.variable_name.ptr.ensGetBinaryVarHeader( vd.export_data[1] );

}





void createExportBuffer( ref VDrive_State vd ) {

    uint32_t buffer_size = vd.sim_domain[0] * vd.sim_domain[1] * ( vd.use_3_dim ? vd.sim_domain[2] : 1 );
    uint32_t buffer_mem_size = buffer_size * (( vd.export_as_vector ? 3 : 1 ) * float.sizeof ).toUint;
    auto header_size = ensGetBinaryVarHeaderSize;

    //
    // exit early if memory is sufficiently large
    //
    if( header_size + buffer_mem_size <= vd.export_memory.memSize ) return;


    vd.graphics_queue.vkQueueWaitIdle;
    //
    // (re)create memory, buffer and buffer view
    //
    if( vd.export_memory.memory != VK_NULL_HANDLE )
        vd.export_memory.destroyResources;             // destroy old memory

    if( vd.export_buffer[0].buffer != VK_NULL_HANDLE )
        vd.export_buffer[0].destroyResources;          // destroy old buffer

    if( vd.export_buffer_view[0]   != VK_NULL_HANDLE )
        vd.destroy( vd.export_buffer_view[0] );        // destroy old buffer view

    if( vd.export_buffer[1].buffer != VK_NULL_HANDLE )
        vd.export_buffer[1].destroyResources;          // destroy old buffer

    if( vd.export_buffer_view[1]   != VK_NULL_HANDLE )
        vd.destroy( vd.export_buffer_view[1] );        // destroy old buffer view

    //
    // as we are computing in a ping pong fashion we need two export buffers
    // othervise we get race conditions when writing into one buffer from the compute shaders
    //

    // create first memory less buffer and get its alignment requirement
    auto aligned_offset_0 = vd.export_buffer[0]( vd )
        .create( VK_BUFFER_USAGE_STORAGE_TEXEL_BUFFER_BIT, buffer_mem_size )
        .alignedOffset( header_size );

    // create second memory less buffer and get its alignment requirement
    auto aligned_offset_1 = vd.export_buffer[1]( vd )
        .create( VK_BUFFER_USAGE_STORAGE_TEXEL_BUFFER_BIT, buffer_mem_size )
        .alignedOffset( aligned_offset_0 + vd.export_buffer[0].memSize + header_size );

    //import std.stdio;
    //writeln( "header_size      : ", header_size );
    //writeln( "aligned_offset_0 : ", aligned_offset_0 );
    //writeln( "aligned_offset_1 : ", aligned_offset_1 );
    //writeln( "buffer_mem_size  : ", buffer_mem_size );
    //writeln( "memSize_0        : ", vd.export_buffer[0].memSize );
    //writeln( "memSize_1        : ", vd.export_buffer[1].memSize );
    //writeln;

    // create memory with additional spaces for two headers
    vd.export_memory( vd )
        .create( VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, aligned_offset_1 + vd.export_buffer[1].memSize );

    // bind memory with offset to first buffer
    vd.export_buffer[0]
        .bindMemory( vd.export_memory.memory, aligned_offset_0 );

    // bind memory with offset to first buffer
    vd.export_buffer[1]
        .bindMemory( vd.export_memory.memory, aligned_offset_1 );

    // bind two buffers to two buffer views
    vd.export_buffer_view[0] = vd.createBufferView( vd.export_buffer[0].buffer, VK_FORMAT_R32_SFLOAT );
    vd.export_buffer_view[1] = vd.createBufferView( vd.export_buffer[1].buffer, VK_FORMAT_R32_SFLOAT );

    // update the descriptor with buffer
    vd.export_descriptor_update.texel_buffer_views[0] = vd.export_buffer_view[0];  // export target buffer
    vd.export_descriptor_update.texel_buffer_views[1] = vd.export_buffer_view[1];  // export target buffer
    vd.export_descriptor_update.update;

    // map first and second memory ranges, including the aligned headers
    vd.export_size = header_size + buffer_mem_size;
    auto mapped_memory = vd.export_memory.mapMemory;
    vd.export_data[0]  = mapped_memory + aligned_offset_0 - header_size;    //vd.export_memory.mapMemory( vd.export_size, aligned_offset_0 - header_size );    // size, offset
    vd.export_data[1]  = mapped_memory + aligned_offset_1 - header_size;    //vd.export_memory.mapMemory( vd.export_size, aligned_offset_1 - header_size );    // size, offset

}


void createExportPipeline( ref VDrive_State vd ) {

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


void createExportCommands( ref VDrive_State vd ) nothrow {

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
        srcQueueFamilyIndex : VK_QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex : VK_QUEUE_FAMILY_IGNORED,
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
        srcQueueFamilyIndex : VK_QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex : VK_QUEUE_FAMILY_IGNORED,
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
        srcQueueFamilyIndex : VK_QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex : VK_QUEUE_FAMILY_IGNORED,
        //buffer              : vd.export_buffer.buffer,
        offset              : 0,
        size                : VK_WHOLE_SIZE,
    };


    uint32_t dispatch_x = vd.sim_domain[0] * vd.sim_domain[1] * vd.sim_domain[2] / vd.sim_work_group_size[0];



    // record commands in loop, only difference is the push constant
    foreach( i, ref cmd_buffer; vd.sim_cmd_buffers ) {

        // - vd.ping_pong = ve.sim_index % 2;
        // - vd.sim_index = ve.start_index + ve.export_index * ve.step_size;

        //
        // First export the current frame!
        //

        cmd_buffer.vkBeginCommandBuffer( &sim_cmd_buffers_bi );  // begin command buffer recording

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

        // with this approach we are able to export sim step zero, initial settings, where no simulation took place
        // we export from the pong buffer, for any other case, after simulation took place
        // hence we use ( i + 1 ) % 2 instead of i % 2
        // to get proper results, the pong range of the population buffer and the macroscopic property image
        // must be properly initialized
        uint32_t[2] push_constant = [ ( i + 1 ).toUint % 2, vd.sim_layers ];
        cmd_buffer.vkCmdPushConstants( vd.comp_export_pso.pipeline_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, 8, push_constant.ptr ); // push constant

        cmd_buffer.vkCmdDispatch( dispatch_x, 1, 1 );   // dispatch compute command

        export_buffer_memory_barrier.buffer = vd.export_buffer[i].buffer;
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
            push_constant[0] = (( i + s ) % 2 ).toUint;

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



void destroyExportResources( ref VDrive_State vd ) {
    // export resources
    if( vd.comp_export_pso.is_constructed ) vd.destroy( vd.comp_export_pso );
    if( vd.export_memory.is_constructed ) vd.export_memory.destroyResources;
    if( vd.export_buffer[0].is_constructed ) vd.export_buffer[0].destroyResources;
    if( vd.export_buffer[1].is_constructed ) vd.export_buffer[1].destroyResources;
    if( vd.export_buffer_view[0] != VK_NULL_HANDLE ) vd.destroy( vd.export_buffer_view[0] );
    if( vd.export_buffer_view[1] != VK_NULL_HANDLE ) vd.destroy( vd.export_buffer_view[1] );
}