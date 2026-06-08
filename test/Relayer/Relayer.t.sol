// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";

import { Relayer } from "@SafeSwapRelayer/Relayer.sol";
import { IRelayerTests } from "@test/Relayer/TestManifest.sol";
import { TestERC20 } from "@test/helpers/TestERC20.t.sol";

import { IERC20, NATIVE_TOKEN, BONDROUTE_ADDRESS } from "@BondRouteProtected/BondRouteProtected.sol";


/**
 * @notice Exposes the Relayer's internal approval helper so a unit test can drive it directly.
 */
contract RelayerHarness is Relayer {

    function approve_max( IERC20 token )
    external
    {
        _approve_max_to_bond_route( token );
    }
}


/**
 * @notice Minimal USDT-style token that forbids overwriting a non-zero allowance, to prove the reset-to-zero dance.
 */
contract UsdtLikeERC20 {

    mapping( address => mapping( address => uint256 ) ) public allowance;

    function approve( address spender, uint256 amount )
    external returns ( bool )
    {
        if(  amount > 0  &&  allowance[ msg.sender ][ spender ] > 0  )  revert( "USDT: approve from non-zero allowance" );

        allowance[ msg.sender ][ spender ]  =  amount;
        return true;
    }
}


/**
 * @title RelayerTest
 * @notice Proves the Relayer's BondRoute approval dance for the funding tokens it approves before `execute_bond_as`.
 * @dev Implements IRelayerTests from TestManifest.sol.
 */
contract RelayerTest is Test, IRelayerTests {

    RelayerHarness harness;

    function setUp( ) public
    {
        harness  =  new RelayerHarness( );
    }


    // ─── BondRoute Approval Dance ───────────────────────────────────────────────

    function test_approve_sets_infinite_allowance_from_zero( ) external
    {
        TestERC20 token  =  new TestERC20( "Token", "TKN", 18 );

        harness.approve_max( IERC20(address(token)) );

        assertEq( token.allowance( address(harness), BONDROUTE_ADDRESS ), type(uint256).max, "allowance should be set to infinite from zero" );
    }

    function test_approve_is_idempotent_when_allowance_already_infinite( ) external
    {
        TestERC20 token  =  new TestERC20( "Token", "TKN", 18 );

        harness.approve_max( IERC20(address(token)) );
        harness.approve_max( IERC20(address(token)) );

        assertEq( token.allowance( address(harness), BONDROUTE_ADDRESS ), type(uint256).max, "allowance should remain infinite" );
    }

    function test_approve_resets_to_zero_first_for_tokens_that_forbid_overwrite( ) external
    {
        UsdtLikeERC20 token  =  new UsdtLikeERC20( );

        vm.prank( address(harness) );
        token.approve( BONDROUTE_ADDRESS, 50 );

        harness.approve_max( IERC20(address(token)) );

        assertEq( token.allowance( address(harness), BONDROUTE_ADDRESS ), type(uint256).max, "should reset to zero then set infinite" );
    }

    function test_approve_skips_native_token( ) external
    {
        harness.approve_max( NATIVE_TOKEN );

        // Reaching this line without reverting proves native was skipped (no approve attempted on address(0)).
        assertTrue( true, "native token approval must be skipped" );
    }


    // ─── Native Receive ─────────────────────────────────────────────────────────

    function test_delegate_accepts_native_value( ) external
    {
        // A gasless op can release native back to the user's EOA mid-execution (native-output swap, remove/collect payout,
        // stake/refund return). These arrive as an empty-calldata value transfer that must not revert.
        uint256 amount  =  1 ether;
        ( bool ok, )  =  address(harness).call{ value: amount }( "" );

        assertTrue( ok, "delegate must accept native value via receive()" );
        assertEq( address(harness).balance, amount, "received native value should land on the delegate account" );
    }
}
