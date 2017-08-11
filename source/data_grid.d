
import std.stdio;

//import std.traits : isIntegral;
import std.container.array;
import dlsl.vector;


nothrow:

struct Data_Grid {

private:
	Array!vec3 cells;
public:
	vec4  minDomain;
	vec4  maxDomain;
	vec4  incDomain;
	uvec4 cellCount;

nothrow:
public:
	this( uvec4 cellCount, vec4 minDomain, vec4 inc_or_max_domain, bool increment_specified = false ) {
		this.cellCount = cellCount;
		this.minDomain = minDomain;

		if( increment_specified ) {
			incDomain = inc_or_max_domain;
			create_domain_from_incremet;
		} else {
			maxDomain = inc_or_max_domain;
			create_domain_from_min_max;
		}
	}

	void create_domain_from_min_max() {
		foreach( i; 0..4 )  incDomain[i] = cellCount[i] > 1  ?  ( maxDomain[i] - minDomain[i] ) / ( cellCount[i] - 1 )  :  0;
		cells.length = cellCount.x * cellCount.y * cellCount.z * cellCount.w;
	}

	void create_domain_from_incremet() {
		maxDomain = minDomain + incDomain * vec4( cellCount - 1 );
		cells.length = cellCount.x * cellCount.y * cellCount.z * cellCount.w;
	}

	uint I() {  return cellCount.x;  }
	uint J() {  return cellCount.y;  }
	uint K() {  return cellCount.z;  }
	uint T() {  return cellCount.w;  }

	ref vec3 opIndex( size_t i ) {  return cells[i];  }
	vec3 opIndexAssign( vec3 vec, size_t i ) {
		cells[i] = vec;
		return vec;
	}

	ref vec3 opIndex( size_t i, size_t j, size_t k, size_t t ) {
		return cells[I*J*K*t + I*J*k + I*j + i];
	}

	vec3 opIndexAssign( vec3 vec, size_t i, size_t j, size_t k, size_t t ) {
		cells[I*J*K*t + I*J*k + I*j + i] = vec;
		return vec;
	}

	ref const( Array!vec3 ) data() {  return cells;  }
	Array!vec3 dataCopy() {  return cells.dup;  }

	Data_Grid opBinary( string op )( Data_Grid rhs ) {
		static if( op == "-" ) {
			auto result = Data_Grid( cellCount, minDomain, maxDomain );
			foreach( i; 0..cells.length )
				result.cells[i] = cells[i] - rhs.cells[i];
			return result;
		}
		else static assert( 0, "Operator " ~ op ~ " not implemented" );
	}

	Data_Grid featureFlowField() {
		vec3 vi, vj, vk, vt;
		auto fff = Data_Grid( cellCount, minDomain, maxDomain );
		import dlsl.matrix;
		alias determinant det;
		foreach( t; 0..T ) {
			foreach( k; 0..K ) {
				foreach( j; 0..J ) {
					foreach( i; 0..I ) {
						if 		( i == 0 )		vi = ( this[i+1,j,k,t] - this[i,j,k,t] ) / incDomain.x;
						else if	( i == I-1 )	vi = ( this[i,j,k,t] - this[i-1,j,k,t] ) / incDomain.x;
						else		vi = 0.5 *  ( this[i+1,j,k,t]    - this[i-1,j,k,t] ) / incDomain.x;					

						if 		( j == 0 )		vj = ( this[i,j+1,k,t] - this[i,j,k,t] ) / incDomain.y;
						else if	( j == J-1 )	vj = ( this[i,j,k,t] - this[i,j-1,k,t] ) / incDomain.y;
						else		vj = 0.5 *  ( this[i,j+1,k,t]    - this[i,j-1,k,t] ) / incDomain.y;

						if 		( k == 0 )		vk = ( this[i,j,k+1,t] - this[i,j,k,t] ) / incDomain.z;
						else if	( k == K-1 )	vk = ( this[i,j,k,t] - this[i,j,k-1,t] ) / incDomain.z;
						else		vk = 0.5 *  ( this[i,j,k+1,t]    - this[i,j,k-1,t] ) / incDomain.z;

						if 		( t == 0 )		vt = ( this[i,j,k,t+1] - this[i,j,k,t] ) / incDomain.t;
						else if	( t == T-1 )	vt = ( this[i,j,k,t] - this[i,j,k,t-1] ) / incDomain.t;
						else		vt = 0.5 *  ( this[i,j,k,t+1]    - this[i,j,k,t-1] ) / incDomain.t;

						fff[i,j,k,t] = 
							1.0 / mat3( vi, vj, vk ).determinant * vec3( -mat3( vj, vk, vt ).determinant,
																		  mat3( vk, vt, vi ).determinant,
																		 -mat3( vt, vi, vj ).determinant );
					}
				}
			}
		}
		return fff;
	}

	void storeCells( string path ) {
		try {
			auto file = File( path, "w" );
			file.rawWrite(( &cells.front())[0..cells.length] );
		} catch( Exception ) {}
	}

	void loadCells( string path ) {
		try {
			auto file = File( path, "r" );
			file.rawRead(( &cells.front())[0..cells.length] );
		} catch( Exception ) {}
	}

	void printCells() {
		try{
			float minT = minDomain.w;
			float incT = incDomain.w;
			foreach( t; 0..T )
				foreach( k; 0..K )
					foreach( j; 0..J )
						foreach( i; 0..I )
							writeln( "T: ", minT + t * incT, " : ", this[i, j, k, t] );
		} catch( Exception ) {}
	}
}
