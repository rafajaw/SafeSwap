// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/*

        ███████╗ █████╗ ███████╗███████╗███████╗██╗    ██╗ █████╗ ██████╗
        ██╔════╝██╔══██╗██╔════╝██╔════╝██╔════╝██║    ██║██╔══██╗██╔══██╗
        ███████╗███████║█████╗  █████╗  ███████╗██║ █╗ ██║███████║██████╔╝
        ╚════██║██╔══██║██╔══╝  ██╔══╝  ╚════██║██║███╗██║██╔══██║██╔═══╝
        ███████║██║  ██║██║     ███████╗███████║╚███╔███╔╝██║  ██║██║
        ╚══════╝╚═╝  ╚═╝╚═╝     ╚══════╝╚══════╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝
        ━━━━━━━━━━━━━━━━━  MEV-protected Uniswap pools  ━━━━━━━━━━━━━━━━━━

*/

import "@SafeSwap/Collector.sol";


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error UnknownSelector( bytes4 selector );


/**
 * @title SafeSwap
 * @notice MEV-protected Uniswap V4 hook powered by BondRoute.
 * @dev Pools using this hook require swaps, liquidity operations, and donations to execute through BondRoute protection.
 *
 * Inheritance Chain (base → derived):
 *   BondRouteProtected, UniswapHook → User → Collector → SafeSwap
 *
 *   BondRouteProtected - commit-reveal bond mechanism
 *   UniswapHook        - PoolManager + V4 callbacks + protected context
 *   User               - user functions (swap, liquidity) + off-chain getters
 *   Collector          - fee withdrawal + role transfer
 *   SafeSwap           - BondRoute interface overrides + receive()
 */
contract SafeSwap is Collector {

    /**
     * @notice Deploy SafeSwap and initialize PoolManager, BondRoute, and collector configuration.
     * @dev Constructor reads deployment configuration from ChainConfig and reverts with string errors for human-facing deployment failures.
     */
    constructor( )
    Collector( ) { }


    // ━━━━  BONDROUTE INTERFACE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Return the SafeSwap selectors that require BondRoute execution.
     * @return selectors Protected function selectors exposed by this contract.
     */
    function BondRoute_get_protected_selectors( )
    public  pure  override  returns ( bytes4[] memory selectors )
    {
        selectors       =  new bytes4[]( 5 );
        selectors[ 0 ]  =  this.swap_exact_input.selector;
        selectors[ 1 ]  =  this.swap_exact_output.selector;
        selectors[ 2 ]  =  this.add_liquidity.selector;
        selectors[ 3 ]  =  this.remove_liquidity.selector;
        selectors[ 4 ]  =  this.donate.selector;
    }

    /**
     * @notice Validate a BondRoute execution against SafeSwap constraints.
     * @dev Extends BondRouteProtected validation with a seconds-based delay floor, orthogonal to block-depth delay.
     */
    function BondRoute_validate( bytes calldata call, BondContext memory context )
    internal  view  override
    {
        super.BondRoute_validate( call, context );

        if(  block.timestamp < context.creation_timestamp + MIN_BOND_EXECUTION_DELAY_IN_SECONDS  )
        {
            revert PossiblyBondFarming({
                reason: EXECUTION_TOO_SOON,
                additional_info: bytes32(MIN_BOND_EXECUTION_DELAY_IN_SECONDS)
            });
        }
    }

    /**
     * @notice Quote BondRoute constraints for a SafeSwap action.
     * @param call Encoded SafeSwap function call.
     * @param preferred_fundings Funding tokens and amounts the user intends to authorize.
     * @return constraints Required stake, fundings, and timing constraints for the call.
     *
     * @dev The preferred stake token argument is intentionally unused. SafeSwap derives stake token from action economics:
     *      swap stake is in the input token; liquidity and donation stake is denominated in token0.
     *
     * @dev ERROR CODES:
     *      - `UnknownSelector(bytes4 selector)` if `call` does not target a protected SafeSwap action.
     *      - `Error(string)` if the funding count is invalid or token pair is invalid.
     *      - `UnsupportedFeeTier(uint24 fee)` if the target pool uses dynamic fees.
     */
    function BondRoute_quote_call( bytes calldata call, IERC20, TokenAmount[] memory preferred_fundings )
    public  view  override  returns ( BondConstraints memory constraints )
    {
        // *GAS SAVING*  -  No length guard on `call`: malformed inputs revert naturally on slice/decode. An upfront
        //                  check would cost gas on every honest call to clarify an already-impossible BondRoute path.
        bytes4 selector  =  bytes4(call);

        if(  selector == this.swap_exact_input.selector  )
        {
            ExactInputSwapParams memory params  =  abi.decode( call[ 4: ], (ExactInputSwapParams) );
            return ExactInputSwapLib.get_constraints( params, preferred_fundings );
        }
        else if(  selector == this.swap_exact_output.selector  )
        {
            ExactOutputSwapParams memory params  =  abi.decode( call[ 4: ], (ExactOutputSwapParams) );
            return ExactOutputSwapLib.get_constraints( params, preferred_fundings );
        }
        else if(  selector == this.add_liquidity.selector  )
        {
            AddLiquidityParams memory params  =  abi.decode( call[ 4: ], (AddLiquidityParams) );
            return AddLiquidityLib.get_constraints( params, preferred_fundings, PoolManager, address(this) );
        }
        else if(  selector == this.remove_liquidity.selector  )
        {
            RemoveLiquidityParams memory params  =  abi.decode( call[ 4: ], (RemoveLiquidityParams) );
            return RemoveLiquidityLib.get_constraints( params, preferred_fundings, PoolManager, address(this) );
        }
        else if(  selector == this.donate.selector  )
        {
            DonateParams memory params  =  abi.decode( call[ 4: ], (DonateParams) );
            return DonateLib.get_constraints( params, preferred_fundings, PoolManager, address(this) );
        }
        else
        {
            revert UnknownSelector( selector );
        }
    }

    /**
     * @notice Return SafeSwap-specific EIP-712 signing information for a protected call.
     * @param call Encoded SafeSwap function call.
     * @return typed_string Complete EIP-712 type string for wallet display.
     * @return struct_hash Hash of the typed SafeSwap call struct.
     * @return token_amount_offset Byte offset used by BondRoute wallet tooling for TokenAmount display.
     *
     * @dev Unknown selectors revert so wallets do not present unsupported SafeSwap actions for signing.
     */
    function BondRoute_get_signing_info( bytes calldata call )
    external  pure  override  returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )
    {
        bytes4 selector  =  bytes4(call);

        if(  selector == this.swap_exact_input.selector  )
        {
            ExactInputSwapParams memory params  =  abi.decode( call[ 4: ], (ExactInputSwapParams) );
            return ExactInputSwapLib.get_signing_info( params );
        }
        else if(  selector == this.swap_exact_output.selector  )
        {
            ExactOutputSwapParams memory params  =  abi.decode( call[ 4: ], (ExactOutputSwapParams) );
            return ExactOutputSwapLib.get_signing_info( params );
        }
        else if(  selector == this.add_liquidity.selector  )
        {
            AddLiquidityParams memory params  =  abi.decode( call[ 4: ], (AddLiquidityParams) );
            return AddLiquidityLib.get_signing_info( params );
        }
        else if(  selector == this.remove_liquidity.selector  )
        {
            RemoveLiquidityParams memory params  =  abi.decode( call[ 4: ], (RemoveLiquidityParams) );
            return RemoveLiquidityLib.get_signing_info( params );
        }
        else if(  selector == this.donate.selector  )
        {
            DonateParams memory params  =  abi.decode( call[ 4: ], (DonateParams) );
            return DonateLib.get_signing_info( params );
        }
        else
        {
            revert UnknownSelector( selector );
        }
    }

    /**
     * @notice Receive native token from PoolManager (protocol fees on native swaps) or BondRoute (native funding pulls).
     * @dev Reverts on any other sender — SafeSwap has no donation surface.
     */
    receive( )
    external  payable
    {
        if(  msg.sender != address(PoolManager)  &&  msg.sender != BONDROUTE_ADDRESS  )  revert( "Direct transfers not allowed" );
    }
}
