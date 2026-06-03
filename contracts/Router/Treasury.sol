// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@SafeSwapRouter/Definitions.sol";
import "@BondRouteProtected/BondRouteProtected.sol";
import { ChainConfig } from "@ChainConfig/IChainConfig.sol";
import { SafeERC20 } from "@OpenZeppelin/token/ERC20/utils/SafeERC20.sol";
import { IERC20 as OZ_IERC20 } from "@OpenZeppelin/token/ERC20/IERC20.sol";


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error Invalid( string field, uint256 value );
error TransferFailed( address token, address recipient, uint256 amount );


// ━━━━  EVENTS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

event TreasuryTransferInitiated( address indexed current_treasury, address indexed pending_treasury );
event TreasuryTransferred( address indexed previous_treasury, address indexed new_treasury );
event ProtocolFeesWithdrawn( address indexed recipient, IERC20 indexed token, uint256 amount );


/**
 * @title Treasury
 * @notice SafeSwap protocol-fee withdrawal and treasury role transfer.
 */
abstract contract Treasury {
    using SafeERC20 for OZ_IERC20;

    address internal _treasury;
    address internal _pending_treasury;

    /**
     * @notice Initialize the treasury from ChainConfig.
     * @dev Reverts with a string error if `INITIAL_TREASURY_KEY` is unset or resolves to the zero address.
     */
    constructor( )
    {
        address initial_treasury  =  ChainConfig.read_address( CONFIG_SIGNER, INITIAL_TREASURY_KEY );

        if(  initial_treasury == address(0)  )  revert( "SafeSwap: Invalid initial_treasury" );

        _treasury  =  initial_treasury;

        emit TreasuryTransferred( address(0), initial_treasury );
    }


    // ━━━━  TREASURY GETTER  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Read the current SafeSwap treasury address.
     */
    function get_treasury( )
    external  view returns ( address )
    {
        return _treasury;
    }


    // ━━━━  TREASURY TRANSFER  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Nominate `new_treasury` as the pending treasury. The transfer completes
     *         only when the nominee calls `accept_treasury`. Two-step to prevent typo loss.
     * @param new_treasury Address nominated to become treasury. Use `address(0)` to cancel an outstanding nomination.
     *
     * @dev    Passing `address(0)` is the cancel path: it clears any pending nomination
     *         since no one can `accept_treasury` as the zero address. No separate cancel
     *         function exists by design.
     *
     * @dev EMITTED EVENTS:
     *      - `TreasuryTransferInitiated(current_treasury, pending_treasury)` on success.
     *
     * @dev ERROR CODES:
     *      - `Unauthorized(address caller, address expected)` if caller is not current treasury.
     *      - `Invalid(string field, uint256 value)` if `new_treasury` is the current treasury.
     */
    function transfer_treasury( address new_treasury )
    external
    {
        if(  msg.sender != _treasury  )  revert Unauthorized({ caller: msg.sender, expected: _treasury });
        if(  new_treasury == _treasury  )  revert Invalid({ field: "new_treasury", value: uint256(uint160(new_treasury)) });

        _pending_treasury  =  new_treasury;

        emit TreasuryTransferInitiated( _treasury, new_treasury );
    }

    /**
     * @notice Accept a pending treasury nomination. Only callable by the pending treasury.
     *
     * @dev EMITTED EVENTS:
     *      - `TreasuryTransferred(previous_treasury, new_treasury)` on success.
     *
     * @dev ERROR CODES:
     *      - `Unauthorized(address caller, address expected)` if caller is not pending treasury.
     */
    function accept_treasury( )
    external
    {
        if(  msg.sender != _pending_treasury  )  revert Unauthorized({ caller: msg.sender, expected: _pending_treasury });

        address previous   =   _treasury;
        _treasury          =   _pending_treasury;
        _pending_treasury  =   address(0);

        emit TreasuryTransferred( previous, _treasury );
    }


    // ━━━━  FEE WITHDRAWAL  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Withdraw accumulated SafeSwap protocol fees.
     * @param token Token to withdraw. Use `NATIVE_TOKEN` for native ETH.
     * @param recipient Address receiving withdrawn fees.
     * @return withdraw_amount Amount transferred to `recipient`.
     *
     * @dev Keeps 1 wei of each token in the contract to avoid zero-to-nonzero storage/accounting costs on future fee collection.
     *
     * @dev EMITTED EVENTS:
     *      - `ProtocolFeesWithdrawn(recipient, token, amount)` when a nonzero withdrawal happens.
     *
     * @dev ERROR CODES:
     *      - `Unauthorized(address caller, address expected)` if caller is not treasury.
     *      - `Invalid(string field, uint256 value)` if `recipient` is zero address.
     *      - `TransferFailed(address token, address recipient, uint256 amount)` if token or native transfer fails.
     */
    function withdraw_protocol_fees( IERC20 token, address recipient )
    external  returns ( uint256 withdraw_amount )
    {
        if(  msg.sender != _treasury  )  revert Unauthorized({ caller: msg.sender, expected: _treasury });
        if(  recipient == address(0)  )  revert Invalid({ field: "recipient", value: 0 });

        bool is_native  =  address(token) == address(NATIVE_TOKEN);

        uint256 balance  =  is_native  ?  address(this).balance  :  token.balanceOf( address(this) );

        if(  balance <= 1  )  return 0;  // *GAS SAVING*  -  Keeps 1 wei to avoid 0 to non-0 writes on next fee collection.

        withdraw_amount  =  balance - 1;

        if(  is_native  )
        {
            ( bool success, )  =  recipient.call{ value: withdraw_amount }( "" );
            if(  success == false  )  revert TransferFailed({ token: address(token), recipient: recipient, amount: withdraw_amount });
        }
        else
        {
            bool success  =  OZ_IERC20(address(token)).trySafeTransfer( recipient, withdraw_amount );
            if(  success == false  )  revert TransferFailed({ token: address(token), recipient: recipient, amount: withdraw_amount });
        }

        emit ProtocolFeesWithdrawn( recipient, token, withdraw_amount );
    }
}
