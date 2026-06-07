// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@BondRouteProtected/BondRouteProtected.sol";
import "@SafeSwapCommon/SafeSwapCommon.sol";
import "@SafeSwapCommon/SigningLib.sol";
import "@SafeSwapCommon/Definitions.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { BalanceDelta } from "@UniswapV4Core/types/BalanceDelta.sol";
import { TickMath } from "@UniswapV4Core/libraries/TickMath.sol";
import { LPFeeLibrary } from "@UniswapV4Core/libraries/LPFeeLibrary.sol";


// ━━━━  PARAMETERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/**
 * @notice Exact-input swap parameters signed by the user.
 * @param token_in Token the user pays. Must equal the bond's single funding token (validated at execution).
 * @param input_amount Exact input the user pays. Must equal the bond's single funding amount (validated at execution).
 * @param token_out Token the user receives.
 * @param minimum_output_amount Minimum net output after the SafeSwap protocol fee.
 * @param pool_info Target SafeSwap pool configuration (base fee, capture, tick spacing).
 *
 * @dev The input is signed here (it is the receipt's `Pay` field) and is the display source of truth; execution still
 *      reads the actual input from the bond funding but reverts if the funding does not match the signed input. The base LP
 *      fee and the repricing fee are charged inside the pool by the hook's dynamic-fee override and accrue to LPs; this
 *      struct's `base_fee_bps` only drives the separate SafeSwap protocol fee.
 */
struct ExactInputSwapParams {
    IERC20 token_in;
    uint256 input_amount;
    IERC20 token_out;
    uint256 minimum_output_amount;
    PoolInfo pool_info;
}


/**
 * @title ExactInputSwapLib
 * @notice Exact-input swaps via SafeSwap on dynamic-fee pools. The LP fee (base + repricing) is applied natively by the
 *         hook; this library only takes the SafeSwap protocol fee from the output and enforces slippage.
 */
library ExactInputSwapLib {
    using FundingsLib for BondContext;


    // ━━━━  EIP-712 SIGNING (SIGNING_UX_REFERENCE_2)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // The loud display label BondRoute shows for the action field, and the human inner type name.
    string constant SWAP_FIELD_DECLARATION  =  "ExactInputSwap sS__SWAP__Ss";

    // Inner struct definition framing the symbol address anchor: "ExactInputSwap(...,address <token_out symbol>)".
    string constant INNER_DEFINITION_HEAD  =  "ExactInputSwap(string Pay,string Receive,string Pool,string Warning,address ";

    /**
     * @notice Build the REFERENCE_2 receipt for an exact-input swap: `Pay` (= input), `Receive` (>= min output), `Pool`,
     *         `Warning`, and the received-token address anchored under its sanitized symbol.
     * @dev `view` (not `pure`) because it reads each token's `symbol()` / `decimals()` defensively once.
     */
    function get_signing_info( ExactInputSwapParams memory params )
    internal view returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )
    {
        string memory symbol_in   =  SigningLib.read_sanitized_symbol( params.token_in );
        string memory symbol_out  =  SigningLib.read_sanitized_symbol( params.token_out );

        string memory pay      =  SigningLib.render_single_amount_value( SigningLib.OPERATOR_EXACT, params.input_amount, SigningLib.read_token_decimals( params.token_in ), symbol_in );
        string memory receive_value  =  SigningLib.render_single_amount_value( SigningLib.OPERATOR_AT_LEAST, params.minimum_output_amount, SigningLib.read_token_decimals( params.token_out ), symbol_out );
        string memory pool     =  SigningLib.render_pool_value( params.pool_info );

        string memory inner_definition  =  string.concat( INNER_DEFINITION_HEAD, symbol_out, ")" );

        ( typed_string, token_amount_offset )  =  SigningLib.build_typed_string( SWAP_FIELD_DECLARATION, inner_definition );

        struct_hash  =  SigningLib.hash_words(
            SigningLib.hash_string( inner_definition ),
            SigningLib.hash_string( pay ),
            SigningLib.hash_string( receive_value ),
            SigningLib.hash_string( pool ),
            SigningLib.WARNING_VALUE_HASH,
            SigningLib.encode_address_word( address(params.token_out) )
        );
    }

    function get_signing_values( ExactInputSwapParams memory params )
    internal view returns ( string[] memory display_values, address[] memory token_addresses )
    {
        string memory symbol_in   =  SigningLib.read_sanitized_symbol( params.token_in );
        string memory symbol_out  =  SigningLib.read_sanitized_symbol( params.token_out );

        display_values     =  new string[]( 4 );
        display_values[0]  =  SigningLib.render_single_amount_value( SigningLib.OPERATOR_EXACT, params.input_amount, SigningLib.read_token_decimals( params.token_in ), symbol_in );
        display_values[1]  =  SigningLib.render_single_amount_value( SigningLib.OPERATOR_AT_LEAST, params.minimum_output_amount, SigningLib.read_token_decimals( params.token_out ), symbol_out );
        display_values[2]  =  SigningLib.render_pool_value( params.pool_info );
        display_values[3]  =  SigningLib.WARNING_VALUE;

        token_addresses     =  new address[]( 1 );
        token_addresses[0]  =  address(params.token_out);
    }


    // ━━━━  GET CONSTRAINTS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function get_constraints( ExactInputSwapParams memory params )
    internal pure returns ( BondConstraints memory constraints )
    {
        if(  address(params.token_in) == address(params.token_out)  )  revert( TOKENS_MUST_BE_DIFFERENT );

        TokenAmount memory declared_funding         =  TokenAmount({ token: params.token_in, amount: params.input_amount });
        constraints.min_stake                       =  SafeSwapCommon.calculate_swap_stake( declared_funding );
        constraints.min_fundings                    =  new TokenAmount[](1);
        constraints.min_fundings[0]                 =  declared_funding;
        constraints.min_execution_delay_in_blocks   =  MIN_BOND_EXECUTION_DELAY_IN_BLOCKS;
        constraints.min_execution_delay_in_seconds  =  MIN_BOND_EXECUTION_DELAY_IN_SECONDS;
        constraints.max_execution_delay_in_seconds  =  MAX_BOND_EXECUTION_DELAY_IN_SECONDS;
    }


    // ━━━━  EXECUTE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function execute( BondContext memory context, ExactInputSwapParams memory params, IPoolManager pool_manager, address hook, address router ) internal
    {
        IERC20 token_in    =  context.fundings[ 0 ].token;
        uint256 amount_in  =  context.fundings[ 0 ].amount;

        // *SECURITY*  -  The signed `Pay` field is the display source of truth. Reject any funding that does not match the
        //                signed input token and amount, so a relayer cannot fund a different asset than the user saw.
        if(  address(token_in) != address(params.token_in)  ||  amount_in != params.input_amount  )
        {
            revert SignedSwapInputMismatch({ signed_token: address(params.token_in), signed_amount: params.input_amount, funded_token: address(token_in), funded_amount: amount_in });
        }

        PoolKey memory pool_key  =  SafeSwapCommon.build_pool_key( token_in, params.token_out, LPFeeLibrary.DYNAMIC_FEE_FLAG, params.pool_info.tick_spacing, hook );

        bool zero_for_one  =  address(token_in) < address(params.token_out);

        IPoolManager.SwapParams memory swap_params  =  IPoolManager.SwapParams({
            zeroForOne: zero_for_one,
            amountSpecified: -int256(amount_in),
            sqrtPriceLimitX96: zero_for_one ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta  =  pool_manager.swap( pool_key, swap_params, "" );

        // *NOTE*  -  Output delta is positive (pool owes us), already net of the LP fee the hook applied. The SafeSwap
        //            protocol fee is taken on top of that; the LP base + repricing fee already accrued to LPs in the pool.
        uint256 pool_output  =  zero_for_one ? uint256(int256(delta.amount1( ))) : uint256(int256(delta.amount0( )));

        ( uint256 protocol_fee, uint256 user_output )  =  SafeSwapCommon.calculate_protocol_fee( pool_output, SafeSwapCommon.compute_base_fee_pips( params.pool_info.base_fee_bps ) );

        if(  user_output < params.minimum_output_amount  )  revert SlippageExceeded({ amount_received: user_output, minimum_required: params.minimum_output_amount });

        SafeSwapCommon.settle_and_take( pool_manager, context, token_in, params.token_out, amount_in, user_output, protocol_fee, router );
    }
}
