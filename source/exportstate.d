import erupted;
import vdrive;
//import gui;
import appstate;
import simulate;
import resources;
import ensight;


//nothrow @nogc:


//////////////////////////////////////
// export state and resource struct //
//////////////////////////////////////
struct VDrive_Export_State {

    // export vulkan resources
    Core_Pipeline               export_pso;
    Meta_Memory                 export_memory;
    Meta_Buffer_View[2]         export_buffer;
    VkDeviceSize                export_size;
    void*[2]                    export_data;
    VkMappedMemoryRange[2]      export_mapped_range;
    char[64]                    export_shader = "shader/export_from_image.comp";


    // export parameter
    int             start_index     = 0;
    int             step_count      = 21;
    int             step_size       = 101;
    int             store_index     = -1;
    char[256]       case_file_name  = "ensight/LDC_D2Q9";
    char[12]        variable_name   = "velocity\0\0\0\0";
    Export_Format   file_format     = Export_Format.binary;
    private int     export_index    = 0;
    char[256]       var_file_buffer;
    char[]          var_file_name;
    bool            as_vector       = true;
}



void drawExportWait( ref VDrive_State app ) nothrow @system {
    // draw the normal simulation before we hit the start index
    if( app.sim.index < app.exp.start_index ) {
        app.drawSim;
    // now draw with the export version
    } else {
        setSimFuncPlay( & drawExport );
        app.drawCmdBufferCount = app.sim_play_cmd_buffer_count = 1;
        app.createExportCommands;        // create export commands now
        app.drawExport;                  // call once as we skipped drawSim above
    }
}


void drawExport( ref VDrive_State app ) nothrow @system {

    // call the export command buffers step_count times
    // use exp.export_index counter to keeo track of steps
    // store sim_index in exp.sim_index to compute modulo
    // app.ping_pong is still based on app.sim.index
    // but we recompute sim_index differently
    // - app.ping_pong = exp.sim_index % 2;
    // - app.sim.index = exp.start_index + exp.export_index * exp.step_size;

    // it should be possible to replace app.sim_command_buffers with our once
    // and simply call app.draw

    if( app.exp.export_index < app.exp.step_count ) {

        app.sim_profile_step_index += app.exp.step_size;
        app.profileSim;  // allways use profilSim to observe MLups when mass exporting

        // invlidate
        app.exp.export_buffer[ app.exp.export_index % 2 ].invalidateMappedMemoryRange;

        // now we have to export the data
        // best way is to write it out raw
        app.exp.export_data[ app.exp.export_index % 2 ][ 0 .. app.exp.export_size ]
            .ensRawWriteBinaryVarFile( app.exp.var_file_name, app.exp.export_index );

        // update indexes and ping pong
        app.sim.ping_pong = ( app.exp.start_index + app.exp.export_index ) % 2;
        ++app.exp.export_index;
        app.sim.index = app.exp.start_index + app.exp.export_index * app.exp.step_size;

    } else {
        // recreate original app.sim.cmd_buffers
        // don't reset or recreate the pipeline
        try {
            app.createBoltzmannPSO( false, false, false );
        } catch( Exception ) {}

        // set default function pointer for play and profile and pause the playback
        app.setDefaultSimFuncs;
        app.simPause;

        // draw the graphics display once
        // otherwisethis draw would be omitted, and the gui rebuild immediatelly
        app.drawSim;

    }
}



void createExportResources( ref VDrive_State app ) {

    // create vulkan resources
    app.createExportBuffer;
    app.createExportPipeline;
    app.createExportCommands;

    // setup export draw function
    setSimFuncPlay( & drawExportWait );

    // initialize profile data
    app.sim_profile_step_index = 0;
    app.resetStopWatch;


    // setup ensight options
    import std.string : fromStringz;
    import std.conv : to;
    Export_Options options = {
        output      : app.exp.case_file_name.ptr.fromStringz.to!string,
        variable    : app.exp.variable_name,
        format      : app.exp.file_format,
        overwrite   : true,
    };
    options.set_default_options;

    // setup domain parameter
    if( app.sim.use_3_dim ) app.sim.domain[2] = 1;
    float[3] minDomain = [ 0, 0, 0 ];
    float[3] maxDomain = [ app.sim.domain[0], app.sim.domain[1], app.sim.domain[2] ];
    float[3] incDomain = [ 1, 1, 1 ];
    uint [3] cellCount = app.sim.domain[ 0..3 ];

    // export case and geo file
    options.ensStoreCase( app.exp.start_index, app.exp.step_count, app.exp.step_size );
    options.ensStoreGeo( minDomain, maxDomain, incDomain, cellCount );

    // get var file name from options

    auto length = options.outVar.length;
    //app.exp.var_file_buffer[ ] = '\0';
    app.exp.var_file_buffer[ 0 .. length ] = options.outVar[];
    app.exp.var_file_buffer[ length .. length + 3 ] = cast( char )( 48 );

    // assign the prepared buffer to the name slice
    app.exp.var_file_name = app.exp.var_file_buffer[ 0 .. length + 3 ];
    app.exp.export_index = 0;

    // set a Export_Binary_Variable_Header in the beginning
    app.exp.variable_name.ptr.ensGetBinaryVarHeader( app.exp.export_data[0] );
    app.exp.variable_name.ptr.ensGetBinaryVarHeader( app.exp.export_data[1] );

}





void createExportBuffer( ref VDrive_State app ) {

    uint32_t buffer_size = app.sim.domain[0] * app.sim.domain[1] * ( app.sim.use_3_dim ? app.sim.domain[2] : 1 );
    uint32_t buffer_mem_size = buffer_size * (( app.exp.as_vector ? 3 : 1 ) * float.sizeof ).toUint;
    auto header_size = ensGetBinaryVarHeaderSize;

    //
    // exit early if memory is sufficiently large
    //
    if( header_size + buffer_mem_size <= app.exp.export_memory.memSize ) return;


    app.graphics_queue.vkQueueWaitIdle;
    //
    // (re)create memory, buffer and buffer view
    //
    if( app.exp.export_memory.memory != VK_NULL_HANDLE )
        app.exp.export_memory.destroyResources;                 // destroy old memory

    if( app.exp.export_buffer[0].buffer != VK_NULL_HANDLE )
        app.exp.export_buffer[0].destroyResources;              // destroy old buffer

    if( app.exp.export_buffer[0].view != VK_NULL_HANDLE )
        app.destroy( app.exp.export_buffer[0].view );           // destroy old buffer view

    if( app.exp.export_buffer[1].buffer != VK_NULL_HANDLE )
        app.exp.export_buffer[1].destroyResources;              // destroy old buffer

    if( app.exp.export_buffer[1].view != VK_NULL_HANDLE )
        app.destroy( app.exp.export_buffer[1].view );           // destroy old buffer view

    //
    // as we are computing in a ping pong fashion we need two export buffers
    // othervise we get race conditions when writing into one buffer from the compute shaders
    //

    // create first memory less buffer and get its alignment requirement
    auto aligned_offset_0 = app.exp.export_buffer[0]( app )
        .usage( VK_BUFFER_USAGE_STORAGE_TEXEL_BUFFER_BIT )
        .bufferSize( buffer_mem_size )
        .constructBuffer
        .alignedOffset( header_size );

    // create second memory less buffer and get its alignment requirement
    auto aligned_offset_1 = app.exp.export_buffer[1]( app )
        .usage( VK_BUFFER_USAGE_STORAGE_TEXEL_BUFFER_BIT )
        .bufferSize( buffer_mem_size )
        .constructBuffer
        .alignedOffset( aligned_offset_0 + app.exp.export_buffer[0].memSize + header_size );

    // create memory with additional spaces for two headers
    app.exp.export_memory( app )
        .allocate( VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, aligned_offset_1 + app.exp.export_buffer[1].memSize );

    // bind memory with offset to first buffer
    app.exp.export_buffer[0]
        .bindMemory( app.exp.export_memory.memory, aligned_offset_0 );

    // bind memory with offset to first buffer
    app.exp.export_buffer[1]
        .bindMemory( app.exp.export_memory.memory, aligned_offset_1 );

    // bind each of two buffers to a buffer view
    app.exp.export_buffer[0].view = app.createBufferView( app.exp.export_buffer[0].buffer, VK_FORMAT_R32_SFLOAT );
    app.exp.export_buffer[1].view = app.createBufferView( app.exp.export_buffer[1].buffer, VK_FORMAT_R32_SFLOAT );

    // update the descriptor with only the new buffer views
    Descriptor_Update_T!( 1, 0, 0, 2 )()
        .addStorageTexelBufferUpdate( 8 )
        .addTexelBufferView( app.exp.export_buffer[0].view )
        .addTexelBufferView( app.exp.export_buffer[1].view )
        .attachSet( app.descriptor.descriptor_set )
        .update( app );

    // Todo(pp): test the descriptor update code above, then remove the commented code bellow
    //app.exp.descriptor_update.texel_buffer_views[0] = app.exp.export_buffer[0].view;  // export target buffer
    //app.exp.descriptor_update.texel_buffer_views[1] = app.exp.export_buffer[1].view;  // export target buffer
    //app.exp.descriptor_update.update( app );

    // map first and second memory ranges, including the aligned headers
    app.exp.export_size = header_size + buffer_mem_size;
    auto mapped_memory = app.exp.export_memory.mapMemory;
    app.exp.export_data[0]  = mapped_memory + aligned_offset_0 - header_size;
    app.exp.export_data[1]  = mapped_memory + aligned_offset_1 - header_size;

}


void createExportPipeline( ref VDrive_State app ) {

    if( app.exp.export_pso.is_null ) {
        app.graphics_queue.vkQueueWaitIdle;         // wait for queue idle as we need to destroy the pipeline
        app.destroy( app.exp.export_pso );
    }

    import std.string : fromStringz;
    Meta_Compute meta_compute;                      // use temporary Meta_Compute struct to specify and create the pso
    app.exp.export_pso = meta_compute( app )        // extracting the core items after construction with reset call
        .shaderStageCreateInfo( app.createPipelineShaderStage( VK_SHADER_STAGE_COMPUTE_BIT, app.exp.export_shader.ptr ))
        .addDescriptorSetLayout( app.descriptor.descriptor_set_layout )
        .addPushConstantRange( VK_SHADER_STAGE_COMPUTE_BIT, 0, 8 )
        .construct( app.sim.compute_cache )              // construct using pipeline cache
        .destroyShaderModule
        .reset;

        //import std.stdio;
        //writeln( meta_compute.static_config );
        //app.exp.export_pso = meta_compute.reset;
}


void createExportCommands( ref VDrive_State app ) nothrow {

    ///////////////////////////////////////////////////////////////////////////
    // create two reusable compute command buffers with export functionality //
    ///////////////////////////////////////////////////////////////////////////

    // reset the command pool to start recording drawing commands
    app.graphics_queue.vkQueueWaitIdle;   // equivalent using a fence per Spec v1.0.48
    app.device.vkResetCommandPool( app.sim.cmd_pool, 0 );   // second argument is VkCommandPoolResetFlags

    // two command buffers for compute loop, one ping and one pong buffer
    app.allocateCommandBuffers( app.sim.cmd_pool, app.sim.cmd_buffers );
    auto sim_cmd_buffers_bi = createCmdBufferBI;

    // barrier for population access from export shader
    VkBufferMemoryBarrier sim_buffer_memory_barrier = {
        srcAccessMask       : VK_ACCESS_SHADER_WRITE_BIT,
        dstAccessMask       : VK_ACCESS_SHADER_READ_BIT,
        srcQueueFamilyIndex : VK_QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex : VK_QUEUE_FAMILY_IGNORED,
        buffer              : app.sim.popul_buffer.buffer,
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
        image               : app.sim.macro_image.image,
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
        //buffer              : app.exp.export_buffer.buffer,
        offset              : 0,
        size                : VK_WHOLE_SIZE,
    };


    uint32_t dispatch_x = app.sim.domain[0] * app.sim.domain[1] * app.sim.domain[2] / app.sim.work_group_size[0];



    // record commands in loop, only difference is the push constant
    foreach( i, ref cmd_buffer; app.sim.cmd_buffers ) {

        // - app.ping_pong = exp.sim_index % 2;
        // - app.sim.index = exp.start_index + exp.export_index * exp.step_size;

        //
        // First export the current frame!
        //

        cmd_buffer.vkBeginCommandBuffer( & sim_cmd_buffers_bi );  // begin command buffer recording

        cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_COMPUTE, app.exp.export_pso.pipeline );    // bind compute app.exp.export_pso.pipeline

        cmd_buffer.vkCmdBindDescriptorSets(             // VkCommandBuffer              commandBuffer
            VK_PIPELINE_BIND_POINT_COMPUTE,             // VkPipelineBindPoint          pipelineBindPoint
            app.exp.export_pso.pipeline_layout,         // VkPipelineLayout             layout
            0,                                          // uint32_t                     firstSet
            1,                                          // uint32_t                     descriptorSetCount
            & app.descriptor.descriptor_set,            // const( VkDescriptorSet )*    pDescriptorSets
            0,                                          // uint32_t                     dynamicOffsetCount
            null                                        // const( uint32_t )*           pDynamicOffsets
        );

        // with this approach we are able to export sim step zero, initial settings, where no simulation took place
        // we export from the pong buffer, for any other case, after simulation took place
        // hence we use ( i + 1 ) % 2 instead of i % 2
        // to get proper results, the pong range of the population buffer and the macroscopic property image
        // must be properly initialized
        uint32_t[2] push_constant = [ ( i + 1 ).toUint % 2, app.sim.layers ];
        cmd_buffer.vkCmdPushConstants( app.exp.export_pso.pipeline_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, 8, push_constant.ptr ); // push constant

        cmd_buffer.vkCmdDispatch( dispatch_x, 1, 1 );   // dispatch compute command

        export_buffer_memory_barrier.buffer = app.exp.export_buffer[i].buffer;
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

        foreach( s; 0 .. app.exp.step_size ) {

            //push_constant[0] = (( exp.sim_index + i + s ) % 2 ).toUint;
            push_constant[0] = (( i + s ) % 2 ).toUint;

            cmd_buffer.vkCmdBindPipeline( VK_PIPELINE_BIND_POINT_COMPUTE, app.sim.loop_pso.pipeline );    // bind compute app.sim.loop_pso.pipeline

            cmd_buffer.vkCmdBindDescriptorSets(         // VkCommandBuffer              commandBuffer
                VK_PIPELINE_BIND_POINT_COMPUTE,         // VkPipelineBindPoint          pipelineBindPoint
                app.sim.loop_pso.pipeline_layout,       // VkPipelineLayout             layout
                0,                                      // uint32_t                     firstSet
                1,                                      // uint32_t                     descriptorSetCount
                & app.descriptor.descriptor_set,        // const( VkDescriptorSet )*    pDescriptorSets
                0,                                      // uint32_t                     dynamicOffsetCount
                null                                    // const( uint32_t )*           pDynamicOffsets
            );

            cmd_buffer.vkCmdPushConstants( app.sim.loop_pso.pipeline_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, 8, push_constant.ptr ); // push constant

            cmd_buffer.vkCmdDispatch( dispatch_x, 1, 1 );   // dispatch compute command

            cmd_buffer.vkCmdPipelineBarrier(
                VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,   // VkPipelineStageFlags                 srcStageMask,
                VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,   // VkPipelineStageFlags                 dstStageMask,
                0,                                      // VkDependencyFlags                    dependencyFlags,
                0, null,                                // uint32_t memoryBarrierCount,         const VkMemoryBarrier* pMemoryBarriers,
                1, & sim_buffer_memory_barrier,         // uint32_t bufferMemoryBarrierCount,   const VkBufferMemoryBarrier* pBufferMemoryBarriers,
                0, null,                                // uint32_t imageMemoryBarrierCount,    const VkImageMemoryBarrier*  pImageMemoryBarriers,
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
    //app.sim.ping_pong = 1;
}



void destroyExpResources( ref VDrive_State app ) {
    // export resources
    if( !app.exp.export_pso.is_null ) app.destroy( app.exp.export_pso );
    if( !app.exp.export_memory.is_null ) app.exp.export_memory.destroyResources;
    if( !app.exp.export_buffer[0].is_null ) app.exp.export_buffer[0].destroyResources;
    if( !app.exp.export_buffer[1].is_null ) app.exp.export_buffer[1].destroyResources;
    if( !app.exp.export_buffer[0].view.is_null ) app.destroy( app.exp.export_buffer[0].view );
    if( !app.exp.export_buffer[1].view.is_null ) app.destroy( app.exp.export_buffer[1].view );
}