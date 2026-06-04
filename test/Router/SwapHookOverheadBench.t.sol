// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { SafeSwapRealEnv } from "@test/helpers/SafeSwapRealEnv.t.sol";
import { TestERC20 } from "@test/helpers/TestERC20.t.sol";

import "@SafeSwapCommon/Definitions.sol";
import { PoolInfo } from "@SafeSwapCommon/Types.sol";
import { CreatePositionParams } from "@SafeSwapNft/libraries/ModifyLiquidityLib.sol";
import { ExactInputSwapParams } from "@SafeSwapRouter/libraries/ExactInputSwapLib.sol";

import { ExecutionData } from "@BondRoute/Core.sol";
import { BondStatus } from "@BondRoute/Definitions.sol";
import { IBondRouteProtected, IERC20, TokenAmount } from "@BondRouteProtected/BondRouteProtected.sol";


/**
 * @title SwapHookOverheadBenchTest
 * @notice End-to-end gas contrast of the `beforeSwap` simulation, measured through the real BondRoute -> router -> hook ->
 *         V4 path. Two pools are identical in every respect (same token pair, base fee, tick spacing and seeded liquidity)
 *         except their LP capture share: one is `capture == 0` (the `beforeSwap` guard returns the flat base fee and never
 *         simulates) and one is `capture == 50` (the full `SwapSimulator` price-path walk runs). Both measured swaps are
 *         preceded by an identical warm-up swap on their own pool by their own funder, so global / code / balance / pool
 *         slots are warm for both — the gas delta between them is therefore purely the simulation the guard skips.
 *
 * @dev Run with `-vv` to see the emitted gas logs. The percentage is the simulation expressed as a share of the no-sim swap.
 */
contract SwapHookOverheadBenchTest is SafeSwapRealEnv {

    address internal constant _LP       =  address(0x11D);
    address internal constant _USER_0   =  address(0xA0);    // swaps the capture==0 pool.
    address internal constant _USER_50  =  address(0xA50);   // swaps the capture==50 pool.

    uint16  internal constant _BASE_FEE_BPS    =  30;
    int24   internal constant _TICK_SPACING    =  60;
    uint160 internal constant _SQRT_PRICE_1_1  =  79228162514264337593543950336;
    uint256 internal constant _SWAP_AMOUNT     =  1_000 ether;

    // A capture==50 swap (full simulation) should not cost more than this multiple of the capture==0 swap (guarded).
    uint256 internal constant _OVERHEAD_CEILING_BPS  =  2_000;   // ≤ 20% of the no-sim swap; trips only on gross regressions.

    TestERC20 internal _token_a;
    TestERC20 internal _token_b;
    uint256   internal _salt;

    // Absolute block / time counters. After a deep `execute_bond` call, re-reading `block.number` in the test frame can
    // return a stale value, so `vm.roll(block.number + N)` computes its target from a stale base and silently fails to
    // advance — the next bond then self-collides on BondRoute's same-block guard. Driving roll/warp from monotonic
    // counters we own (seeded once from a fresh read) avoids reading block.number/timestamp after a deep call at all.
    uint256 internal _blk;
    uint256 internal _ts;

    function setUp( ) public
    {
        _setup_real_env( );

        // Same audited impl backs both clones; only the address-encoded capture share differs.
        _register_hook( _BASE_FEE_BPS, 0 );
        _register_hook( _BASE_FEE_BPS, 50 );

        _token_a  =  _new_token( "Token A", "TKNA" );
        _token_b  =  _new_token( "Token B", "TKNB" );

        _fund_and_approve( _LP,      _token_a, 10_000_000 ether );
        _fund_and_approve( _LP,      _token_b, 10_000_000 ether );
        _fund_and_approve( _USER_0,  _token_a, 10_000_000 ether );
        _fund_and_approve( _USER_50, _token_a, 10_000_000 ether );

        // Seed the absolute roll/warp counters from a fresh read, before any bond is executed.
        _blk  =  block.number;
        _ts   =  block.timestamp;

        _create_deep_position( 0 );
        _create_deep_position( 50 );
    }

    /// @dev Advance block and time to an absolute, monotonically increasing point past BondRoute's min execution delay.
    function _advance_past_delay( ) private
    {
        _blk  +=  MIN_BOND_EXECUTION_DELAY_IN_BLOCKS + 1;
        _ts   +=  MIN_BOND_EXECUTION_DELAY_IN_SECONDS + 1;
        vm.roll( _blk );
        vm.warp( _ts );
    }


    // ━━━━  BENCH  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_bench_beforeswap_sim_overhead_capture0_vs_capture50( )
    external
    {
        // Warm each pool with an identical throwaway swap so both measured swaps see warm slots / code / balances; the
        // gas delta between them is then purely the simulation the capture==0 guard skips.
        _swap_gas( _USER_0,  0 );
        _swap_gas( _USER_50, 50 );

        uint256 gas_no_sim  =  _swap_gas( _USER_0,  0 );    // capture==0: guard returns the base fee, no simulation.
        uint256 gas_sim     =  _swap_gas( _USER_50, 50 );   // capture==50: full SwapSimulator walk.

        assertGt( gas_sim, gas_no_sim, "the simulated swap must cost more than the guarded one" );

        uint256 overhead      =  gas_sim - gas_no_sim;
        uint256 overhead_bps  =  overhead * 10_000 / gas_no_sim;   // basis points of the no-sim swap (100 bps = 1%).

        emit log_named_uint( "swap_gas_capture0_no_sim", gas_no_sim );
        emit log_named_uint( "swap_gas_capture50_sim",   gas_sim );
        emit log_named_uint( "sim_overhead_gas",         overhead );
        emit log_named_uint( "sim_overhead_pct_x100",    overhead_bps );   // e.g. 612 => 6.12%.

        assertLt( overhead_bps, _OVERHEAD_CEILING_BPS, "beforeSwap simulation overhead regressed past its ceiling" );
    }


    // ━━━━  HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// @dev Drive one real exact-input swap as `user` against the `rebate` pool through BondRoute; return the `execute_bond` gas.
    function _swap_gas( address user, uint8 rebate ) private returns ( uint256 gas_used )
    {
        ExactInputSwapParams memory params  =  ExactInputSwapParams({
            token_out: IERC20(address(_token_b)),
            minimum_output_amount: 0,
            pool_info: _pool_info( rebate )
        });

        TokenAmount memory stake  =  TokenAmount({ token: IERC20(address(_token_a)), amount: _SWAP_AMOUNT / 100 });

        TokenAmount[] memory fundings  =  new TokenAmount[](1);
        fundings[0]  =  TokenAmount({ token: IERC20(address(_token_a)), amount: _SWAP_AMOUNT });

        ExecutionData memory execution_data  =  ExecutionData({
            fundings: fundings,
            stake:    stake,
            salt:     _salt++,
            protocol: IBondRouteProtected( address(router) ),
            call:     abi.encodeCall( router.swap_exact_input, ( params ) )
        });

        bytes32 commitment_hash  =  bond_route.__OFF_CHAIN__calc_commitment_hash( user, execution_data );

        vm.prank( user );
        bond_route.create_bond( commitment_hash, stake );

        _advance_past_delay( );

        vm.prank( user );
        uint256 g  =  gasleft( );
        ( BondStatus status, )  =  bond_route.execute_bond( execution_data );
        gas_used  =  g - gasleft( );

        assertEq( uint256(status), uint256(BondStatus.EXECUTED), "bench swap bond must execute" );
    }

    function _create_deep_position( uint8 rebate ) private
    {
        CreatePositionParams memory params  =  CreatePositionParams({
            pool_info: _pool_info( rebate ),
            tick_lower: -6000,
            tick_upper: 6000,
            liquidity: 100_000 ether,
            sqrt_price_x96: _SQRT_PRICE_1_1,
            minimum_deposited_a: TokenAmount({ token: IERC20(address(_token_a)), amount: 0 }),
            minimum_deposited_b: TokenAmount({ token: IERC20(address(_token_b)), amount: 0 })
        });

        TokenAmount[] memory fundings  =  new TokenAmount[](2);
        fundings[0]  =  TokenAmount({ token: IERC20(address(_token_b)), amount: 1_000_000 ether });
        fundings[1]  =  TokenAmount({ token: IERC20(address(_token_a)), amount: 1_000_000 ether });

        IERC20 token0  =  address(_token_a) < address(_token_b)  ?  IERC20(address(_token_a))  :  IERC20(address(_token_b));

        TokenAmount memory stake  =  TokenAmount({ token: token0, amount: 50_000 ether });

        ExecutionData memory execution_data  =  ExecutionData({
            fundings: fundings,
            stake:    stake,
            salt:     _salt++,
            protocol: IBondRouteProtected( address(nft) ),
            call:     abi.encodeCall( nft.create_position, ( params ) )
        });

        bytes32 commitment_hash  =  bond_route.__OFF_CHAIN__calc_commitment_hash( _LP, execution_data );

        vm.prank( _LP );
        bond_route.create_bond( commitment_hash, stake );

        _advance_past_delay( );

        vm.prank( _LP );
        ( BondStatus status, )  =  bond_route.execute_bond( execution_data );
        assertEq( uint256(status), uint256(BondStatus.EXECUTED), "bench position bond must execute" );
    }

    function _pool_info( uint8 rebate ) private pure returns ( PoolInfo memory )
    {
        return PoolInfo({ base_fee_bps: _BASE_FEE_BPS, rebate_percent: rebate, tick_spacing: _TICK_SPACING });
    }
}
