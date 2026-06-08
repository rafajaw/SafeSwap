// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/*

        ███████╗ █████╗ ███████╗███████╗███████╗██╗    ██╗ █████╗ ██████╗
        ██╔════╝██╔══██╗██╔════╝██╔════╝██╔════╝██║    ██║██╔══██╗██╔══██╗
        ███████╗███████║█████╗  █████╗  ███████╗██║ █╗ ██║███████║██████╔╝
        ╚════██║██╔══██║██╔══╝  ██╔══╝  ╚════██║██║███╗██║██╔══██║██╔═══╝
        ███████║██║  ██║██║     ███████╗███████║╚███╔███╔╝██║  ██║██║
        ╚══════╝╚═╝  ╚═╝╚═╝     ╚══════╝╚══════╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝
        ━━━━━━━  MEV protection for traders. Repricing revenue for LPs.  ━━━━━━━

*/

import "@SafeSwapHook/ISafeSwapHook.sol";
import { HookAddress } from "@SafeSwapCommon/HookAddress.sol";
import {
    CONFIG_SIGNER,
    POOL_MANAGER_KEY,
    SAFESWAP_ROUTER_KEY,
    SAFESWAP_NFT_KEY
} from "@SafeSwapCommon/Definitions.sol";
import { SafeSwapCommon } from "@SafeSwapCommon/SafeSwapCommon.sol";
import { SwapSimulator } from "@SafeSwapCommon/SwapSimulator.sol";
import { ChainConfig } from "@ChainConfig/IChainConfig.sol";
import { IHooks } from "@UniswapV4Core/interfaces/IHooks.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "@UniswapV4Core/types/BeforeSwapDelta.sol";
import { LPFeeLibrary } from "@UniswapV4Core/libraries/LPFeeLibrary.sol";
import { Clones } from "@OpenZeppelin/proxy/Clones.sol";


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error DirectImplementationCallForbidden( address implementation );
error CallerNotPoolManager( address caller, address pool_manager );
error CallerNotRouter( address sender, address router );
error CallerNotPositionManager( address sender, address position_manager );
// Hook deployment failure modes. ALREADY_EXISTS: a hook is already deployed at this salt's address. CONFIG_MISMATCH: the
// mined address does not decode to the requested base fee and capture. PERMISSIONS: the address lacks the required V4 hook
// permission bits. The new_hook address recovers all decoded detail off-chain.
enum DeployHookError { ALREADY_EXISTS, CONFIG_MISMATCH, PERMISSIONS }
error DeployHookFailed( DeployHookError reason, address new_hook, uint16 base_fee_bps, uint8 rebate_percent );


/**
 * @title SafeSwapHookImpl
 * @notice Single Uniswap V4 hook implementation. Every SafeSwap pool's hook is a tiny EIP-1167 clone of this
 *         contract whose CREATE2 address encodes the pool's base fee and LP capture share (see the HookAddress library). Because the
 *         clone delegatecalls into this code, `address(this)` here is the clone, so the economic config is decoded from the
 *         clone address on every call — no per-clone storage, no constructor.
 *
 * @dev The hook prices the swap (design A): `beforeSwap` simulates the swap with `SwapSimulator`, computes
 *      `baseFee + repricingFee` from the estimated repricing surplus, and returns it as a Uniswap V4 dynamic-fee override so
 *      the fee accrues natively (path-fairly) to the LPs the swap crosses. The hook never holds funds and only gates every
 *      pool action to the canonical router.
 */
contract SafeSwapHookImpl is ISafeSwapHook {

    IPoolManager public immutable PoolManager;
    address public immutable SafeSwapRouter;          // initiates swaps.
    address public immutable SafeSwapNft;             // initiates pool init + liquidity (it owns the V4 positions).

    // *SECURITY*  -  The implementation's own address. Set at deploy of THIS contract, so under a clone's delegatecall it
    //                differs from `address(this)`; equal only on a direct call to the implementation, which is rejected.
    address private immutable IMPLEMENTATION_SELF;

    /**
     * @notice Wire the PoolManager and the canonical router from ChainConfig.
     * @dev Reverts with string errors for human-facing deployment failures.
     */
    constructor( )
    {
        address pool_manager  =  ChainConfig.read_address( CONFIG_SIGNER, POOL_MANAGER_KEY );
        if(  pool_manager.code.length == 0  )  revert( "SafeSwapHook: Invalid pool_manager" );

        address router  =  ChainConfig.read_address( CONFIG_SIGNER, SAFESWAP_ROUTER_KEY );
        if(  router.code.length == 0  )  revert( "SafeSwapHook: Invalid router" );

        address position_manager  =  ChainConfig.read_address( CONFIG_SIGNER, SAFESWAP_NFT_KEY );
        if(  position_manager.code.length == 0  )  revert( "SafeSwapHook: Invalid position manager" );

        PoolManager          =  IPoolManager(pool_manager);
        SafeSwapRouter       =  router;
        SafeSwapNft          =  position_manager;
        IMPLEMENTATION_SELF  =  address(this);
    }


    // ━━━━  CONFIG GETTERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Base LP fee in basis points and LP capture share in percent, decoded from this clone's address.
     * @dev Reverts with `DirectImplementationCallForbidden` if called on the implementation, which carries no valid config.
     */
    function get_hook_config( )
    external  view returns ( uint16 base_fee_bps, uint8 rebate_percent )
    {
        _require_clone_context( );

        ( base_fee_bps, rebate_percent )  =  HookAddress.decode( address(this) );
    }


    // ━━━━  REGISTRATION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Register this clone with the canonical router for its decoded config. Idempotent.
     * @dev The router re-validates this clone's runtime codehash (the EIP-1167 stub), address-bit config, and V4 permissions.
     */
    function initialize_once( )
    external
    {
        _require_clone_context( );

        ( uint16 fee_bps, uint8 capture_percent )  =  HookAddress.decode( address(this) );

        ISafeSwapHookRegistry(SafeSwapRouter).register_hook( fee_bps, capture_percent );
    }

    /**
     * @notice Permissionlessly deploy a config-hook clone of this implementation at a mined `salt` address and register it
     *         with the canonical router for `(base_fee_bps, rebate_percent)`. Callable on the implementation or any clone;
     *         under a clone's delegatecall it forwards to the implementation so the canonical EIP-1167 code is baked in.
     *
     * @dev Every clone is the canonical EIP-1167 minimal proxy with this implementation baked in, so they all share the one
     *      runtime codehash the router authorizes. The `salt` must be mined off-chain so the CREATE2 address carries the
     *      matching `HookAddress` BCD config and the required V4 permission bits.
     */
    function deploy_hook( uint16 base_fee_bps, uint8 rebate_percent, bytes32 salt )
    external  returns ( address new_hook )
    {
        if(  address(this) != IMPLEMENTATION_SELF  )  return SafeSwapHookImpl(IMPLEMENTATION_SELF).deploy_hook( base_fee_bps, rebate_percent, salt );

        new_hook  =  Clones.predictDeterministicAddress( IMPLEMENTATION_SELF, salt );
        if(  new_hook.code.length != 0  )  revert DeployHookFailed( DeployHookError.ALREADY_EXISTS, new_hook, base_fee_bps, rebate_percent );

        ( uint16 decoded_fee, uint8 decoded_capture )  =  HookAddress.decode( new_hook );
        if(  decoded_fee != base_fee_bps  ||  decoded_capture != rebate_percent  )  revert DeployHookFailed( DeployHookError.CONFIG_MISMATCH, new_hook, base_fee_bps, rebate_percent );

        if(  HookAddress.has_required_permissions( new_hook ) == false  )  revert DeployHookFailed( DeployHookError.PERMISSIONS, new_hook, base_fee_bps, rebate_percent );

        Clones.cloneDeterministic( IMPLEMENTATION_SELF, salt );    // canonical EIP-1167, this implementation baked in.

        SafeSwapHookImpl(new_hook).initialize_once( );             // registers with the router; re-validates codehash + config.
        // *NOTE*  -  No deploy event here; the canonical HookRegistered is emitted by the router on that registration.
    }


    // ━━━━  HOOK CALLBACKS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Authorize a PositionManager-initiated pool initialization.
     */
    function beforeInitialize( address sender, PoolKey calldata, uint160 )
    external  view returns ( bytes4 )
    {
        _require_position_action( sender );

        return IHooks.beforeInitialize.selector;
    }

    /**
     * @notice Authorize a PositionManager-initiated add-liquidity callback.
     */
    function beforeAddLiquidity( address sender, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata )
    external  view returns ( bytes4 )
    {
        _require_position_action( sender );

        return IHooks.beforeAddLiquidity.selector;
    }

    /**
     * @notice Authorize a PositionManager-initiated remove-liquidity callback.
     */
    function beforeRemoveLiquidity( address sender, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata )
    external  view returns ( bytes4 )
    {
        _require_position_action( sender );

        return IHooks.beforeRemoveLiquidity.selector;
    }

    /**
     * @notice Price a router-initiated swap: return `base LP fee + repricing fee` as a dynamic-fee override.
     * @return Hook selector, zero before-swap delta, and the override swap fee in v4 pips.
     *
     * @dev Simulates the swap on the pre-swap pool state to estimate the post-swap tick, then prices the movement. The
     *      override fee accrues natively to the LPs the swap crosses (path-fair). The simulation reads the same storage the
     *      swap will read, warming it.
     */
    function beforeSwap( address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata )
    external  view returns ( bytes4, BeforeSwapDelta, uint24 )
    {
        _require_swap_action( sender );

        ( uint16 fee_bps, uint8 capture_percent )  =  HookAddress.decode( address(this) );
        uint24 base_fee_pips  =  SafeSwapCommon.compute_base_fee_pips( fee_bps );

        // No capture ⇒ repricing fee is always zero and the simulation's output is unused; skip the price-path walk.
        if(  capture_percent == 0  )  return ( IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, LPFeeLibrary.OVERRIDE_FEE_FLAG | base_fee_pips );

        ( , , uint160 sqrt_price_after_x96, uint256 counterpart )  =  SwapSimulator.simulate( PoolManager, key, params.zeroForOne, params.amountSpecified, base_fee_pips );

        ( uint256 amount_in, uint256 amount_out )  =  SafeSwapCommon.compute_swap_amounts( params.amountSpecified, counterpart );

        uint24 swap_fee_pips  =  SafeSwapCommon.compute_repricing_fee_pips( amount_in, amount_out, sqrt_price_after_x96, params.zeroForOne, capture_percent, base_fee_pips );

        return ( IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, LPFeeLibrary.OVERRIDE_FEE_FLAG | swap_fee_pips );
    }


    // ━━━━  INTERNAL HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // *SECURITY*  -  `msg.sender` is the PoolManager; `sender` is the address that opened the action. Only the canonical
    //                SwapRouter may route swaps through SafeSwap pools, and it is BondRoute-gated.
    function _require_swap_action( address sender ) private view
    {
        _require_clone_context( );

        if(  msg.sender != address(PoolManager)  )  revert CallerNotPoolManager({ caller: msg.sender, pool_manager: address(PoolManager) });
        if(  sender != SafeSwapRouter  )            revert CallerNotRouter({ sender: sender, router: SafeSwapRouter });
    }

    // *SECURITY*  -  Pool initialization and liquidity changes may only be initiated by the canonical PositionManager NFT,
    //                which owns the V4 positions and is BondRoute-gated.
    function _require_position_action( address sender ) private view
    {
        _require_clone_context( );

        if(  msg.sender != address(PoolManager)  )  revert CallerNotPoolManager({ caller: msg.sender, pool_manager: address(PoolManager) });
        if(  sender != SafeSwapNft  )               revert CallerNotPositionManager({ sender: sender, position_manager: SafeSwapNft });
    }

    // *SECURITY*  -  The implementation only ever runs under a clone's delegatecall, where `address(this)` is the config
    //                clone. A direct call to the implementation has no valid F/C config and is rejected outright.
    function _require_clone_context( ) private view
    {
        if(  address(this) == IMPLEMENTATION_SELF  )  revert DirectImplementationCallForbidden({ implementation: IMPLEMENTATION_SELF });
    }
}
