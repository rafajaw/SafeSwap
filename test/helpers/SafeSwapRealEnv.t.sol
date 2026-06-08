// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ChainConfigTestHelper } from "@test/helpers/ChainConfigTestHelper.t.sol";
import { SafeSwapTestHelper } from "@test/helpers/SafeSwapTestHelper.t.sol";
import { TestERC20 } from "@test/helpers/TestERC20.t.sol";

import "@SafeSwapCommon/Definitions.sol";
import { HookAddress } from "@SafeSwapCommon/HookAddress.sol";
import { SafeSwapRouter } from "@SafeSwapRouter/SafeSwapRouter.sol";
import { SafeSwapNft } from "@SafeSwapNft/SafeSwapNft.sol";
import { SafeSwapPositionDescriptor } from "@SafeSwapNft/SafeSwapPositionDescriptor.sol";
import { SafeSwapSigningDescriptor } from "@SafeSwapCommon/SafeSwapSigningDescriptor.sol";
import { SafeSwapHookImpl } from "@SafeSwapHook/SafeSwapHookImpl.sol";

import { BondRoute } from "@BondRoute/BondRoute.sol";
import { BondRouteTestHelper } from "@BondRouteProtected/BondRouteTestHelper.sol";
import { ExecutionData } from "@BondRoute/Core.sol";
import { BondStatus } from "@BondRoute/Definitions.sol";
import {
    BONDROUTE_ADDRESS,
    IBondRouteProtected,
    IERC20,
    NATIVE_TOKEN,
    TokenAmount
} from "@BondRouteProtected/BondRouteProtected.sol";

import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";


/// @dev Minimal handle to the `=0.8.26` PoolManager deployer compiled in its own unit (test/helpers/ForceCompileV4.sol).
interface IPoolManagerDeployer {
    function deploy( address controller ) external returns ( address );
}


/**
 * @title SafeSwapRealEnv
 * @notice Shared base that stands up a fully real SafeSwap environment: real Uniswap V4 PoolManager, real SafeSwapRouter,
 *         real SafeSwapNft, a real registered hook clone, and the real BondRoute singleton. Lifecycle calls are driven
 *         through BondRoute exactly as on-chain (`create_bond` -> wait -> `execute_bond`) with no signatures, so tests
 *         exercise the genuine funding (`transferFrom` from the bond owner) and V4 settlement paths.
 *
 * @dev There is no `SafeSwapHookProxy` contract yet, so the hook clone is hand-built: `SafeSwapHookImpl` is deployed once
 *      (its self-guard forbids being deployed *at* a config address), and the EIP-1167 runtime that delegatecalls it is
 *      etched at a CREATE2-style config address whose top bytes carry the `F d d d C r 0` BCD config and whose low 14 bits
 *      carry the V4 permission bitmap. The registry approves the etched runtime's codehash.
 */
abstract contract SafeSwapRealEnv is ChainConfigTestHelper, SafeSwapTestHelper, BondRouteTestHelper {

    address internal constant TREASURY  =  address(0x7EEA5);

    IPoolManager                    internal poolManager;
    SafeSwapRouter                  internal router;
    SafeSwapNft                     internal nft;
    SafeSwapPositionDescriptor      internal descriptor;
    SafeSwapSigningDescriptor       internal _signing_descriptor;
    SafeSwapHookImpl                internal hookImpl;
    bytes32                         internal hookRuntimeCodehash;

    uint256 private _bond_salt;

    // Absolute, monotonic roll/warp counters. After a deep `execute_bond` call the test frame's own `block.number` /
    // `block.timestamp` read stale (frozen at the transaction's start value) while external calls see the live value, so
    // a relative `block.number + delay` would roll a second bond back onto its own creation block. We advance these
    // absolutes instead, seeded once from a fresh read before any bond runs.
    uint256 private _bond_roll_block;
    uint256 private _bond_warp_timestamp;


    // ━━━━  ENVIRONMENT  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Deploy and wire the whole real stack. Call once from a test's `setUp`.
     */
    function _setup_real_env( ) internal
    {
        vm.chainId( 31_337 );
        vm.roll( 100 );
        vm.warp( _DEFAULT_CONFIG_TIMESTAMP + 1 days );

        _bond_roll_block      =  block.number;
        _bond_warp_timestamp  =  block.timestamp;

        _deploy_chain_config( );

        // BondRoute singleton first: BondRouteProtected's constructor announces to BONDROUTE_ADDRESS, so it must have code
        // before the router/NFT are deployed.
        _set_up_bond_route( );

        // Uniswap V4 PoolManager — deployed from its own `=0.8.26` unit via artifact (this test is the fee owner).
        address pool_manager_deployer  =  deployCode( "ForceCompileV4.sol:PoolManagerDeployer" );
        poolManager  =  IPoolManager( IPoolManagerDeployer( pool_manager_deployer ).deploy( address(this) ) );
        _publish_config_address( POOL_MANAGER_KEY, address(poolManager) );
        _publish_config_address( INITIAL_TREASURY_KEY, TREASURY );
        _publish_native_token_config( );

        _signing_descriptor  =  new SafeSwapSigningDescriptor( );
        _publish_config_address( SAFESWAP_SIGNING_DESCRIPTOR_KEY, address(_signing_descriptor) );

        // Router reads PoolManager, treasury, and its signing descriptor from ChainConfig.
        router  =  new SafeSwapRouter( );
        _publish_config_address( SAFESWAP_ROUTER_KEY, address(router) );

        // Position metadata also reads PoolManager; the NFT requires both descriptor addresses at construction.
        descriptor  =  new SafeSwapPositionDescriptor( );
        _publish_config_address( SAFESWAP_POSITION_DESCRIPTOR_KEY, address(descriptor) );

        nft  =  new SafeSwapNft( );
        _publish_config_address( SAFESWAP_NFT_KEY, address(nft) );

        hookImpl             =  new SafeSwapHookImpl( );
        hookRuntimeCodehash  =  keccak256( _eip1167_runtime( address(hookImpl) ) );
        _publish_config_bytes32( SAFESWAP_HOOK_CODEHASH_KEY, hookRuntimeCodehash );
    }

    /**
     * @notice Etch a real hook clone for `(base_fee_bps, rebate_percent)` at its config address and register it.
     * @return hook The config-hook address (delegatecalls the audited `SafeSwapHookImpl`).
     */
    function _register_hook( uint16 base_fee_bps, uint8 rebate_percent ) internal returns ( address hook )
    {
        hook  =  _hook_address( base_fee_bps, rebate_percent, HookAddress.REQUIRED_PERMISSIONS );

        vm.etch( hook, _eip1167_runtime( address(hookImpl) ) );

        SafeSwapHookImpl( hook ).initialize_once( );
    }

    /**
     * @notice The 45-byte EIP-1167 minimal-proxy runtime that delegatecalls `implementation`.
     */
    function _eip1167_runtime( address implementation ) internal pure returns ( bytes memory )
    {
        return abi.encodePacked(
            hex"363d3d373d3d3d363d73",
            implementation,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
    }


    // ━━━━  TOKENS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _new_token( string memory name, string memory symbol ) internal returns ( TestERC20 )
    {
        return new TestERC20( name, symbol, 18 );
    }

    /**
     * @notice Mint `amount` to `user` and grant BondRoute the standing allowance it needs to pull fundings and stake.
     */
    function _fund_and_approve( address user, TestERC20 token, uint256 amount ) internal
    {
        token.mint( user, amount );

        vm.prank( user );
        token.approve( BONDROUTE_ADDRESS, type(uint256).max );
    }


    // ━━━━  BOND EXECUTION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Run the genuine no-signature bond flow as `user`: create the bond, wait past SafeSwap's reveal delay, execute.
     * @dev Native stake / funding values are forwarded automatically. A monotonically increasing salt keeps otherwise
     *      identical bonds distinct so the same call can be executed more than once in a test.
     */
    function _create_and_execute_bond(
        address user,
        IBondRouteProtected protocol,
        bytes memory call,
        TokenAmount memory stake,
        TokenAmount[] memory fundings
    ) internal returns ( BondStatus status, bytes memory output )
    {
        ExecutionData memory execution_data  =  ExecutionData({
            fundings: fundings,
            stake:    stake,
            salt:     _bond_salt++,
            protocol: protocol,
            call:     call
        });

        bytes32 commitment_hash  =  bond_route.__OFF_CHAIN__calc_commitment_hash( user, execution_data );

        uint256 stake_value  =  address(stake.token) == address(NATIVE_TOKEN)  ?  stake.amount  :  0;

        vm.prank( user );
        bond_route.create_bond{ value: stake_value }( commitment_hash, stake );

        _bond_roll_block      +=  MIN_BOND_EXECUTION_DELAY_IN_BLOCKS + 1;
        _bond_warp_timestamp  +=  MIN_BOND_EXECUTION_DELAY_IN_SECONDS + 1;
        vm.roll( _bond_roll_block );
        vm.warp( _bond_warp_timestamp );

        uint256 funding_value  =  _native_funding_total( fundings );

        vm.prank( user );
        ( status, output )  =  bond_route.execute_bond{ value: funding_value }( execution_data );
    }

    function _native_funding_total( TokenAmount[] memory fundings ) private pure returns ( uint256 total )
    {
        for(  uint256 i = 0  ;  i < fundings.length  ;  i = i + 1  )
        {
            if(  address(fundings[ i ].token) == address(NATIVE_TOKEN)  )  total  =  total + fundings[ i ].amount;
        }
    }
}
