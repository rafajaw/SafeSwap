// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/*

        ███████╗ █████╗ ███████╗███████╗███████╗██╗    ██╗ █████╗ ██████╗
        ██╔════╝██╔══██╗██╔════╝██╔════╝██╔════╝██║    ██║██╔══██╗██╔══██╗
        ███████╗███████║█████╗  █████╗  ███████╗██║ █╗ ██║███████║██████╔╝
        ╚════██║██╔══██║██╔══╝  ██╔══╝  ╚════██║██║███╗██║██╔══██║██╔═══╝
        ███████║██║  ██║██║     ███████╗███████║╚███╔███╔╝██║  ██║██║
        ╚══════╝╚═╝  ╚═╝╚═╝     ╚══════╝╚══════╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝
        ━━━━━━━━━━━━  Trustless MEV-protected Uniswap pools  ━━━━━━━━━━━━━

*/

import "@SafeSwapHook/ISafeSwapHook.sol";
import {
    CONFIG_SIGNER,
    POOL_MANAGER_KEY,
    SAFESWAP_ROUTER_KEY,
    SAFESWAP_HOOK_ADDRESS_MAGIC,
    HOOK_ADDRESS_MAGIC_SHIFT,
    HOOK_ADDRESS_REBATE_PROFILE_SHIFT,
    HOOK_ADDRESS_REBATE_PROFILE_MASK,
    HOOK_PERMISSIONS_MASK,
    REQUIRED_HOOK_PERMISSIONS,
    MAX_REBATE_PROFILE
} from "@SafeSwapRouter/Definitions.sol";
import { ChainConfig } from "@ChainConfig/IChainConfig.sol";
import { IHooks } from "@UniswapV4Core/interfaces/IHooks.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "@UniswapV4Core/types/BeforeSwapDelta.sol";


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error HookAddressMagicMismatch( address hook, uint8 magic );
error HookAddressRebateProfileInvalid( address hook, uint8 rebate_profile );
error HookAddressPermissionsMismatch( address hook, uint160 permission_bits );
error CallerNotPoolManager( address caller, address pool_manager );
error CallerNotRouter( address sender, address router );


/**
 * @title SafeSwapHook
 * @notice Permissionlessly-deployed Uniswap V4 config hook for one LP repricing rebate profile.
 *
 * @dev Every instance shares the same runtime bytecode: the rebate profile is decoded from `address(this)` and kept in
 *      storage (never an immutable), so the audited runtime codehash is uniform and the router can authorize hooks by
 *      exact codehash. The economic profile is bound to the CREATE2 address, which makes each profile a distinct V4 PoolId.
 *
 *      The hook itself does not compute the repricing rebate — the router measures the swap's real tick movement and
 *      donates the rebate to LPs. The hook only gates every pool action to the canonical router.
 */
contract SafeSwapHook is ISafeSwapHook {

    IPoolManager public immutable PoolManager;
    address public immutable SafeSwapRouter;

    uint8 public rebate_profile;

    /**
     * @notice Decode and validate the rebate profile from this hook's CREATE2 address and wire the PoolManager/router.
     * @dev Reverts with explicit errors if the deployed address does not encode the SafeSwap magic byte, a supported
     *      rebate profile, and exactly the required Uniswap V4 hook permission bits.
     */
    constructor( )
    {
        uint160 self  =  uint160(address(this));

        uint8 magic  =  uint8(self >> HOOK_ADDRESS_MAGIC_SHIFT);
        if(  magic != SAFESWAP_HOOK_ADDRESS_MAGIC  )  revert HookAddressMagicMismatch({ hook: address(this), magic: magic });

        uint8 profile  =  uint8((self >> HOOK_ADDRESS_REBATE_PROFILE_SHIFT) & HOOK_ADDRESS_REBATE_PROFILE_MASK);
        if(  profile > MAX_REBATE_PROFILE  )  revert HookAddressRebateProfileInvalid({ hook: address(this), rebate_profile: profile });

        uint160 permission_bits  =  self & HOOK_PERMISSIONS_MASK;
        if(  permission_bits != REQUIRED_HOOK_PERMISSIONS  )  revert HookAddressPermissionsMismatch({ hook: address(this), permission_bits: permission_bits });

        address pool_manager  =  ChainConfig.read_address( CONFIG_SIGNER, POOL_MANAGER_KEY );
        if(  pool_manager.code.length == 0  )  revert( "SafeSwapHook: Invalid pool_manager" );

        address router  =  ChainConfig.read_address( CONFIG_SIGNER, SAFESWAP_ROUTER_KEY );
        if(  router.code.length == 0  )  revert( "SafeSwapHook: Invalid router" );

        PoolManager     =  IPoolManager(pool_manager);
        SafeSwapRouter  =  router;
        rebate_profile  =  profile;
    }


    // ━━━━  REGISTRATION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Register this hook with the canonical router for its rebate profile. Idempotent.
     * @dev The router re-validates this hook's runtime codehash, address-bit config, and V4 permission bits before binding.
     */
    function initialize_once( )
    external
    {
        ISafeSwapHookRegistry(SafeSwapRouter).register_hook( rebate_profile );
    }


    // ━━━━  HOOK CALLBACKS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Authorize a SafeSwap-router-initiated Uniswap V4 pool initialization.
     * @dev Only the canonical router may initialize a SafeSwap pool, which closes the permissionless first-price attack.
     */
    function beforeInitialize( address sender, PoolKey calldata, uint160 )
    external  view returns ( bytes4 )
    {
        _require_router_action( sender );

        return IHooks.beforeInitialize.selector;
    }

    /**
     * @notice Authorize a SafeSwap-router-initiated add-liquidity callback.
     */
    function beforeAddLiquidity( address sender, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata )
    external  view returns ( bytes4 )
    {
        _require_router_action( sender );

        return IHooks.beforeAddLiquidity.selector;
    }

    /**
     * @notice Authorize a SafeSwap-router-initiated remove-liquidity callback.
     */
    function beforeRemoveLiquidity( address sender, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata )
    external  view returns ( bytes4 )
    {
        _require_router_action( sender );

        return IHooks.beforeRemoveLiquidity.selector;
    }

    /**
     * @notice Authorize a SafeSwap-router-initiated swap callback.
     * @return Hook selector, zero before-swap delta, and zero LP fee override (SafeSwap pools are static-fee).
     */
    function beforeSwap( address sender, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata )
    external  view returns ( bytes4, BeforeSwapDelta, uint24 )
    {
        _require_router_action( sender );

        return ( IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0 );
    }

    /**
     * @notice Authorize a SafeSwap-router-initiated donation callback (including LP repricing rebate donations).
     */
    function beforeDonate( address sender, PoolKey calldata, uint256, uint256, bytes calldata )
    external  view returns ( bytes4 )
    {
        _require_router_action( sender );

        return IHooks.beforeDonate.selector;
    }


    // ━━━━  INTERNAL HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // *SECURITY*  -  `msg.sender` is the PoolManager; `sender` is the address that opened the action (the unlocker / initializer).
    //                Only the canonical SafeSwap router may route actions through SafeSwap pools, and the router is
    //                BondRoute-gated, so this single identity check is the whole access boundary for SafeSwap pools.
    function _require_router_action( address sender ) private view
    {
        if(  msg.sender != address(PoolManager)  )  revert CallerNotPoolManager({ caller: msg.sender, pool_manager: address(PoolManager) });
        if(  sender != SafeSwapRouter  )            revert CallerNotRouter({ sender: sender, router: SafeSwapRouter });
    }
}
