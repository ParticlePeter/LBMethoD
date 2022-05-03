//module settings;


//import gui;
import appstate;
import simulate;
import visualize;

import vdrive.util.array;
import vdrive.util.string;

import dlsl.matrix, dlsl.vector;

import core.stdc.stdio  : sprintf, printf;
import core.stdc.stdlib : atoi, atof;
import core.stdc.string : strcmp, strncmp, strlen;

import std.stdio;// : File;
import std.string : fromStringz, lineSplitter, strip;
import std.algorithm : splitter;

import std.traits;
import std.meta;



// Todo(pp): longterm, write a gui settings manager to load and store during runtime



enum setting;
int single_indent = 2;

private:

template Tuple( T... )              { alias Tuple = T; }
template is_enum( T )               { enum is_enum = is( T == enum ); }
template value_type( alias member ) { alias value_type = typeof( member ); }

template nameof( alias member ) {
    enum nameof = __traits( identifier, member );
}

template array_type( T ) {
    static if( isArray!T )  alias array_type = array_type!( ForeachType!T )[];
    else                    alias array_type = T;
}

template return_or_value_type( alias member ) {
    static if( is( typeof( member ) == function ))  alias return_or_value_type = ReturnType!member;
    else static if( isArray!( typeof( member )))    alias return_or_value_type = array_type!( typeof( member ));//return_or_value_type!( ForeachType!( typeof( member )))[];
    else                                            alias return_or_value_type = typeof( member );
}




void appendValue( T )( ref Block_Array!char settings, const T value ) {
    static if( is( T == char* ) || is( T : char[] )) {
        settings.append( "\"" );
        static if( is( T == char* ))    settings.append( value[ 0 .. value.strlen ] );
        else                            settings.append( value[ 0 .. value.ptr.strlen ] );
        settings.append( "\"" );
    }

    else static if( is( T : E[], E )) {
        settings.append( "[ " );
        if( value.length > 0 )
            appendValue( settings, value[0] );
        foreach( v; value[ 1 .. $ ] ) {
            settings.append( ", " );
            appendValue( settings, v );
        }
        settings.append( " ]" );
    }

    else static if( is_enum!T ) {
        settings.append( T.stringof );
        settings.append( '.' );

        // we borrow some memory from the settings Block_Array, which again sub allocates from Arena_array
        // then we actually don't need to do anything more, as the data extracted into the buffer / enum_z
        // will end up at the proper location within the settings
        settings.Size_T buffer_size = 128;
        settings.Size_T settings_length = settings.length;
        settings.length = settings_length + buffer_size;

        // we have to cast to void, as another constructor overload accepts and prefers arrays of element type
        auto enum_z = Dynamic_Array!char( cast( void[] )( settings.data[ settings_length .. $ ] ));
        value.toStringz( enum_z );
        settings.length = settings.length + enum_z.length - buffer_size - 1;    // last -1 ignores terminating \0

    }

    else static if( is( T == int    )) settings.length = settings.length + sprintf( settings.ptr + settings.length, "%i", value );
    else static if( is( T == uint   )) settings.length = settings.length + sprintf( settings.ptr + settings.length, "%u", value );
    else static if( is( T == float  )) settings.length = settings.length + sprintf( settings.ptr + settings.length, "%g", value );
    else static if( is( T == bool   )) settings.append( value ? "true" : "false" );
    else static if( is( T == string )) settings.append( value );
}




public void extractSettings( T )( ref T aggregate, string name, ref Block_Array!char settings, int indent = 0 ) {

    size_t max_member_length = 0;
    size_t tmp_member_length = 0;

    foreach( i; 0 .. indent )
        settings.append( " " );
    settings.append( name );
    settings.append( '\n' );

    indent += single_indent;

    static foreach( member; getSymbolsByUDA!( T, setting )) {
        tmp_member_length = nameof!member.length;
        if( max_member_length < tmp_member_length )
            max_member_length = tmp_member_length;
    }

    if( max_member_length % single_indent > 0 )
        max_member_length = single_indent * ( max_member_length / single_indent + 1 );

    // when a new member struct is found we usually add a new line to separate the new struct from pure values before.
    // this looks awkward when the parent struct has no data other than its member struct and in this case we omit the nl.
    // we capture this behavior in the following boolean, if its is still true in the extract struct section, omit the nl.
    bool first_member = true;

    // first extract all values, this includes arrays.
    static foreach( member; getSymbolsByUDA!( T, setting )) {

        static if( !is( typeof( member ) == struct ) && !isPointer!( typeof( member )) && !( is( typeof( member ) == function ) && is( ReturnType!member == void ))) {
            first_member = false;

            foreach( i; 0 .. indent )
                settings.append( " " );

            settings.append( nameof!member );

            tmp_member_length = nameof!member.length;
            foreach( i; tmp_member_length .. max_member_length )
                settings.append( " " );

            settings.append( " = " );

            static if( is( typeof( member ) == function ) && !isScalarType!( ReturnType!member )) {
                // mixin member return type string and member name string as stack variable and assign value with __traits call to get member data
                mixin( ReturnType!member.stringof ~ " " ~ nameof!member ~ " = __traits( getMember, aggregate, nameof!member );" );
                mixin( "settings.appendValue( " ~ nameof!member ~ " );" );  // mixin call to append value with the stack variable
            }

            else
                settings.appendValue!( return_or_value_type!member )( __traits( getMember, aggregate, nameof!member ));

            settings.append( '\n' );

        }
    }

    // now extract member structs, which can be value or pointer type
    static foreach( member; getSymbolsByUDA!( T, setting )) {

        static if( is( typeof( member ) == struct )) {
            if( first_member )  first_member = false;
            else settings.append( '\n' );
            extractSettings( __traits( getMember, aggregate, member.stringof ), member.stringof, settings, indent );

        } else static if( isPointer!( typeof( member )) && is( typeof( *member ) == struct )) {
            if( first_member )  first_member = false;
            else settings.append( '\n' );
            extractSettings( *__traits( getMember, aggregate, member.stringof ), member.stringof, settings, indent );
        }
    }
}



public void writeSettings( ref Block_Array!char settings, string filepath ) {
    auto file = File( filepath, "w" );
    file.write( settings.data );
}



public void writeSettings( T )( ref T aggregate, string name, Arena_Array* scratch = null, int single_indent = 2 ) {

    auto settings = Block_Array!char( *scratch );
    //settings.length = 1024;
    settings.reserve = 1024;

    .single_indent = single_indent;

    //int max_member_length = 0;
    //extractSettings( aggregate, settings, max_member_length, true  );
    extractSettings( aggregate, name, settings ); //, max_member_length, false );

    auto file = File( "settings.ini", "w" );
    file.write( settings.data );
}


alias write = writeSettings;










// Todo(pp): remove necessity for buffer_z, use existing buffer and replace the apropriate chars with '\0'


struct Token_Value( Line_Splitter ) {
    char[] token;
    char[] value;

    @disable this();
    @disable this( this );

    this( ref Line_Splitter ls, ref Block_Array!char buffer_z ) {
        line_splitter = & ls;
        this.buffer_z = & buffer_z;
        splitLine;
    }

    private Line_Splitter* line_splitter;
    private Block_Array!( char )* buffer_z;         // to convert value strings to stringz

    // return mutable copy of the original data with the termination '\0'
    //char* value_z() {
    //    if( buffer_z.length == 0 )
    //        value.toStringz( *buffer_z );
    //    return buffer_z.ptr;
    //}

    bool empty()            { return token == []; }
    bool has_value()        { return value != []; }
    bool token_no_value()   { return token != [] && value == []; }

    private bool is_front = false;

    ref Token_Value next() {
        if( buffer_z.length > 0 )
            buffer_z.reset;
        line_splitter.popFront;
        splitLine;
        return this;
    }

    private void splitLine() {

        if( line_splitter.empty ) {
            token = value = ( char[] ).init;
            return;
        }

        while( line_splitter.front.length == 0 )
            line_splitter.popFront;

        auto tv_splitter = line_splitter.front.splitter( '=' );
        token = tv_splitter.front.strip;

        tv_splitter.popFront;
        value = tv_splitter.empty ? ( char[] ).init : tv_splitter.front.strip;

        //if( tv_splitter.empty ) writeln;
        //writefln( "%s = %s", token, value );

    }
}



T extractValue( T )( char[] value, ref Block_Array!char buffer_z ) {
    T result;
    extractValue( value, buffer_z, result );
    return result;
}



void extractValue( T )( char[] value, ref Block_Array!char buffer_z, ref T result ) {

    // We must test for char[] before we test for general arrays, as char[] is a subset but requires different treatment.
    // Value of a char* or char[] is represented as "SomeStringValue" including the quotation marks.
    // To extract the individual characters we replace the last quotation mark with \0 -> "SomeStringValue\0
    // and copy a slice without first element into its target.
    static if( is( T == char* ) || is( T : char[] )) {
        auto value_length = value.length;
        value[ value_length - 1 ] = '\0';                               // overwrite last character, which is a " with '\0'
        result[ 0 .. value_length - 1 ] = value[ 1 .. value_length ];   // exclude starting " from assignment
    }

    // extract arrays recursively
    else static if( is( T : E[], E )) {

        // first handle array of arrays
        static if( is( ForeachType!T : F[], F )) {
            // After outer brackets are ditched we need to count up '[' and down ']' until zero.
            // Memorize the index where the first '[' and last ']' was found and send that
            // substring into extract extractValue recursively.
            // Eventually we will end up in the case above, which in term ends up in the
            // scalar types bellow.
            size_t depth = 0;
            size_t index_a, index_b = 0;
            char[] sub_value = value[ 1 .. $-1 ];       // omitting initial '[' and ']'

            foreach( ref r; result ) {
                sub_value = sub_value[ index_b .. $ ];  // update search string s.t. it skips the previously found sub-value
                foreach( i, c; sub_value ) {
                    if( c == '[' ) {
                        depth++;                        // increment depth at each occurrence of '[' character
                        if( depth == 1 ) {
                            index_a = i;                // the first time we find one '[' character, at depth of 1, we store its index in the value array
                        }
                    } else if( c == ']' ) {
                        depth--;                        // decrement depth at each occurrence of ']' character
                        if( depth == 0 ) {
                            index_b = i + 1;            // if we reached depth 0 again, we store the index AFTER the found closing ']' character
                            break;                      // and break out of the loop
                        }
                    }
                }
                // now we extract the current element with the
                r = extractValue!( typeof( r ))( sub_value[ index_a .. index_b ], buffer_z );
            }
        }

        // now handle elements
        else {
            auto value_range = value[ 1 .. $-1 ].splitter( ',' );
            foreach( ref v; result ) {
                if( !value_range.empty ) {
                    v = extractValue!( typeof( v ))( value_range.front.strip, buffer_z ); //.toStringz( buffer_z ).ptr );
                    value_range.popFront;
                }
            }
        }
    }

    // extract enums
    else static if( is_enum!T ) {
        // As we get each value as string_z and we serialized Typename.enum
        // we first get rid of the terminating \0 and then split on '.'
        if( value.length > 0 ) {
            auto enum_name = value.splitter( '.' );
            enum_name.popFront;
            result = enum_name.empty ? T.init : toEnum!T( enum_name.front );
        } else {
            result = T.init;
        }
    }

    else static if( is( T == bool )) {
        result = value == "true";
    }

    else {
        // convert to string_z
        auto value_z = value.toStringz( buffer_z ).ptr;

        // extract integral, floating point and boolean values
             static if( isIntegral!T )      result = cast( T )value_z.atoi;
        else static if( isFloatingPoint!T ) result = cast( T )value_z.atof;
    }
}



void extractAggregate( T, TV )( ref T aggregate, ref TV tv ) {

    // loop through all the next token value pairs until no value is available
    while( tv.has_value ) {

        // When a specific serialized setting cannot be found in the current aggregate
        // we never would advance the Token_Value line in this while loop.
        // To detect this we need a signal which becomes set to true if a the setting was found
        // otherwise, it stays false till the end of the loop. Then we have to advance.
        bool setting_found = false;

        // try to match every member marked as @setting to any parsed token
        static foreach( member; getSymbolsByUDA!( T, setting )) {

            // handle properties
            static if( is( typeof( member ) == function ) && is( ReturnType!member == void )) {
                if( tv.token == nameof!member ) {
                    // assume that the properties are not simple getters and setters, but apply logic in the process
                    mixin( Parameters!member[0].stringof ~ " " ~ nameof!member ~ ";" );                     // mixin stack variable with the name of aggregates member variable
                    mixin( "extractValue( tv.value, *tv.buffer_z, " ~ nameof!member ~ " );" );              // mixin valua extraction from string into reference to that variable
                    mixin( "__traits( getMember, aggregate, nameof!member ) = " ~ nameof!member ~ ";" );    // mixin call to set the extracted value with the member property
                    setting_found = true;
                    tv.next;
                }
            }

            // handle enum, numeric and boolean types
            else static if( !( is( typeof( member ) == struct ) || is( typeof( *member ) == struct ) || is( typeof( member ) == function ))) {  //( is_enum!( typeof( member )) || isScalarType!( typeof( member ))) {
                if( tv.token == nameof!member ) {
                    extractValue( tv.value, *tv.buffer_z, __traits( getMember, aggregate, nameof!member ));
                    setting_found = true;
                    tv.next;
                }
            }
        }

        // we must advance when a setting was not found to leave an infinite loop
        // and will ignore the setting. Todo(pp): issue a warning?
        if( !setting_found ) {
            tv.next;
        }
    }
}



void extractData( T, TV )( ref T aggregate, ref TV tv ) {
    // extract struct members
	aggregate.extractAggregate( tv );

     // extract member structs, which can be value or pointer type
    static foreach( member; getSymbolsByUDA!( T, setting )) {
        static if( is( typeof( member ) == struct )) {
            if( tv.token == member.stringof ) {
                //auto token = tv.token;
                extractAggregate( __traits( getMember, aggregate, member.stringof ), tv.next );
                extractData( __traits( getMember, aggregate, member.stringof ), tv );
            }
        }

        else static if( isPointer!( typeof( member )) && is( typeof( *member ) == struct )) {
            if( tv.token == member.stringof ) {
                extractAggregate( *__traits( getMember, aggregate, member.stringof ), tv.next );
                extractData( *__traits( getMember, aggregate, member.stringof ), tv );
            }
        }
    }
}



//alias Line_Splitter = LineSplitter!( cast( Flag )false, char[] );


public void parseSettings( T )( ref T aggregate, ref Arena_Array scratch, uint buffer_size = 4096 ) {

    //int[3][4][5] array_test;
    //pragma( msg, array_type!( typeof( array_test )).stringof );
    //pragma( msg, return_or_value_type!( array_test ));

    auto buffer = Block_Array!char( scratch );
    buffer.length = buffer_size;

    auto file = File( "settings.ini", "r" );
    auto data = file.rawRead( buffer.data );

    auto ls = data.lineSplitter;
    auto tv = Token_Value!( typeof( ls ))( ls, buffer );
    //pragma( msg, typeof( ls ).stringof );

    // fast forward empty lines
    while( !tv.has_value ) tv.next;

    // begin extraction
    extractData( aggregate, tv );
}