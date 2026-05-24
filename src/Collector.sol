// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@SafeSwap/Definitions.sol";
import "@BondRouteProtected/BondRouteProtected.sol";
import { ChainConfig } from "@ChainConfig/IChainConfig.sol";
import { SafeERC20 } from "@OpenZeppelin/token/ERC20/utils/SafeERC20.sol";
import { IERC20 as OZ_IERC20 } from "@OpenZeppelin/token/ERC20/IERC20.sol";


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error Invalid( string field, uint256 value );
error TransferFailed( address token, address recipient, uint256 amount );


// ━━━━  EVENTS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

event CollectorTransferInitiated( address indexed current_collector, address indexed pending_collector );
event CollectorTransferred( address indexed previous_collector, address indexed new_collector );
event FeesWithdrawn( address indexed recipient, IERC20 indexed token, uint256 amount );


/**
 * @title Collector
 * @notice Fee withdrawal and collector role transfer.
 */
abstract contract Collector {
    using SafeERC20 for OZ_IERC20;

    address internal _collector;
    address internal _pending_collector;

    /**
     * @notice Initialize the collector from ChainConfig.
     * @dev Reverts with a string error if `INITIAL_COLLECTOR_KEY` is unset or resolves to the zero address.
     */
    constructor( )
    {
        address initial_collector  =  ChainConfig.read_address( CONFIG_SIGNER, INITIAL_COLLECTOR_KEY );

        if(  initial_collector == address(0)  )  revert( "SafeSwap: Invalid initial_collector" );

        _collector  =  initial_collector;

        emit CollectorTransferred( address(0), initial_collector );
    }


    // ━━━━  COLLECTOR GETTER  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Read the current fee collector address.
     */
    function get_collector( )
    external  view returns ( address )
    {
        return _collector;
    }


    // ━━━━  COLLECTOR TRANSFER  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Nominate `new_collector` as the pending collector. The transfer completes
     *         only when the nominee calls `accept_collector`. Two-step to prevent typo loss.
     * @param new_collector Address nominated to become collector. Use `address(0)` to cancel an outstanding nomination.
     *
     * @dev    Passing `address(0)` is the cancel path: it clears any pending nomination
     *         since no one can `accept_collector` as the zero address. No separate cancel
     *         function exists by design.
     *
     * @dev EMITTED EVENTS:
     *      - `CollectorTransferInitiated(current_collector, pending_collector)` on success.
     *
     * @dev ERROR CODES:
     *      - `Unauthorized(address caller, address expected)` if caller is not current collector.
     */
    function transfer_collector( address new_collector )
    external
    {
        if(  msg.sender != _collector  )  revert Unauthorized({ caller: msg.sender, expected: _collector });

        _pending_collector  =  new_collector;

        emit CollectorTransferInitiated( _collector, new_collector );
    }

    /**
     * @notice Accept a pending collector nomination. Only callable by the pending collector.
     *
     * @dev EMITTED EVENTS:
     *      - `CollectorTransferred(previous_collector, new_collector)` on success.
     *
     * @dev ERROR CODES:
     *      - `Unauthorized(address caller, address expected)` if caller is not pending collector.
     */
    function accept_collector( )
    external
    {
        if(  msg.sender != _pending_collector  )  revert Unauthorized({ caller: msg.sender, expected: _pending_collector });

        address previous     =   _collector;
        _collector           =   _pending_collector;
        _pending_collector   =   address(0);

        emit CollectorTransferred( previous, _collector );
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
     *      - `FeesWithdrawn(recipient, token, amount)` when a nonzero withdrawal happens.
     *
     * @dev ERROR CODES:
     *      - `Unauthorized(address caller, address expected)` if caller is not collector.
     *      - `Invalid(string field, uint256 value)` if `recipient` is zero address.
     *      - `TransferFailed(address token, address recipient, uint256 amount)` if token or native transfer fails.
     */
    function withdraw_fees( IERC20 token, address recipient )
    external  returns ( uint256 withdraw_amount )
    {
        if(  msg.sender != _collector  )  revert Unauthorized({ caller: msg.sender, expected: _collector });
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

        emit FeesWithdrawn( recipient, token, withdraw_amount );
    }
}
