// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title RelayerTestManifest
 * @notice Test interface registry for the EIP-7702 gasless `SafeSwap7702Delegate`.
 * @dev Future test contracts in test/Relayer should implement the relevant interface below.
 */


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// SAFESWAP7702DELEGATE.SOL - the two-phase gasless delegate: a relayer-sponsored create_bond_from_user_stake +
// execute_bond_from_user, authorized by one off-chain SafeSwapGaslessBond signature, driven as the user's 7702-delegated
// EOA against the real SafeSwap router / NFT / pools and BondRoute singleton (router + NFT resolved from ChainConfig).
// Implemented in: test/Relayer/Relayer.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IRelayerTests {
    // ─── Happy path (real env) ────────────────────────────────────────────────────
    function test_gasless_create_and_execute_pays_user_and_relayer() external;

    // ─── Relayer fee accounting ───────────────────────────────────────────────────
    // The on-chain fee is paid from the user's EOA exactly once at commit, and not at all if the commit reverts (atomic).
    function test_relayer_fee_paid_once_after_create() external;
    function test_relayer_fee_not_paid_when_create_reverts() external;
    function test_native_relayer_fee_paid() external;

    // ─── Native stake / funding ───────────────────────────────────────────────────
    // Native stake and native inbound funding are paid from the delegated EOA's own balance via { value: ... }.
    function test_native_stake_from_eoa_balance() external;
    function test_native_funding_execute_works() external;

    // ─── Context guards ───────────────────────────────────────────────────────────
    // The entrypoints run only as a 7702-delegated EOA (never directly on the deployed artifact), and the relayer attaches
    // no native value.
    function test_create_reverts_on_direct_call() external;
    function test_execute_reverts_on_direct_call() external;
    function test_create_reverts_on_native_value() external;
    function test_execute_reverts_on_native_value() external;

    // ─── Authorization guards ─────────────────────────────────────────────────────
    // The intent pins the delegate (helper) and the submitting relayer, is recovered via ECDSA against the EOA, and the
    // commit honours the signed deadline.
    function test_reverts_on_wrong_helper() external;
    function test_reverts_on_unauthorized_relayer() external;
    function test_reverts_on_invalid_signature() external;
    function test_create_reverts_after_deadline() external;

    // ─── Execution-data binding ───────────────────────────────────────────────────
    // At execute the revealed ExecutionData must target an allowlisted protocol and reproduce the signed commitment, stake,
    // gasless type hash, and action struct hash.
    function test_execute_reverts_on_unsupported_protocol() external;
    function test_execute_reverts_on_commitment_mismatch() external;
    function test_execute_reverts_on_stake_mismatch() external;
    function test_execute_reverts_on_gasless_type_hash_mismatch() external;
    function test_execute_reverts_on_action_struct_hash_mismatch() external;

    // ─── Type-string splice ───────────────────────────────────────────────────────
    // The signed type re-parents the protocol action tail under the SafeSwapGaslessBond prefix; a non-prefixed or malformed
    // leading definition (e.g. a tampered TokenAmount) is rejected.
    function test_splice_builds_expected_gasless_type_hash() external;
    function test_splice_reverts_on_bad_prefix() external;
    function test_splice_reverts_on_malformed_token_amount() external;
}
