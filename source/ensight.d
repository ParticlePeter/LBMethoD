
import std.stdio;
import std.string : fromStringz;
//import data_grid;

// enum for the storage format of ensight geo and ensight variable format
enum Export_Format{ ascii, binary }


// struct to parametrize loading and storing of files
struct Export_Options {
    string  output;
    string  outGeo;
    string  outVar;
    uint    padding;
    char[12] variable;
    Export_Format format = Export_Format.ascii;
    bool    overwrite = false;
}


auto ref set_default_options( ref Export_Options options ) {
    import std.conv : to;
    import std.path;
    // Patch cases where no filepath or file extension was specified
    string basename = options.output.dup;

    if( options.output.extension == "" )                                // use the default .case extension
        options.output = basename.setExtension( "case" );

    if( options.outGeo == "" )                                          // derive geo filepath from caseFilepath
        options.outGeo = basename.setExtension( "geo" );

    else if( options.outGeo.extension == "" )                           // use the default .case extension
        options.outGeo = options.outGeo.setExtension( "geo" );

    if( options.outVar == "" ) {                                        // derive var filepath from caseFilepath and variable name
        options.variable[ 8 ] = '\0';
        options.outVar = basename.setExtension( options.variable.ptr.fromStringz.to!string ~ "_" );
    }

    else if( options.outGeo.extension == "" )                           // use the default .case extension
        options.outVar = options.outVar.setExtension( options.variable.ptr.fromStringz.to!string ~ "_" );

    import core.stdc.stdio : printf;
    printf( "\n" );

    return options;
}


// structure representing binary geometry file layout
private struct Export_Binary_Geometry {
    ubyte[80]   binary = 0;
    ubyte[80]   desc_1 = 0;
    ubyte[80]   desc_2 = 0;
    ubyte[80]   nodeId = 0;
    ubyte[80]   elemId = 0;
    ubyte[80]   extent = 0;
    float[ 6]   extentValues = 0;
    ubyte[80]   part = 0;
    uint  partNumber = 0;
    ubyte[80]   desc = 0;
    ubyte[80]   block = 0;
    uint[3]     ijkDim = 0;
    //float[ 3] origin = 0;
    //float[ 3] deltas = 0;
}


// structure for the binary header, it is 244
private struct Export_Binary_Variable_Header {
    ubyte[80]   desc = 0;       //  80 chars description
    ubyte[80]   part = 0;       //  80 chars "part"
    uint  partNumber = 0;       //   1 uint ( int per definition, but its unlikely that negative parts will be used )
    ubyte[80]   block = 0;      //  80 chars "block"
}                               // 244 chars / bytes in total


// struct for parsing TIME section and capturing timeset data
private struct Export_Time_Set_Data {
    string  description;
    uint    time_set;
    uint    number_of_steps;
    uint    filename_start_number;
    uint    filename_increment;
    float[] time_values;
}

nothrow:

void ensStoreCase(
    Export_Options          options,
    uint                    start_index,
    uint                    step_count,
    uint                    step_size,
    Export_Time_Set_Data*   time_set_data = null
    ) {

    ///////////////
    // case file //
    ///////////////

    // detect the minimum variable file time padding
    uint minPadding = 1;
    uint timeFactor = 10;
    while( step_count > ( timeFactor - 1 )) {
        timeFactor *= 10;
        ++minPadding;
    }

    // if the specified padding is not enough increase it
    if( minPadding > options.padding ) {
        options.padding = minPadding;
        //options.outVar = options.outVar.leftJustify( options.outVar.length + options.padding, '*' );
    }

    // append options.padding * to the end of the variable path specification in the case file
    import std.string : leftJustify, fromStringz;
    auto caseVarPath = options.outVar.leftJustify( options.outVar.length + options.padding, '*' );

    try {

        //
        // target directory
        //
        import std.stdio;
        import std.path : dirName, baseName;
        import std.file : exists, mkdirRecurse;

        // check if target directory exists and possibly create it
        if(!options.output.dirName.exists )
            //options.output..dirName.mkdir;
            options.output.dirName.mkdirRecurse;


        //
        // Output Buffer
        //
        import std.outbuffer;
        import std.typecons : scoped;

        auto caseData = scoped!OutBuffer;
        caseData.writefln( "FORMAT" );
        caseData.writefln( "type:                  ensight gold\n" );

        caseData.writefln( "GEOMETRY" );
        caseData.writefln( "model:                 %s\n", options.outGeo.baseName );

        caseData.writefln( "VARIABLE" );
        caseData.writefln( "vector per node: 1     %s %s\n", options.variable.ptr.fromStringz, caseVarPath.baseName );

        //caseData.writeln;
        caseData.writefln( "TIME" );
        if( time_set_data ) {
            caseData.writefln( "time set:              %s", time_set_data.time_set );
            caseData.writefln( "number of steps:       %s", time_set_data.number_of_steps );
            caseData.writefln( "filename start number: %s", time_set_data.filename_start_number );
            caseData.writefln( "filename increment:    %s", time_set_data.filename_increment );
            caseData.writefln( "time values:" );
            foreach( t; time_set_data.time_values ) {
                caseData.writefln( "%s", t );
            }
        } else {
            caseData.writefln( "time set:              1" );
            caseData.writefln( "number of steps:       %s", step_count );
            caseData.writefln( "filename start number: 0" );
            caseData.writefln( "filename increment:    1" );
            caseData.writefln( "time values:" );
            foreach( t; 0..step_count ) {
                caseData.writefln( "%s", cast( float )t * step_size );
            }
        }

        // write case file
        auto file = File( options.output, "w" );
        file.write( caseData.toString );
        file.close;

    } catch( Exception ) {}
}

void ensStoreGeo(
    in Export_Options   options,
    float[3]            minDomain,
    float[3]            maxDomain,
    float[3]            incDomain,
    uint [3]            cellCount
    ) {
    // geometry and variable files specified in the case file are specified relative to the case file
    // if the case was specified with a directory prefix, the same prefix must be prependet to the physical file location


    ///////////////////
    // geometry file //
    ///////////////////

    try {
        import std.outbuffer;
        import std.stdio : File;
        import std.typecons : scoped;


        // open filehandle
        auto file = File( options.outGeo, "w" );

        // write binary data file
        if( options.format == Export_Format.binary ) {

            // chunk of memory to be written, the size is variable dependent on the entry of
            // Export_Binary_Geometry.block in conjunction with Export_Binary_Geometry.ijkDim at the end of the struct
            // while writing it will be always the same size (block uniform)
            // but may differ while reading, hence the last 6 floats are attached without being part of the struct
            ubyte[ Export_Binary_Geometry.sizeof + 6 * float.sizeof ] binaryData;
            // structure representing binary geometry file layout
            auto binaryGeometry = cast( Export_Binary_Geometry* )binaryData.ptr;
            binaryGeometry.binary[0.. 8]    = cast( ubyte[] )"C Binary";
            binaryGeometry.desc_1[0..21]    = cast( ubyte[] )"full model structured";
            binaryGeometry.desc_2[0..21]    = cast( ubyte[] )"=====================";
            binaryGeometry.nodeId[0..11]    = cast( ubyte[] )"node id off";
            binaryGeometry.elemId[0..14]    = cast( ubyte[] )"element id off";
            binaryGeometry.extent[0.. 7]    = cast( ubyte[] )"extents";
            binaryGeometry.extentValues     = [ minDomain[0], maxDomain[0], minDomain[1], maxDomain[1], minDomain[2], maxDomain[2] ];
            binaryGeometry.part[0.. 4]      = cast( ubyte[] )"part";
            binaryGeometry.partNumber       = 1;
            binaryGeometry.desc[0..15]      = cast( ubyte[] )"full voxel grid";
            binaryGeometry.block[0..13]     = cast( ubyte[] )"block uniform";
            binaryGeometry.ijkDim           = cellCount[0..3];

            auto domainData = cast( float* )( binaryData.ptr + Export_Binary_Geometry.sizeof );
            domainData[0..3] = minDomain[0..3];            // binaryGeometry.origin
            domainData[3..6] = incDomain[0..3];            // binaryGeometry.deltas

            // write the raw binary data into file
            file.rawWrite( binaryData );

        } else {

            // use OutBuffer as sink for the ascii file structure
            auto geoData = scoped!OutBuffer;
            geoData.writefln( "Full model structured" );
            geoData.writefln( "=====================" );
            geoData.writefln( "node id off" );
            geoData.writefln( "element id off" );
            geoData.writefln( "extents" );
            geoData.writefln( "%12.5e%12.5e", minDomain[0], maxDomain[0] );
            geoData.writefln( "%12.5e%12.5e", minDomain[1], maxDomain[1] );
            geoData.writefln( "%12.5e%12.5e", minDomain[2], maxDomain[2] );
            geoData.writefln( "part\n%10d", 1 );
            geoData.writefln( "Full Voxel Grid" );
            geoData.writefln( "block uniform" );
            geoData.writefln( "%10d%10d%10d", cellCount[0], cellCount[1], cellCount[2] );
            geoData.writefln( "%12.5e", minDomain[0] );
            geoData.writefln( "%12.5e", minDomain[1] );
            geoData.writefln( "%12.5e", minDomain[2] );
            geoData.writefln( "%12.5e", incDomain[0] );
            geoData.writefln( "%12.5e", incDomain[1] );
            geoData.writefln( "%12.5e", incDomain[2] );

            // write formatted ascii file
            file.write( geoData.toString );
        }

        // close the geometry file
        file.close;

    } catch( Exception ) {}
}

auto ensGetBinaryVarHeader( const( char )* var_name ) {
    Export_Binary_Variable_Header header;
    var_name.ensGetBinaryVarHeader( & header );
    return header;
}


void ensGetBinaryVarHeader( const( char )* var_name, void* data ) {
    // cast the data into a struct BinaryHeader pointer and write into its memory
    auto binaryVariableHeader = cast( Export_Binary_Variable_Header* )data;
    binaryVariableHeader[0] = Export_Binary_Variable_Header();  // set to default values, [0] dereferences
    binaryVariableHeader[0].desc[0..8] = cast( ubyte[] )var_name[0..8];
    binaryVariableHeader[0].part[0..4] = cast( ubyte[] )"part";
    binaryVariableHeader[0].partNumber = 1;
    binaryVariableHeader[0].block[0..5] = cast( ubyte[] )"block";
}

size_t ensGetBinaryVarHeaderSize() {
    return Export_Binary_Variable_Header.sizeof;
}

auto ensGetAsciiVarHeader( string var_name ) {
    return var_name ~ "\npart\n         1\nblock\n";      // "%10d", 1
}


// filename should be filled with as many zeros at the end as many digets the highest index will have
void ensRawWriteBinaryVarFile( void[] data_with_header, char[] file_name, uint index ) {

    ////////////////////
    // variable files //
    ////////////////////

    // append suffix at the end of the file
    uint suffix = 1;
    uint constraint = 1;
    while( constraint <= index ) {
        file_name[ $ - suffix ] = cast( char )(( index / constraint ) % 10 + 48 );
        constraint *= 10;
        ++suffix;
    }


    try {
        import std.stdio : File;
        auto file = File( file_name, "w" );
        file.rawWrite( data_with_header );
        file.close;
    } catch( Exception ) {}
}
