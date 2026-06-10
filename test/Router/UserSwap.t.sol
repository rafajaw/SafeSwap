// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IUserSwapWorkflowTests } from "@test/Router/TestManifest.sol";
import { TickMath } from "@UniswapV4Core/libraries/TickMath.sol";
import { SafeSwapRealEnv } from "@test/helpers/SafeSwapRealEnv.t.sol";
import { TestERC20 } from "@test/helpers/TestERC20.t.sol";

import { PoolInfo } from "@SafeSwapCommon/Types.sol";
import { SafeSwapCommon } from "@SafeSwapCommon/SafeSwapCommon.sol";
import { CreatePositionParams } from "@SafeSwapNft/ModifyLiquidityLib.sol";
import { ExactInputSwapParams } from "@SafeSwapRouter/ExactInputSwapLib.sol";
import { ExactOutputSwapParams } from "@SafeSwapRouter/ExactOutputSwapLib.sol";
import { BondStatus } from "@BondRoute/Definitions.sol";
import { IBondRouteProtected, IERC20, TokenAmount } from "@BondRouteProtected/BondRouteProtected.sol";


/**
 * @title UserSwapTest
 * @notice Full-workflow swap tests: real `swap_exact_input` / `swap_exact_output` driven through the real BondRoute, the
 *         router, the registered hook (which applies the surplus repricing fee in `beforeSwap`), and a real V4 pool seeded
 *         with real liquidity. This is the first end-to-end exercise of the surplus-based repricing fee on a live swap.
 */
contract UserSwapTest is IUserSwapWorkflowTests, SafeSwapRealEnv {

    address internal constant _USER  =  address(0xA11CE);

    uint16 internal constant _BASE_FEE_BPS    =  30;
    uint8  internal constant _CAPTURE_PERCENT =  50;
    int24  internal constant _TICK_SPACING    =  60;
    uint160 internal constant _SQRT_PRICE_1_1 =  79228162514264337593543950336;

    TestERC20 internal _token_a;
    TestERC20 internal _token_b;
    address   internal _hook;

    function setUp( ) public
    {
        _setup_real_env( );

        _hook     =  _register_hook( _BASE_FEE_BPS, _CAPTURE_PERCENT );
        _token_a  =  _new_token( "Token A", "TKNA" );
        _token_b  =  _new_token( "Token B", "TKNB" );

        _fund_and_approve( _USER, _token_a, 10_000_000 ether );
        _fund_and_approve( _USER, _token_b, 10_000_000 ether );

        _create_deep_position( );
    }


    // ━━━━  EXACT INPUT  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_swap_exact_input_pays_user_the_quoted_net_output( )
    external
    {
        uint256 amount_in  =  1_000 ether;

        ( uint256 quoted_net_output, , )  =  router.__OFF_CHAIN__quote_swap_exact_input( IERC20(address(_token_a)), IERC20(address(_token_b)), _pool_info(), amount_in );

        uint256 user_out_before  =  _token_b.balanceOf( _USER );

        BondStatus status  =  _swap_exact_input({ user: _USER, amount_in: amount_in, minimum_output_amount: 0 });

        assertEq( uint256(status), uint256(BondStatus.EXECUTED), "exact-input swap bond should execute." );
        assertGt( quoted_net_output, 0, "quote should return a positive net output." );
        assertEq( _token_b.balanceOf( _USER ) - user_out_before, quoted_net_output, "realized net output must equal the off-chain quote." );
    }

    function test_swap_exact_input_takes_protocol_fee_to_the_router_treasury( )
    external
    {
        uint256 router_fee_before  =  _token_b.balanceOf( address(router) );

        _swap_exact_input({ user: _USER, amount_in: 1_000 ether, minimum_output_amount: 0 });

        assertGt( _token_b.balanceOf( address(router) ) - router_fee_before, 0, "the SafeSwap protocol fee should accrue to the router." );
    }

    function test_swap_exact_input_applies_a_repricing_fee_above_the_base_fee( )
    external  view
    {
        ( , uint24 total_fee_pips, uint256 movement_bps )  =  router.__OFF_CHAIN__quote_swap_exact_input( IERC20(address(_token_a)), IERC20(address(_token_b)), _pool_info(), 1_000 ether );

        assertGt( movement_bps, 0, "a price-moving swap should report nonzero movement." );
        assertGt( total_fee_pips, SafeSwapCommon.compute_base_fee_pips( _BASE_FEE_BPS ), "the swap fee should exceed the base fee by the repricing component." );
    }

    function test_swap_exact_input_reverts_on_slippage_as_graceful_bond_settlement( )
    external
    {
        uint256 user_out_before  =  _token_b.balanceOf( _USER );

        BondStatus status  =  _swap_exact_input({ user: _USER, amount_in: 1_000 ether, minimum_output_amount: type(uint256).max });

        assertEq( uint256(status), uint256(BondStatus.PROTOCOL_REVERTED), "an unmet minimum output should revert inside the protocol." );
        assertEq( _token_b.balanceOf( _USER ), user_out_before, "a reverted swap must not move the user's output token." );
    }


    // ━━━━  EXACT OUTPUT  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_swap_exact_output_delivers_the_exact_net_output( )
    external
    {
        uint256 exact_output  =  500 ether;

        uint256 user_out_before  =  _token_b.balanceOf( _USER );

        BondStatus status  =  _swap_exact_output({ user: _USER, exact_output_amount: exact_output, maximum_input: 1_000 ether });

        assertEq( uint256(status), uint256(BondStatus.EXECUTED), "exact-output swap bond should execute." );
        assertEq( _token_b.balanceOf( _USER ) - user_out_before, exact_output, "user should receive exactly the requested net output." );
    }


    // ━━━━  HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _swap_exact_input( address user, uint256 amount_in, uint256 minimum_output_amount ) internal returns ( BondStatus status )
    {
        ExactInputSwapParams memory params  =  ExactInputSwapParams({
            token_in: IERC20(address(_token_a)),
            input_amount: amount_in,
            token_out: IERC20(address(_token_b)),
            minimum_output_amount: minimum_output_amount,
            pool_info: _pool_info()
        });

        ( status, )  =  _create_and_execute_bond(
            user,
            IBondRouteProtected( address(router) ),
            abi.encodeCall( router.bonded_swap_exact_input, ( params ) ),
            _swap_stake( amount_in ),
            _one_funding( amount_in )
        );
    }

    function _swap_exact_output( address user, uint256 exact_output_amount, uint256 maximum_input ) internal returns ( BondStatus status )
    {
        ExactOutputSwapParams memory params  =  ExactOutputSwapParams({
            token_in: IERC20(address(_token_a)),
            maximum_input_amount: maximum_input,
            token_out: IERC20(address(_token_b)),
            exact_output_amount: exact_output_amount,
            pool_info: _pool_info()
        });

        ( status, )  =  _create_and_execute_bond(
            user,
            IBondRouteProtected( address(router) ),
            abi.encodeCall( router.bonded_swap_exact_output, ( params ) ),
            _swap_stake( maximum_input ),
            _one_funding( maximum_input )
        );
    }

    function _create_deep_position( ) internal
    {
        CreatePositionParams memory params  =  CreatePositionParams({
            pool_info: _pool_info(),
            sqrt_price_lower_x96: TickMath.getSqrtPriceAtTick( -6000 ),
            sqrt_price_upper_x96: TickMath.getSqrtPriceAtTick( 6000 ),
            liquidity: 100_000 ether,
            sqrt_price_x96: _SQRT_PRICE_1_1,
            maximum_deposit_a: TokenAmount({ token: IERC20(address(_token_a)), amount: 1_000_000 ether }),
            minimum_deposit_a: 0,
            maximum_deposit_b: TokenAmount({ token: IERC20(address(_token_b)), amount: 1_000_000 ether }),
            minimum_deposit_b: 0
        });

        TokenAmount[] memory fundings  =  new TokenAmount[](2);
        fundings[0]  =  TokenAmount({ token: IERC20(address(_token_b)), amount: 1_000_000 ether });
        fundings[1]  =  TokenAmount({ token: IERC20(address(_token_a)), amount: 1_000_000 ether });

        IERC20 token0  =  address(_token_a) < address(_token_b)  ?  IERC20(address(_token_a))  :  IERC20(address(_token_b));

        _create_and_execute_bond(
            _USER,
            IBondRouteProtected( address(nft) ),
            abi.encodeCall( nft.bonded_create_position, ( params ) ),
            TokenAmount({ token: token0, amount: 50_000 ether }),
            fundings
        );
    }

    function _pool_info( ) internal pure returns ( PoolInfo memory )
    {
        return PoolInfo({ base_fee_bps: _BASE_FEE_BPS, rebate_percent: _CAPTURE_PERCENT, tick_spacing: _TICK_SPACING });
    }

    function _swap_stake( uint256 amount_in ) internal view returns ( TokenAmount memory )
    {
        uint256 stake_amount  =  amount_in / 100;
        if(  stake_amount == 0  )  stake_amount  =  1;

        return TokenAmount({ token: IERC20(address(_token_a)), amount: stake_amount });
    }

    function _one_funding( uint256 amount_in ) internal view returns ( TokenAmount[] memory fundings )
    {
        fundings     =  new TokenAmount[](1);
        fundings[0]  =  TokenAmount({ token: IERC20(address(_token_a)), amount: amount_in });
    }
}
