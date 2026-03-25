// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@SafeSwap/Collector.sol";


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error UnknownSelector( bytes4 selector );


/**
 * @title SafeSwap
 * @notice MEV-protected Uniswap V4 hook powered by BondRoute
 * @dev Pools using this hook require all swaps and liquidity operations to go through BondRoute protection
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

    constructor( address initial_collector )
    Collector( initial_collector ) { }


    // ━━━━  BONDROUTE INTERFACE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function BondRoute_get_protected_selectors( )
    public pure override returns ( bytes4[] memory selectors )
    {
        selectors       =  new bytes4[]( 4 );
        selectors[ 0 ]  =  this.swap_exact_input.selector;
        selectors[ 1 ]  =  this.swap_exact_output.selector;
        selectors[ 2 ]  =  this.add_liquidity.selector;
        selectors[ 3 ]  =  this.remove_liquidity.selector;
    }

    function BondRoute_quote_call( bytes calldata call, IERC20, TokenAmount[] memory preferred_fundings )
    public pure override returns ( BondConstraints memory constraints )
    {
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
            return AddLiquidityLib.get_constraints( params, preferred_fundings );
        }
        else if(  selector == this.remove_liquidity.selector  )
        {
            RemoveLiquidityParams memory params  =  abi.decode( call[ 4: ], (RemoveLiquidityParams) );
            return RemoveLiquidityLib.get_constraints( params );
        }
        else
        {
            revert UnknownSelector( selector );
        }
    }

    function BondRoute_get_signing_info( bytes calldata call )
    external pure override returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )
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
        else
        {
            return ( "", bytes32(0), 0 );  // Fallback to calldata hash for unknown selectors.
        }
    }

    receive( )
    external payable { }
}
