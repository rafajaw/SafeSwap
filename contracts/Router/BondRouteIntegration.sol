// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@SafeSwapRouter/User.sol";
import "@SafeSwapRouter/libraries/ExactInputSwapLib.sol";
import "@SafeSwapRouter/libraries/ExactOutputSwapLib.sol";


/**
 * @title BondRouteIntegration
 * @notice BondRoute selector, quote, and signing-info integration for the SafeSwap SwapRouter (swaps only; LP positions are
 *         a separate BondRoute surface on the PositionManager NFT).
 */
abstract contract BondRouteIntegration is User {

    constructor( )
    User( ) { }

    /**
     * @notice Return the swap selectors that require BondRoute execution.
     */
    function BondRoute_get_protected_selectors( )
    public  pure override returns ( bytes4[] memory selectors )
    {
        selectors       =  new bytes4[]( 2 );
        selectors[ 0 ]  =  this.swap_exact_input.selector;
        selectors[ 1 ]  =  this.swap_exact_output.selector;
    }

    /**
     * @notice Quote BondRoute constraints (stake, fundings, timing) for a swap. The repricing/LP fee is not part of the
     *         bond constraints; the trader is protected at execution by their signed slippage bound.
     *
     * @dev ERROR CODES:
     *      - `UnsupportedCall()` if `call` does not target a protected swap.
     */
    function BondRoute_quote_call( bytes calldata call, IERC20, TokenAmount[] memory preferred_fundings )
    public  view override returns ( BondConstraints memory constraints )
    {
        if(  call.length < 4  )  revert UnsupportedCall( );

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
        else
        {
            revert UnsupportedCall( );
        }
    }

    /**
     * @notice Return EIP-712 signing information for a protected swap.
     */
    function BondRoute_get_signing_info( bytes calldata call )
    external  pure override returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )
    {
        if(  call.length < 4  )  revert UnsupportedCall( );

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
        else
        {
            revert UnsupportedCall( );
        }
    }
}
