// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title RelayerTestManifest
 * @notice Test interface registry for the EIP-7702 Relayer delegate.
 * @dev Future test contracts in test/Relayer should implement the relevant interface below.
 */


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// RELAYER.SOL - BondRoute approval dance (zero->infinite, idempotent, USDT reset-first) and native-token skip.
// Implemented in: test/Relayer/Relayer.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IRelayerTests {
    // ─── BondRoute Approval Dance ───────────────────────────────────────────────
    // Before calling execute_bond_as, the delegate approves each funding token to BondRoute via Solady's
    // safeApproveWithRetry (auto reset-to-zero for USDT-style tokens), and skips the native token.
    function test_approve_sets_infinite_allowance_from_zero() external;
    function test_approve_is_idempotent_when_allowance_already_infinite() external;
    function test_approve_resets_to_zero_first_for_tokens_that_forbid_overwrite() external;
    function test_approve_skips_native_token() external;

    // ─── Native Receive ─────────────────────────────────────────────────────────
    // The delegate must accept native value sent to the user's EOA (empty-calldata transfer), or a gasless op that
    // releases native mid-execution (native-output swap, remove/collect payout, stake/refund return) would revert.
    function test_delegate_accepts_native_value() external;

    // NOTE: the execute-path funding pull (native/ERC20) needs a real protocol that consumes fundings plus a signed
    //       execution, so it is covered through the SafeSwap real-env integration in a follow-up, not here. The relayer
    //       fronts and creates the bond from its own inventory, so there is no create entrypoint on the delegate to test.
}
