// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@SafeSwap/User.sol";
import "@SafeSwap/Definitions.sol";
import { ChainConfig } from "@SafeSwap/integrations/IChainConfig.sol";
import { SafeERC20 } from "@OpenZeppelin/token/ERC20/utils/SafeERC20.sol";
import { IERC20 as OZ_IERC20 } from "@OpenZeppelin/token/ERC20/IERC20.sol";


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error Invalid( string field, uint256 value );
error TransferFailed( address token, address recipient, uint256 amount );


// ━━━━  EVENTS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

event CollectorTransferStarted( address indexed current_collector, address indexed pending_collector );
event CollectorTransferred( address indexed previous_collector, address indexed new_collector );
event FeesWithdrawn( IERC20 indexed token, address indexed recipient, uint256 amount );


/**
 * @title Collector
 * @notice Fee withdrawal and role transfer
 */
abstract contract Collector is User {
    using SafeERC20 for OZ_IERC20;

    address public collector;
    address public pending_collector;

    constructor( )
    User( )
    {
        address initial_collector  =  ChainConfig.read_address( CONFIG_SIGNER, INITIAL_COLLECTOR_KEY );

        if(  initial_collector == address(0)  )  revert( "SafeSwap: Invalid initial_collector" );

        collector  =  initial_collector;

        emit CollectorTransferred( address(0), initial_collector );
    }


    // ━━━━  COLLECTOR TRANSFER  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Nominate `new_collector` as the pending collector. The transfer completes
     *         only when the nominee calls `accept_collector`. Two-step to prevent typo loss.
     * @dev    Passing `address(0)` is the cancel path: it clears any pending nomination
     *         since no one can `accept_collector` as the zero address. No separate cancel
     *         function exists by design.
     */
    function transfer_collector( address new_collector )
    external
    {
        if(  msg.sender != collector  )  revert Unauthorized({ caller: msg.sender, expected: collector });

        pending_collector  =  new_collector;
        emit CollectorTransferStarted( collector, new_collector );
    }

    /**
     * @notice Accept a pending collector nomination. Only callable by the pending collector.
     */
    function accept_collector( )
    external
    {
        if(  msg.sender != pending_collector  )  revert Unauthorized({ caller: msg.sender, expected: pending_collector });

        address previous    =   collector;
        collector           =   pending_collector;
        pending_collector   =   address(0);

        emit CollectorTransferred( previous, collector );
    }


    // ━━━━  FEE WITHDRAWAL  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function withdraw_fees( IERC20 token, address recipient )
    external  returns ( uint256 withdraw_amount )
    {
        if(  msg.sender != collector  )  revert Unauthorized({ caller: msg.sender, expected: collector });
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

        emit FeesWithdrawn( token, recipient, withdraw_amount );
    }
}
