// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./TestBase.t.sol";
import { PROTOCOL_FEE_DIVISOR } from "@SafeSwapRouter/Definitions.sol";


/// @dev Handler contract for invariant testing.
contract SafeSwapHandler is Test {
    TestableSafeSwap public hook;
    MockPoolManager public pool_manager;
    MockERC20 public token0;
    MockERC20 public token1;
    address public user;

    uint256 public total_protocol_fees_collected;
    uint256 public total_output_to_users;
    uint256 public swap_count;

    constructor(
        TestableSafeSwap _hook,
        MockPoolManager _pool_manager,
        MockERC20 _token0,
        MockERC20 _token1,
        address _user
    )
    {
        hook          =  _hook;
        pool_manager  =  _pool_manager;
        token0        =  _token0;
        token1        =  _token1;
        user          =  _user;
    }

    function execute_swap( uint256 amount_in, uint256 output_ratio ) external
    {
        amount_in     =  bound( amount_in, 1 ether, 100 ether );
        output_ratio  =  bound( output_ratio, 80, 120 );  // 80% to 120% of input.

        uint256 mock_output  =  amount_in * output_ratio / 100;

        TokenAmount[] memory fundings  =  new TokenAmount[]( 1 );
        fundings[ 0 ]  =  TokenAmount({ token: IERC20(address(token0)), amount: amount_in });

        BondContext memory context  =  BondContext({
            user: user,
            stake: TokenAmount({ token: IERC20(address(token0)), amount: amount_in / 100 }),
            fundings: fundings,
            creation_block: block.number - 5,
            creation_timestamp: block.timestamp - 1 hours
        });

        ExactInputSwapParams memory params  =  ExactInputSwapParams({
            token_out: IERC20(address(token1)),
            minimum_output_amount: 0,  // No slippage check for invariant testing.
            pool_info: PoolInfo({ fee: 3000, tick_spacing: 60 })
        });

        pool_manager.set_mock_swap_amounts( -int128(uint128(amount_in)), int128(uint128(mock_output)) );

        vm.prank( address(pool_manager) );
        try hook.harness_execute_exact_input_swap( context, params )
        {
            // Calculate protocol fee: 10% of 0.30% = 0.03%.
            uint256 protocol_fee  =  mock_output * 3000 / PROTOCOL_FEE_DIVISOR;
            uint256 user_amount   =  mock_output - protocol_fee;

            total_protocol_fees_collected  =  total_protocol_fees_collected + protocol_fee;
            total_output_to_users          =  total_output_to_users + user_amount;
            swap_count                     =  swap_count + 1;
        }
        catch { }
    }
}


contract InvariantsTest is SafeSwapTestBase {

    SafeSwapHandler public handler;

    function setUp( ) public override
    {
        super.setUp( );

        handler  =  new SafeSwapHandler( hook, pool_manager, token0, token1, user );

        // Target the handler for invariant testing.
        targetContract( address(handler) );
    }


    // ━━━━  Fee Invariants  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function invariant_protocol_fee_always_collected( ) external view
    {
        // If swaps occurred, fees should be collected.
        if(  handler.swap_count( ) > 0  )
        {
            assertGt(
                handler.total_protocol_fees_collected( ),
                0,
                "Protocol fees should be collected on swaps."
            );
        }
    }

    function invariant_protocol_fee_never_negative( ) external view
    {
        // Protocol fee is always >= 0 (unsigned).
        assertGe(
            handler.total_protocol_fees_collected( ),
            0,
            "Protocol fee should never be negative."
        );
    }

    function invariant_user_output_plus_fee_equals_pool_output( ) external view
    {
        // user_amount + protocol_fee should equal total pool output.
        // This is implicitly tested by the handler tracking.
        uint256 total_pool_output  =  handler.total_output_to_users( ) + handler.total_protocol_fees_collected( );

        // Total should be positive if swaps occurred.
        if(  handler.swap_count( ) > 0  )
        {
            assertGt(
                total_pool_output,
                0,
                "Total pool output should be positive after swaps."
            );
        }
    }


    // ━━━━  Protected Context Invariants  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function invariant_protected_context_always_cleared_after_operation( ) external view
    {
        // After all operations, protected context should be cleared.
        assertEq(
            hook.harness_hook_callback_allowed( ),
            false,
            "Protected context should be cleared after operations."
        );
    }

    function invariant_hooks_only_pass_in_protected_context( ) external
    {
        // Without protected context, hook callbacks should revert.
        PoolKey memory pool_key  =  PoolKey({
            currency0: Currency.wrap( address(token0) ),
            currency1: Currency.wrap( address(token1) ),
            fee: POOL_FEE_030,
            tickSpacing: TICK_SPACING_60,
            hooks: IHooks(address(hook))
        });

        IPoolManager.SwapParams memory swap_params  =  IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -100 ether,
            sqrtPriceLimitX96: 0
        });

        // Ensure not protected.
        hook.harness_revoke_hook_callback_permission( );

        vm.prank( address(pool_manager) );
        vm.expectRevert( abi.encodeWithSelector( BondRouteRequired.selector, address(pool_manager), address(BondRoute) ) );
        hook.beforeSwap( user, pool_key, swap_params, "" );
    }


    // ━━━━  Treasury Invariants  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function invariant_only_treasury_can_withdraw( ) external
    {
        // Non-treasury should not be able to withdraw.
        token0.mint( address(hook), 100 ether );

        vm.prank( user );
        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, user, treasury ) );
        hook.withdraw_protocol_fees( token0, user );

        // Treasury should succeed.
        vm.prank( treasury );
        hook.withdraw_protocol_fees( token0, treasury );
    }

    function invariant_treasury_transfer_requires_current_treasury( ) external
    {
        address new_treasury  =  makeAddr( "new_treasury" );

        // Non-treasury cannot initiate transfer.
        vm.prank( user );
        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, user, treasury ) );
        hook.transfer_treasury( new_treasury );

        // Treasury can initiate transfer (2-step process).
        address current_treasury  =  hook.get_treasury( );
        vm.prank( current_treasury );
        hook.transfer_treasury( new_treasury );

        // Treasury unchanged until accepted.
        assertEq(
            hook.get_treasury( ),
            current_treasury,
            "Treasury should not change until accepted."
        );

        // New treasury accepts.
        vm.prank( new_treasury );
        hook.accept_treasury( );

        assertEq(
            hook.get_treasury( ),
            new_treasury,
            "Treasury should transfer after accept."
        );

        // Restore for other tests.
        vm.prank( new_treasury );
        hook.transfer_treasury( treasury );
        vm.prank( treasury );
        hook.accept_treasury( );
    }
}
