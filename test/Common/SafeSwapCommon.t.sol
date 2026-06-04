// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ISafeSwapCommonTests } from "@test/Common/TestManifest.sol";
import { SafeSwapTestHelper } from "@test/helpers/SafeSwapTestHelper.t.sol";
import "@SafeSwapCommon/SafeSwapCommon.sol";
import "@SafeSwapCommon/Definitions.sol";
import "@SafeSwapCommon/Types.sol";
import { IERC20, TokenAmount, BondContext, NATIVE_TOKEN, BONDROUTE_ADDRESS } from "@BondRouteProtected/BondRouteProtected.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { Currency } from "@UniswapV4Core/types/Currency.sol";
import { IHooks } from "@UniswapV4Core/interfaces/IHooks.sol";
import { LPFeeLibrary } from "@UniswapV4Core/libraries/LPFeeLibrary.sol";


contract SafeSwapCommonHarness {

    function hash_pool_info( PoolInfo memory pool_info ) external pure returns ( bytes32 )
    {
        return SafeSwapCommon.hash_pool_info( pool_info );
    }

    function hash_token_amount( TokenAmount memory token_amount ) external pure returns ( bytes32 )
    {
        return SafeSwapCommon.hash_token_amount( token_amount );
    }

    function hash_token_amount_and_check_free_memory_pointer( TokenAmount memory token_amount ) external pure returns ( bytes32 result, bool pointer_restored )
    {
        uint256 pointer_before;
        uint256 pointer_after;

        assembly ("memory-safe") { pointer_before := mload( 0x40 ) }
        result  =  SafeSwapCommon.hash_token_amount( token_amount );
        assembly ("memory-safe") { pointer_after := mload( 0x40 ) }

        pointer_restored  =  pointer_before == pointer_after;
    }

    function base_fee_units( uint16 base_fee_bps ) external pure returns ( uint24 )
    {
        return SafeSwapCommon.base_fee_units( base_fee_bps );
    }

    function compute_repricing_fee_pips( uint256 amount_in, uint256 amount_out, uint160 sqrt_price_after_x96, bool zero_for_one, uint8 capture_percent, uint24 base_fee_pips ) external pure returns ( uint24 )
    {
        return SafeSwapCommon.compute_repricing_fee_pips( amount_in, amount_out, sqrt_price_after_x96, zero_for_one, capture_percent, base_fee_pips );
    }

    function build_pool_key( IERC20 token_in, IERC20 token_out, uint24 fee, int24 tick_spacing, address hook_address ) external pure returns ( PoolKey memory )
    {
        return SafeSwapCommon.build_pool_key( token_in, token_out, fee, tick_spacing, hook_address );
    }

    function sort_token_amount_pair( TokenAmount memory pair_a, TokenAmount memory pair_b )
    external pure returns ( IERC20 token0, uint256 amount0, IERC20 token1, uint256 amount1 )
    {
        return SafeSwapCommon.sort_token_amount_pair( pair_a, pair_b );
    }

    function calculate_swap_stake( TokenAmount memory funding ) external pure returns ( TokenAmount memory )
    {
        return SafeSwapCommon.calculate_swap_stake( funding );
    }

    function calculate_normalized_liquidity_stake(
        uint160 sqrtPriceX96,
        IERC20 token0,
        IERC20 token1,
        uint256 amount0,
        uint256 amount1,
        IERC20 preferred_stake_token
    ) external pure returns ( TokenAmount memory )
    {
        return SafeSwapCommon.calculate_normalized_liquidity_stake( sqrtPriceX96, token0, token1, amount0, amount1, preferred_stake_token );
    }

    function calculate_protocol_fee( uint256 amount_out, uint24 pool_fee ) external pure returns ( uint256 protocol_fee, uint256 user_amount )
    {
        return SafeSwapCommon.calculate_protocol_fee( amount_out, pool_fee );
    }

    function settle_input( IPoolManager pool_manager, BondContext memory context, IERC20 token, uint256 amount ) external
    {
        SafeSwapCommon.settle_input( pool_manager, context, token, amount );
    }

    function settle_and_take(
        IPoolManager pool_manager,
        BondContext memory context,
        IERC20 token_in,
        IERC20 token_out,
        uint256 amount_in,
        uint256 user_output,
        uint256 protocol_fee,
        address fee_recipient
    ) external
    {
        SafeSwapCommon.settle_and_take( pool_manager, context, token_in, token_out, amount_in, user_output, protocol_fee, fee_recipient );
    }

    receive( ) external payable { }
}


contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals  =  18;
    uint256 public totalSupply;

    mapping( address => uint256 ) public balanceOf;
    mapping( address => mapping( address => uint256 ) ) public allowance;

    constructor( string memory token_name, string memory token_symbol )
    {
        name    =  token_name;
        symbol  =  token_symbol;
    }

    function mint( address to, uint256 amount ) external
    {
        balanceOf[ to ]  =  balanceOf[ to ] + amount;
        totalSupply      =  totalSupply + amount;
    }

    function approve( address spender, uint256 amount ) external returns ( bool )
    {
        allowance[ msg.sender ][ spender ]  =  amount;
        return true;
    }

    function transfer( address to, uint256 amount ) external returns ( bool )
    {
        balanceOf[ msg.sender ]  =  balanceOf[ msg.sender ] - amount;
        balanceOf[ to ]          =  balanceOf[ to ] + amount;
        return true;
    }

    function transferFrom( address from, address to, uint256 amount ) external returns ( bool )
    {
        if(  allowance[ from ][ msg.sender ] != type(uint256).max  )  allowance[ from ][ msg.sender ]  =  allowance[ from ][ msg.sender ] - amount;

        balanceOf[ from ]  =  balanceOf[ from ] - amount;
        balanceOf[ to ]    =  balanceOf[ to ] + amount;
        return true;
    }
}


contract MockBondRouteFunding {

    function transfer_funding( address to, IERC20 token, uint256 amount, BondContext memory context )
    external returns ( uint256 updated_index, uint256 new_available_amount )
    {
        for(  uint256 i = 0  ;  i < context.fundings.length  ;  i = i + 1  )
        {
            if(  context.fundings[ i ].token == token  )
            {
                if(  address(token) == address(0)  )
                {
                    ( bool success, )  =  to.call{ value: amount }( "" );
                    require( success, "native transfer failed" );
                }
                else
                {
                    MockERC20(address(token)).transfer( to, amount );
                }

                return ( i, context.fundings[ i ].amount - amount );
            }
        }

        revert( "funding not found" );
    }

    receive( ) external payable { }
}


contract MockPoolManagerSettlement {
    IERC20 public last_synced_currency;
    uint256 public settle_call_count;
    uint256 public settle_value_received;

    function sync( Currency currency ) external
    {
        last_synced_currency  =  IERC20(Currency.unwrap( currency ));
    }

    function settle( ) external payable returns ( uint256 )
    {
        settle_call_count     =  settle_call_count + 1;
        settle_value_received =  settle_value_received + msg.value;
        return msg.value;
    }

    function take( Currency currency, address to, uint256 amount ) external
    {
        if(  amount == 0  )  return;

        address token  =  Currency.unwrap( currency );
        if(  token == address(0)  )
        {
            ( bool success, )  =  to.call{ value: amount }( "" );
            require( success, "native take failed" );
        }
        else
        {
            MockERC20(token).transfer( to, amount );
        }
    }

    receive( ) external payable { }
}


/**
 * @title SafeSwapCommonTest
 * @notice Tests shared SafeSwap math, hashing, pool-key, stake, fee, and settlement helpers.
 * @dev Implements ISafeSwapCommonTests from TestManifest.sol.
 */
contract SafeSwapCommonTest is ISafeSwapCommonTests, SafeSwapTestHelper {

    uint160 private constant SQRT_PRICE_1_1  =  79228162514264337593543950336;
    uint160 private constant SQRT_PRICE_4_1  =  158456325028528675187087900672;

    SafeSwapCommonHarness private harness;
    MockERC20 private token_a;
    MockERC20 private token_b;

    function setUp( ) public
    {
        harness  =  new SafeSwapCommonHarness( );
        token_a  =  new MockERC20( "Token A", "TKNA" );
        token_b  =  new MockERC20( "Token B", "TKNB" );

        if(  address(token_a) > address(token_b)  )  ( token_a, token_b )  =  ( token_b, token_a );
    }

    function test_hash_pool_info_matches_abi_encoded_type_hash( )
    external  view
    {
        PoolInfo memory pool_info  =  PoolInfo({ base_fee_bps: 30, rebate_percent: 50, tick_spacing: 60 });
        bytes32 expected           =  keccak256( abi.encode( keccak256( "PoolInfo(uint16 base_fee_bps,uint8 rebate_percent,int24 tick_spacing)" ), pool_info.base_fee_bps, pool_info.rebate_percent, pool_info.tick_spacing ) );

        assertEq( harness.hash_pool_info( pool_info ), expected, "PoolInfo hash should match the EIP-712 type hash layout." );
    }

    function test_hash_pool_info_changes_when_base_fee_changes( )
    external  view
    {
        PoolInfo memory pool_a  =  PoolInfo({ base_fee_bps: 30, rebate_percent: 50, tick_spacing: 60 });
        PoolInfo memory pool_b  =  PoolInfo({ base_fee_bps: 31, rebate_percent: 50, tick_spacing: 60 });

        assertTrue( harness.hash_pool_info( pool_a ) != harness.hash_pool_info( pool_b ), "Changing base fee should change PoolInfo hash." );
    }

    function test_hash_pool_info_changes_when_rebate_percent_changes( )
    external  view
    {
        PoolInfo memory pool_a  =  PoolInfo({ base_fee_bps: 30, rebate_percent: 50, tick_spacing: 60 });
        PoolInfo memory pool_b  =  PoolInfo({ base_fee_bps: 30, rebate_percent: 60, tick_spacing: 60 });

        assertTrue( harness.hash_pool_info( pool_a ) != harness.hash_pool_info( pool_b ), "Changing rebate percent should change PoolInfo hash." );
    }

    function test_hash_pool_info_changes_when_tick_spacing_changes( )
    external  view
    {
        PoolInfo memory pool_a  =  PoolInfo({ base_fee_bps: 30, rebate_percent: 50, tick_spacing: 60 });
        PoolInfo memory pool_b  =  PoolInfo({ base_fee_bps: 30, rebate_percent: 50, tick_spacing: 10 });

        assertTrue( harness.hash_pool_info( pool_a ) != harness.hash_pool_info( pool_b ), "Changing tick spacing should change PoolInfo hash." );
    }

    function test_hash_token_amount_matches_abi_encoded_type_hash( )
    external  view
    {
        TokenAmount memory token_amount  =  TokenAmount({ token: IERC20(address(token_a)), amount: 123 });
        bytes32 expected                 =  keccak256( abi.encode( keccak256( "TokenAmount(address token,uint256 amount)" ), token_amount.token, token_amount.amount ) );

        assertEq( harness.hash_token_amount( token_amount ), expected, "TokenAmount hash should match the EIP-712 type hash layout." );
    }

    function test_hash_token_amount_changes_when_token_changes( )
    external  view
    {
        TokenAmount memory amount_a  =  TokenAmount({ token: IERC20(address(token_a)), amount: 123 });
        TokenAmount memory amount_b  =  TokenAmount({ token: IERC20(address(token_b)), amount: 123 });

        assertTrue( harness.hash_token_amount( amount_a ) != harness.hash_token_amount( amount_b ), "Changing token should change TokenAmount hash." );
    }

    function test_hash_token_amount_changes_when_amount_changes( )
    external  view
    {
        TokenAmount memory amount_a  =  TokenAmount({ token: IERC20(address(token_a)), amount: 123 });
        TokenAmount memory amount_b  =  TokenAmount({ token: IERC20(address(token_a)), amount: 124 });

        assertTrue( harness.hash_token_amount( amount_a ) != harness.hash_token_amount( amount_b ), "Changing amount should change TokenAmount hash." );
    }

    function test_hash_token_amount_restores_free_memory_pointer( )
    external  view
    {
        TokenAmount memory token_amount  =  TokenAmount({ token: IERC20(address(token_a)), amount: 123 });
        ( , bool pointer_restored )      =  harness.hash_token_amount_and_check_free_memory_pointer( token_amount );

        assertTrue( pointer_restored, "hash_token_amount should restore the free memory pointer." );
    }

    function test_base_fee_units_converts_basis_points_to_v4_pips( )
    external  view
    {
        assertEq( harness.base_fee_units( 30 ), 3000, "30 bps should convert to 3000 v4 pips." );
    }

    function test_base_fee_units_accepts_zero_base_fee( )
    external  view
    {
        assertEq( harness.base_fee_units( 0 ), 0, "Zero bps should convert to zero pips." );
    }

    function test_base_fee_units_accepts_maximum_bcd_base_fee( )
    external  view
    {
        assertEq( harness.base_fee_units( 999 ), 99900, "999 bps should convert to 99900 v4 pips." );
    }

    // sqrt price for pool price 1:1 (2^96): output and input are valued 1:1, so surplus = amount_out − amount_in.
    uint160 internal constant _SQRT_PRICE_1_1  =  79228162514264337593543950336;

    function test_compute_repricing_fee_pips_returns_base_fee_when_no_surplus( )
    external  view
    {
        // Output (valued at the post-swap price) does not exceed the input → no repricing surplus → base fee only.
        assertEq( harness.compute_repricing_fee_pips( 100, 100, _SQRT_PRICE_1_1, true, 50, 3000 ), 3000, "No surplus should charge only the base fee." );
    }

    function test_compute_repricing_fee_pips_charges_capture_percent_of_surplus( )
    external  view
    {
        // in 100, out 110 at price 1 → surplus 10 (10% of input). Capture 50% → 5% repricing = 50_000 pips; + base 3_000.
        assertEq( harness.compute_repricing_fee_pips( 100, 110, _SQRT_PRICE_1_1, true, 50, 3000 ), 53000, "50% capture of a 10% surplus should add 50_000 pips." );
    }

    function test_compute_repricing_fee_pips_is_symmetric_across_swap_direction( )
    external  view
    {
        // Same surplus moving the price up (zeroForOne) or down (oneForZero) must charge the same fee.
        uint24 fee_zero_for_one  =  harness.compute_repricing_fee_pips( 100, 110, _SQRT_PRICE_1_1, true,  50, 3000 );
        uint24 fee_one_for_zero  =  harness.compute_repricing_fee_pips( 100, 110, _SQRT_PRICE_1_1, false, 50, 3000 );

        assertEq( fee_zero_for_one, fee_one_for_zero, "Repricing fee must be direction-neutral for equal surplus." );
        assertEq( fee_zero_for_one, 53000, "Both directions should charge 50% of the surplus." );
    }

    function test_compute_repricing_fee_pips_caps_repricing_component( )
    external  view
    {
        // in 100, out 300 at price 1 → surplus 200 (200% of input); 90% capture would be 1_800_000 pips → capped at 100_000.
        assertEq( harness.compute_repricing_fee_pips( 100, 300, _SQRT_PRICE_1_1, true, 90, 3000 ), 103000, "Repricing component should cap at MAX_REPRICING_FEE_PIPS." );
    }

    function test_compute_repricing_fee_pips_caps_total_swap_fee( )
    external  view
    {
        // Base 450_000 + capped repricing 100_000 = 550_000 → clamped to MAX_TOTAL_FEE_PIPS.
        assertEq( harness.compute_repricing_fee_pips( 100, 300, _SQRT_PRICE_1_1, true, 90, 450000 ), MAX_TOTAL_FEE_PIPS, "Total swap fee should cap at MAX_TOTAL_FEE_PIPS." );
    }

    function test_compute_repricing_fee_pips_allows_zero_capture_percent( )
    external  view
    {
        assertEq( harness.compute_repricing_fee_pips( 100, 300, _SQRT_PRICE_1_1, true, 0, 3000 ), 3000, "Zero capture should not add a repricing fee." );
    }

    function test_compute_repricing_fee_pips_allows_ninety_percent_capture( )
    external  view
    {
        // in 100, out 110 → surplus 10 (10%). Capture 90% → 9% repricing = 90_000 pips; + base 3_000.
        assertEq( harness.compute_repricing_fee_pips( 100, 110, _SQRT_PRICE_1_1, true, 90, 3000 ), 93000, "90% capture of a 10% surplus should add 90_000 pips." );
    }

    function test_build_pool_key_sorts_currencies_independently_of_user_token_order( )
    external  view
    {
        address hook          =  address(0x1234);
        PoolKey memory key_a  =  harness.build_pool_key( IERC20(address(token_a)), IERC20(address(token_b)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, hook );
        PoolKey memory key_b  =  harness.build_pool_key( IERC20(address(token_b)), IERC20(address(token_a)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, hook );

        assertEq( Currency.unwrap( key_a.currency0 ), Currency.unwrap( key_b.currency0 ), "currency0 should be independent of input order." );
        assertEq( Currency.unwrap( key_a.currency1 ), Currency.unwrap( key_b.currency1 ), "currency1 should be independent of input order." );
    }

    function test_build_pool_key_preserves_dynamic_fee_flag( )
    external  view
    {
        PoolKey memory key  =  harness.build_pool_key( IERC20(address(token_a)), IERC20(address(token_b)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, address(0x1234) );

        assertEq( key.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG, "Pool key should preserve the dynamic fee flag." );
    }

    function test_build_pool_key_preserves_hook_address_as_pool_identity( )
    external  view
    {
        address hook        =  address(0x1234);
        PoolKey memory key  =  harness.build_pool_key( IERC20(address(token_a)), IERC20(address(token_b)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, hook );

        assertEq( address(key.hooks), hook, "Pool key should preserve the hook address." );
    }

    function test_build_pool_key_preserves_tick_spacing( )
    external  view
    {
        PoolKey memory key  =  harness.build_pool_key( IERC20(address(token_a)), IERC20(address(token_b)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, address(0x1234) );

        assertEq( key.tickSpacing, 60, "Pool key should preserve tick spacing." );
    }

    function test_sort_token_amount_pair_orders_tokens_and_amounts_together( )
    external  view
    {
        TokenAmount memory amount_a  =  TokenAmount({ token: IERC20(address(token_b)), amount: 200 });
        TokenAmount memory amount_b  =  TokenAmount({ token: IERC20(address(token_a)), amount: 100 });

        ( IERC20 token0, uint256 amount0, IERC20 token1, uint256 amount1 )  =  harness.sort_token_amount_pair( amount_a, amount_b );

        assertEq( address(token0), address(token_a), "token0 should be the lower token address." );
        assertEq( amount0, 100, "amount0 should stay attached to token0." );
        assertEq( address(token1), address(token_b), "token1 should be the higher token address." );
        assertEq( amount1, 200, "amount1 should stay attached to token1." );
    }

    function test_sort_token_amount_pair_reverts_when_tokens_are_identical( )
    external
    {
        TokenAmount memory amount_a  =  TokenAmount({ token: IERC20(address(token_a)), amount: 100 });
        TokenAmount memory amount_b  =  TokenAmount({ token: IERC20(address(token_a)), amount: 200 });

        vm.expectRevert( bytes( TOKENS_MUST_BE_DIFFERENT ) );
        harness.sort_token_amount_pair( amount_a, amount_b );
    }

    function test_calculate_swap_stake_returns_one_percent_of_input_amount( )
    external  view
    {
        TokenAmount memory stake  =  harness.calculate_swap_stake( TokenAmount({ token: IERC20(address(token_a)), amount: 10_000 }) );

        assertEq( address(stake.token), address(token_a), "Stake token should match funding token." );
        assertEq( stake.amount, 100, "Swap stake should be one percent of funding amount." );
    }

    function test_calculate_swap_stake_rounds_dust_up_to_one_wei( )
    external  view
    {
        TokenAmount memory stake  =  harness.calculate_swap_stake( TokenAmount({ token: IERC20(address(token_a)), amount: 1 }) );

        assertEq( stake.amount, 1, "Dust swap stake should round up to one wei." );
    }

    function test_calculate_normalized_liquidity_stake_defaults_to_token0( )
    external  view
    {
        TokenAmount memory stake  =  harness.calculate_normalized_liquidity_stake( SQRT_PRICE_1_1, IERC20(address(token_a)), IERC20(address(token_b)), 100, 100, IERC20(address(0x9999)) );

        assertEq( address(stake.token), address(token_a), "Unknown preferred stake token should default to token0." );
        assertEq( stake.amount, 2, "At 1:1 price, 100 token0 + 100 token1 should produce 2 token0 stake." );
    }

    function test_calculate_normalized_liquidity_stake_uses_token1_when_preferred( )
    external  view
    {
        TokenAmount memory stake  =  harness.calculate_normalized_liquidity_stake( SQRT_PRICE_1_1, IERC20(address(token_a)), IERC20(address(token_b)), 100, 100, IERC20(address(token_b)) );

        assertEq( address(stake.token), address(token_b), "Preferred token1 should be used as stake token." );
        assertEq( stake.amount, 2, "At 1:1 price, normalized total should be 200 token1 units." );
    }

    function test_calculate_normalized_liquidity_stake_converts_token1_value_into_token0_at_price( )
    external  view
    {
        TokenAmount memory stake  =  harness.calculate_normalized_liquidity_stake( SQRT_PRICE_4_1, IERC20(address(token_a)), IERC20(address(token_b)), 100, 400, IERC20(address(token_a)) );

        assertEq( stake.amount, 2, "At price 4 token1 per token0, 400 token1 should convert to 100 token0." );
    }

    function test_calculate_normalized_liquidity_stake_converts_token0_value_into_token1_at_price( )
    external  view
    {
        TokenAmount memory stake  =  harness.calculate_normalized_liquidity_stake( SQRT_PRICE_4_1, IERC20(address(token_a)), IERC20(address(token_b)), 100, 400, IERC20(address(token_b)) );

        assertEq( stake.amount, 8, "At price 4 token1 per token0, 100 token0 should convert to 400 token1." );
    }

    function test_calculate_normalized_liquidity_stake_rounds_dust_up_to_one_wei( )
    external  view
    {
        TokenAmount memory stake  =  harness.calculate_normalized_liquidity_stake( SQRT_PRICE_1_1, IERC20(address(token_a)), IERC20(address(token_b)), 1, 0, IERC20(address(token_a)) );

        assertEq( stake.amount, 1, "Dust liquidity stake should round up to one wei." );
    }

    function test_calculate_normalized_liquidity_stake_handles_zero_amount_side( )
    external  view
    {
        TokenAmount memory stake  =  harness.calculate_normalized_liquidity_stake( SQRT_PRICE_1_1, IERC20(address(token_a)), IERC20(address(token_b)), 0, 200, IERC20(address(token_a)) );

        assertEq( stake.amount, 2, "Zero token0 side should still include token1 value." );
    }

    function test_calculate_protocol_fee_uses_base_fee_when_above_floor( )
    external  view
    {
        ( uint256 protocol_fee, uint256 user_amount )  =  harness.calculate_protocol_fee( 1_000_000, 3000 );

        assertEq( protocol_fee, 300, "Protocol fee should use pool fee above the floor." );
        assertEq( user_amount, 999700, "User amount should be output less protocol fee." );
    }

    function test_calculate_protocol_fee_uses_minimum_fee_when_base_fee_is_below_floor( )
    external  view
    {
        ( uint256 protocol_fee, uint256 user_amount )  =  harness.calculate_protocol_fee( 1_000_000, 100 );

        assertEq( protocol_fee, 100, "Protocol fee should use minimum fee rate below the floor." );
        assertEq( user_amount, 999900, "User amount should be output less floored protocol fee." );
    }

    function test_calculate_protocol_fee_preserves_output_conservation( )
    external  view
    {
        ( uint256 protocol_fee, uint256 user_amount )  =  harness.calculate_protocol_fee( 123456789, 3000 );

        assertEq( protocol_fee + user_amount, 123456789, "Protocol fee and user amount should sum to output." );
    }

    function test_settle_input_sends_erc20_funding_directly_to_pool_manager( )
    external
    {
        MockBondRouteFunding bond_route      =  new MockBondRouteFunding( );
        MockPoolManagerSettlement manager    =  new MockPoolManagerSettlement( );
        BondContext memory context           =  _single_funding_context( IERC20(address(token_a)), 500 );

        vm.etch( BONDROUTE_ADDRESS, address(bond_route).code );
        token_a.mint( BONDROUTE_ADDRESS, 500 );

        harness.settle_input( IPoolManager(address(manager)), context, IERC20(address(token_a)), 500 );

        assertEq( token_a.balanceOf( address(manager) ), 500, "ERC20 funding should be sent directly to PoolManager." );
        assertEq( manager.settle_call_count( ), 1, "PoolManager settle should be called once." );
        assertEq( address(manager.last_synced_currency( )), address(token_a), "PoolManager should sync the input token." );
    }

    function test_settle_input_pulls_native_funding_into_calling_contract_then_settles_with_value( )
    external
    {
        MockBondRouteFunding bond_route    =  new MockBondRouteFunding( );
        MockPoolManagerSettlement manager  =  new MockPoolManagerSettlement( );
        BondContext memory context         =  _single_funding_context( NATIVE_TOKEN, 500 );

        vm.etch( BONDROUTE_ADDRESS, address(bond_route).code );
        vm.deal( BONDROUTE_ADDRESS, 500 );

        harness.settle_input( IPoolManager(address(manager)), context, NATIVE_TOKEN, 500 );

        assertEq( manager.settle_call_count( ), 1, "PoolManager settle should be called once." );
        assertEq( manager.settle_value_received( ), 500, "Native funding should be forwarded with settle value." );
    }

    function test_settle_input_noops_for_zero_amount( )
    external
    {
        MockPoolManagerSettlement manager  =  new MockPoolManagerSettlement( );
        BondContext memory context         =  _single_funding_context( IERC20(address(token_a)), 0 );

        harness.settle_input( IPoolManager(address(manager)), context, IERC20(address(token_a)), 0 );

        assertEq( manager.settle_call_count( ), 0, "Zero amount should not call settle." );
        assertEq( address(manager.last_synced_currency( )), address(0), "Zero amount should not sync a currency." );
    }

    function test_settle_and_take_sends_net_output_to_user_and_protocol_fee_to_recipient( )
    external
    {
        MockBondRouteFunding bond_route    =  new MockBondRouteFunding( );
        MockPoolManagerSettlement manager  =  new MockPoolManagerSettlement( );
        BondContext memory context         =  _single_funding_context( IERC20(address(token_a)), 500 );
        address fee_recipient              =  address(0xFEE);

        vm.etch( BONDROUTE_ADDRESS, address(bond_route).code );
        token_a.mint( BONDROUTE_ADDRESS, 500 );
        token_b.mint( address(manager), 1000 );

        harness.settle_and_take( IPoolManager(address(manager)), context, IERC20(address(token_a)), IERC20(address(token_b)), 500, 900, 100, fee_recipient );

        assertEq( token_b.balanceOf( context.user ), 900, "User should receive net output." );
        assertEq( token_b.balanceOf( fee_recipient ), 100, "Fee recipient should receive protocol fee." );
    }

    function _single_funding_context( IERC20 token, uint256 amount ) private pure returns ( BondContext memory context )
    {
        TokenAmount[] memory fundings  =  new TokenAmount[]( 1 );
        fundings[ 0 ]                  =  TokenAmount({ token: token, amount: amount });

        context  =  BondContext({
            user: address(0xA11CE),
            stake: TokenAmount({ token: token, amount: 0 }),
            fundings: fundings,
            creation_block: 1,
            creation_timestamp: 1
        });
    }
}
