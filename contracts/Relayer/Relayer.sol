// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ExecutionData } from "@BondRoute/Core.sol";
import { IERC20, NATIVE_TOKEN, BONDROUTE_ADDRESS } from "@BondRouteProtected/BondRouteProtected.sol";
import { SafeTransferLib } from "@Solady/utils/SafeTransferLib.sol";


/**
 * @title Relayer
 * @notice EIP-7702 delegate for gasless SafeSwap execution. A relayer pays the gas; the user only signs. The user's EOA
 *         delegates to this code (7702 style), so every line below runs *as the user's own account*: it sets the user's own
 *         token allowances to the canonical BondRoute and drives the bonded execution.
 *
 *         The relayer fronts and creates the bond itself from inventory (a normal `create_bond` from the relayer's own key,
 *         staking the relayer's own tokens), so this delegate never stakes the user's funds — and therefore exposes *only*
 *         the execute path. Execution is gated on the user's `ExecuteBondAs` signature, which BondRoute verifies, so nobody
 *         can execute on the user's behalf without their signed message.
 *
 *         *SECURITY*  -  Deliberately no create entrypoint. A delegate that staked the user's funds from opaque commitment
 *                        data could not be gated by the `execute_bond_as` signature: that signature binds fundings/call via
 *                        their EIP-712 hashes, while the commitment binds them via different (plain) hashes, and the two are
 *                        independent calldata at commit time — leaving the commitment's hashes unsigned and a griefer free to
 *                        lock the user's stake into an unexecutable bond. Fronting the stake from relayer inventory removes
 *                        the user-fund griefing surface entirely.
 */
contract Relayer {

    using SafeTransferLib for address;

    uint256 constant INFINITE_TOKEN_AMOUNT  =  type(uint256).max;

    /**
     * @notice Accept native value sent to the user's EOA. Required: a gasless op can *release* native to the user
     *         mid-execution — a native-output swap, a remove/collect that pays out ETH, or a stake/refund return at
     *         settlement — and those arrive as an empty-calldata `call{value}("")` that dispatches here. Without it the
     *         payout (and the whole `execute_bond_as`) reverts. It also restores plain-EOA semantics: a delegated account
     *         that lacks `receive()` would otherwise bounce ordinary ETH transfers while the 7702 delegation persists.
     *
     *         *SECURITY*  -  `receive()` only, no payable `fallback()`: keep the "no arbitrary call surface" property —
     *                        native payouts use empty calldata, so `receive()` is sufficient.
     */
    receive() external payable { }

    /**
     * @notice Approve the funding tokens to BondRoute and execute the user's bond. BondRoute itself verifies the signature.
     */
    function approve_fundings_and_execute_bond_as_user( ExecutionData calldata execution_data, address user, bytes calldata signature, bool is_eip1271 )
    external
    {
        for(  uint256 i = 0  ;  i < execution_data.fundings.length  ;  i++  )
        {
            _approve_max_to_bond_route( execution_data.fundings[ i ].token );
        }

        IBondRouteSingleton( BONDROUTE_ADDRESS ).execute_bond_as( execution_data, user, signature, is_eip1271 );
    }

    /**
     * @dev Set an infinite BondRoute allowance. `safeApproveWithRetry` resets to zero first and retries for tokens (e.g.
     *      USDT) that forbid overwriting a non-zero allowance. Native token needs no allowance.
     */
    function _approve_max_to_bond_route( IERC20 token ) internal
    {
        if(  address(token) == address(NATIVE_TOKEN)  )  return;

        address(token).safeApproveWithRetry( BONDROUTE_ADDRESS, INFINITE_TOKEN_AMOUNT );
    }
}


/**
 * @notice Minimal local view of the canonical BondRoute singleton — only the call this delegate makes.
 */
interface IBondRouteSingleton {
    function execute_bond_as( ExecutionData calldata execution_data, address user, bytes calldata signature, bool is_eip1271 ) external payable returns ( uint8 status, bytes memory output );
}
