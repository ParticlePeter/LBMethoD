

/*
// structure ensight binary vector variable of 127 * 127 * 3 floats 
private struct BinaryVariableHeader {
	ubyte[80]		    desc = 0;     // 80 chars description
	ubyte[80]		    part = 0;     // 80 chars "part"
	uint  	      partNumber = 0;     // 1 uint ( int per definition, but its unlikely that negative parts will be used )
	ubyte[80]		    blck = 0;     // 80 chars "block"
	float[127][127][3] 	data;
}


int main() {

    //import core.stdc.stdlib : malloc;
    //void* scratch = malloc( 1024 );

    import std.stdio;
    writeln;

    //int[15] coords_x = [ 125, 124, 123, 122, 117, 111, 104, 65, 31, 30, 21, 13, 11, 10, 9 ];
    //write( "[ " );
    //foreach( c; coords_x[ 0 .. $-2 ] ) {
    //    write( c - 2, ", " );
    //}
    //writeln( coords_x[ $-1 ] - 2, " ]\n" );

    int[15] coords_x = [ 123, 122, 121, 120, 115, 109, 102, 63, 29, 28, 19, 11, 9, 8, 7 ];

    import std.file;
    auto varFile = read( "..//Ensight//Ensight_LDC_127_127//LDC_D2Q9.velocity_009" );
	auto binaryHeader = cast( BinaryVariableHeader* )( varFile.ptr );

    writeln( varFile.length );
    writeln( BinaryVariableHeader.sizeof);

    foreach( c; coords_x ) {
        writefln( "%+.8f,       %-3.8f", binaryHeader.data[ 0 ][ c ][ 63 ], binaryHeader.data[ 0 ][ 63 ][ c ] );
    }

    return 0;
}
*/





// structure ensight binary vector variable of 127 * 127 * 3 floats 
struct BinaryVariableHeader {
    ubyte[80]           desc = 0;     // 80 chars description
    ubyte[80]           part = 0;     // 80 chars "part"
    uint          partNumber = 0;     // 1 uint ( int per definition, but its unlikely that negative parts will be used )
    ubyte[80]           blck = 0;     // 80 chars "block"
}

// structure ensight binary vector variable of 127 * 127 * 3 floats 
struct BinaryVariable {
    BinaryVariableHeader header;
    alias header this;

    float[ 127 *127 *3 ]  data;

    float val( size_t x, size_t y, size_t c ) {
        return data[ 127 * 127 * c + 127 * y + x ];
    }
}


auto val( float* data, size_t x, size_t y, size_t c ) {
    return data[ 127 * 127 * c + 127 * y + x ];
    //return 127 * 127 * c + 127 * y + x;
}



int main() {

    //import core.stdc.stdlib : malloc;
    //void* scratch = malloc( 1024 );

    import std.stdio;
    writeln;

    //int[15] coords_x = [ 125, 124, 123, 122, 117, 111, 104, 65, 31, 30, 21, 13, 11, 10, 9 ];
    //write( "[ " );
    //foreach( c; coords_x[ 0 .. $-2 ] ) {
    //    write( c - 2, ", " );
    //}
    //writeln( coords_x[ $-1 ] - 2, " ]\n" );

    int[15] coords_y = [ 124, 123, 122, 121, 108,  93,  78, 63, 57, 29, 21, 12, 8, 7, 6 ];
    int[15] coords_x = [ 123, 122, 121, 120, 115, 109, 102, 63, 29, 28, 19, 11, 9, 8, 7 ];


    
    import core.stdc.stdlib : malloc, free;
    auto  buffer_size = 127 * 127 * 3 * float.sizeof;
    void* buffer = malloc( buffer_size );


    enum Ghia {
        Re____100,
        Re____400,
        Re__1_000,
        Re__3_200,
        Re__5_000,
        Re__7_500,
        Re_10_000,
        count, 
    }

    string[ Ghia.count ] ensight_var_file = [
        "..//Ensight//LDC_D2Q9.re__100__020",
        "..//Ensight//LDC_D2Q9.re__400__020",
        "..//Ensight//LDC_D2Q9.re_1000__020",
        "..//Ensight//LDC_D2Q9.re_3200__020",
        "..//Ensight//LDC_D2Q9.re_5000__020",
        "..//Ensight//LDC_D2Q9.re_7500__020",
        "..//Ensight//LDC_D2Q9.re10000__020",
    ];

    float[15][ Ghia.count ] ghia_u = [
        [  0.84123,  0.78871,  0.73722,  0.68717,  0.23151,  0.00332, -0.13641, -0.20581, -0.21090, -0.15662, -0.10150, -0.06434, -0.04775, -0.04192, -0.03717 ],
        [  0.75837,  0.68439,  0.61756,  0.55892,  0.29093,  0.16256,  0.02135, -0.11477, -0.17119, -0.32726, -0.24299, -0.14612, -0.10338, -0.09266, -0.08186 ],
        [  0.65928,  0.57492,  0.51117,  0.46604,  0.33304,  0.18719,  0.05702, -0.06080, -0.10648, -0.27805, -0.38289, -0.29730, -0.22220, -0.20196, -0.18109 ],
        [  0.53236,  0.48296,  0.46547,  0.46101,  0.34682,  0.19791,  0.07156, -0.04272, -0.86636, -0.24427, -0.34323, -0.41933, -0.37827, -0.35344, -0.32407 ],
        [  0.48223,  0.46120,  0.45992,  0.46036,  0.33556,  0.20087,  0.08183, -0.03039, -0.07404, -0.22855, -0.33050, -0.40435, -0.43643, -0.42901, -0.41165 ],
        [  0.47244,  0.47048,  0.47323,  0.47167,  0.34228,  0.20591,  0.08342, -0.03800, -0.07503, -0.23176, -0.32393, -0.38324, -0.43025, -0.43590, -0.43154 ],
        [  0.47221,  0.47783,  0.48070,  0.47804,  0.34635,  0.20673,  0.08344,  0.03111, -0.07540, -0.23186, -0.32709, -0.38000, -0.41657, -0.42537, -0.42735 ],
    ];

    float[15][ Ghia.count ] ghia_v = [
        [ -0.05906, -0.07391, -0.08864, -0.10313, -0.16914, -0.22445, -0.24533,  0.05454,  0.17527,  0.17507,  0.16077,  0.12317,  0.10890,  0.10091,  0.09233 ],
        [ -0.12146, -0.15663, -0.19254, -0.22847, -0.23827, -0.44993, -0.38598,  0.05188,  0.30174,  0.30203,  0.28124,  0.22965,  0.20920,  0.19713,  0.18360 ],
        [ -0.21388, -0.27669, -0.33714, -0.39188, -0.51550, -0.42665, -0.31966,  0.02526,  0.32235,  0.33075,  0.37095,  0.32627,  0.30353,  0.29012,  0.27485 ],
        [ -0.39017, -0.47425, -0.52357, -0.54053, -0.44307, -0.37401, -0.31184,  0.00999,  0.28188,  0.29030,  0.37119,  0.42768,  0.41906,  0.40917,  0.39560 ],
        [ -0.49774, -0.55069, -0.55408, -0.52876, -0.41442, -0.36214, -0.30018,  0.00945,  0.27280,  0.28066,  0.35368,  0.42951,  0.43648,  0.43329,  0.42447 ],
        [ -0.53858, -0.55216, -0.52347, -0.48590, -0.41050, -0.36213, -0.30448,  0.00824,  0.27348,  0.28117,  0.35060,  0.41824,  0.43564,  0.44030,  0.43979 ],
        [ -0.54302, -0.52987, -0.49099, -0.45863, -0.41496, -0.36737, -0.30719,  0.00831,  0.27224,  0.28003,  0.35070,  0.41487,  0.43124,  0.43733,  0.43983 ],
    ];
/*
    size_t offset_u = 0, offset_v = 0;  // try to offset in case center calc is not good 
    foreach( g; 0 .. cast( size_t )Ghia.count ) {
        // open ensight var file
        import std.file;
        auto file = File( ensight_var_file[ g ], "r" );  // "..//Ensight//Ensight_LDC_127_127//LDC_D2Q9.velocity_009"
        file.seek( BinaryVariableHeader.sizeof, SEEK_SET );
        auto varFile = file.rawRead( buffer[ 0 .. buffer_size ] );
        auto data = cast( float* )( varFile.ptr );

        writeln;
        foreach( i, c; coords_x ) {
            writefln( "%+.8f / %+.8f = %+.8f,      %+.8f / %+.8f = %+.8f", 
                ghia_u[ g ][ i ], data.val( 63, c + offset_u, 0 ) * 10.0, ghia_u[ g ][ i ] / data.val( 63, c + offset_u, 0 ) / 10.0,
                ghia_v[ g ][ i ], data.val( c + offset_v, 63, 2 ) * 10.0, ghia_v[ g ][ i ] / data.val( c + offset_v, 63, 2 ) / 10.0);
        }
    }
*/

    int[15] coords_y = [ 126, 125, 124, 123, 110, 95, 80, 65, 59, 31, 23, 14, 10, 9, 8 ];
    writeln;
    write( "{ ");
    foreach( i; coords_y ) {
        write( i - 2, ", " );
    }
    writeln( "};" );

    free( buffer );
    return 0;
}