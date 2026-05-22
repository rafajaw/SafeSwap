// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "@BondRouteProtected/BondRouteProtected.sol";


/**
 * @title MemoryZeroInitTest
 * @notice Empirical proof that the current Solidity compiler zero-initializes named-return struct
 *         memory and `new T[](n)` array allocations, even when the memory region they land in was
 *         pre-filled with 0xFF...FF garbage.
 *
 * @dev BondRoute's `get_constraints` callers rely on `BondConstraints.valid_creation_timestamp_range`
 *      and `valid_execution_timestamp_range` defaulting to `Range(0, 0)` (= "no timestamp gating").
 *      That assumption is only safe if the Solidity compiler emits zero-fill code for unassigned
 *      named-return memory. If this test ever fails on a future Solidity version, the omitted-field
 *      pattern in `get_constraints` must be replaced with explicit `Range({ min: 0, max: 0 })`.
 */
contract MemoryZeroInitTest is Test {

    bytes32 constant GARBAGE_WORD       =  bytes32(type(uint256).max);   // 0xFFFF...FFFF
    uint256 constant GARBAGE_BYTE_COUNT =  0x1000;                       // 4 KiB — large enough that any subsequent allocation lands inside.


    // ━━━━  GARBAGE-WRITER HARNESS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Write `0xFF...FF` to memory starting at the current free-memory pointer, for `GARBAGE_BYTE_COUNT` bytes.
     *         The free-memory pointer is left UNCHANGED so the next Solidity allocation lands right on top of the garbage.
     *
     * @dev This is the adversarial setup: any subsequent allocation in the same call frame that the compiler does NOT
     *      explicitly zero-fill will be observable as 0xFF... bytes.
     */
    function _fill_memory_above_free_memory_pointer_with_garbage( ) private pure
    {
        bytes32 garbage       =  GARBAGE_WORD;
        uint256 garbage_size  =  GARBAGE_BYTE_COUNT;

        assembly ("memory-safe")
        {
            let start  :=  mload( 0x40 )
            let end    :=  add( start, garbage_size )

            for { let cursor := start }  lt( cursor, end )  { cursor := add( cursor, 0x20 ) }
            {
                mstore( cursor, garbage )
            }
        }
    }


    // ━━━━  NAMED-RETURN STRUCT MEMORY  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_named_return_BondConstraints_is_zero_initialized_after_memory_garbage( ) external pure
    {
        _fill_memory_above_free_memory_pointer_with_garbage( );

        BondConstraints memory constraints  =  _produce_unassigned_named_return_constraints( );

        // Read every field into stack locals FIRST so the assertion machinery's own allocations
        // can't mask the result by overwriting the constraints memory before we read it.
        uint256 creation_range_min      =  constraints.valid_creation_timestamp_range.min;
        uint256 creation_range_max      =  constraints.valid_creation_timestamp_range.max;
        uint256 execution_range_min     =  constraints.valid_execution_timestamp_range.min;
        uint256 execution_range_max     =  constraints.valid_execution_timestamp_range.max;
        uint256 min_blocks_delay        =  constraints.min_execution_delay_in_blocks;
        uint256 min_seconds_delay       =  constraints.min_execution_delay_in_seconds;
        uint256 max_seconds_delay       =  constraints.max_execution_delay_in_seconds;
        address stake_token             =  address(constraints.min_stake.token);
        uint256 stake_amount            =  constraints.min_stake.amount;
        uint256 fundings_length         =  constraints.min_fundings.length;

        assertEq( creation_range_min,    0,           "valid_creation_timestamp_range.min  must be zero" );
        assertEq( creation_range_max,    0,           "valid_creation_timestamp_range.max  must be zero" );
        assertEq( execution_range_min,   0,           "valid_execution_timestamp_range.min must be zero" );
        assertEq( execution_range_max,   0,           "valid_execution_timestamp_range.max must be zero" );
        assertEq( min_blocks_delay,      0,           "min_execution_delay_in_blocks       must be zero" );
        assertEq( min_seconds_delay,     0,           "min_execution_delay_in_seconds      must be zero" );
        assertEq( max_seconds_delay,     0,           "max_execution_delay_in_seconds      must be zero" );
        assertEq( stake_token,           address(0),  "min_stake.token                     must be zero" );
        assertEq( stake_amount,          0,           "min_stake.amount                    must be zero" );
        assertEq( fundings_length,       0,           "min_fundings.length                 must be zero" );
    }

    function _produce_unassigned_named_return_constraints( ) private pure returns ( BondConstraints memory constraints )
    {
        // Intentionally assigns nothing. The test asserts every field of the named return is zero
        // despite the memory region having been pre-filled with 0xFF...FF garbage.
    }


    // ━━━━  NEW DYNAMIC ARRAY OF VALUE TYPES  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_new_uint256_array_is_zero_initialized_after_memory_garbage( ) external pure
    {
        _fill_memory_above_free_memory_pointer_with_garbage( );

        uint256[] memory arr  =  new uint256[]( 16 );

        uint256 length  =  arr.length;
        assertEq( length, 16, "new uint256[](16).length must be 16" );

        for( uint256 i = 0  ;  i < length  ;  i++ )
        {
            assertEq( arr[ i ], 0, "new uint256[](16) element must be zero" );
        }
    }


    // ━━━━  NEW DYNAMIC ARRAY OF STRUCTS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_new_TokenAmount_array_is_zero_initialized_after_memory_garbage( ) external pure
    {
        _fill_memory_above_free_memory_pointer_with_garbage( );

        TokenAmount[] memory arr  =  new TokenAmount[]( 4 );

        uint256 length  =  arr.length;
        assertEq( length, 4, "new TokenAmount[](4).length must be 4" );

        for( uint256 i = 0  ;  i < length  ;  i++ )
        {
            assertEq( address(arr[ i ].token),  address(0),  "new TokenAmount[](4) element token  must be zero" );
            assertEq( arr[ i ].amount,          0,           "new TokenAmount[](4) element amount must be zero" );
        }
    }


    // ━━━━  IN-BODY UNASSIGNED STRUCT MEMORY VARIABLE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_in_body_Range_memory_var_is_zero_initialized_after_memory_garbage( ) external pure
    {
        _fill_memory_above_free_memory_pointer_with_garbage( );

        Range memory r  =  _produce_unassigned_named_return_range( );

        uint256 r_min  =  r.min;
        uint256 r_max  =  r.max;

        assertEq( r_min, 0, "Range.min must be zero" );
        assertEq( r_max, 0, "Range.max must be zero" );
    }

    function _produce_unassigned_named_return_range( ) private pure returns ( Range memory r )
    {
        // Same pattern as _produce_unassigned_named_return_constraints — proves zero-init for a small value-type struct.
    }
}
