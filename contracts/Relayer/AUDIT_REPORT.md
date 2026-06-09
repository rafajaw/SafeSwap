# SafeSwap7702Delegate — Security Audit (focused pass)

Date: 2026-06-09 · Tools: Slither 0.11.5 + manual review · Focus: reentrancy, access control, griefing / bricking.

Scope: `contracts/Relayer/SafeSwap7702Delegate.sol` — the EIP-7702 delegate the user's EOA delegates to for gasless execution.
Its code runs **as the user's own EOA**: it stakes the user's tokens, pays the relayer its fee, and drives the bond through
BondRoute via the plain (msg.sender-owned) `create_bond` / `execute_bond`. Evidence: `test/Relayer/Relayer.t.sol` (22 real-env
tests — every guard below has a passing revert test).

## Verdict

**No Critical / High / Medium findings.** This contract was designed around the access-control and griefing surface and is
covered by a full revert suite. The serious open item is **operational, not a contract flaw**: the whole gasless flow is
**unverified on a live chain** (deploy pending), and the off-chain relayer's `PostgresStore` is written-but-untested.

## Access control — strong (defense in depth)

Both entrypoints (`create_bond_from_user_stake`, `execute_bond_from_user`) enforce, in order:

| Guard | Check | Revert |
| --- | --- | --- |
| No relayer value | `msg.value == 0` (native is paid from the EOA's own balance via `{value}`) | `UnexpectedNativeValue` |
| Delegated context | `address(this) != THIS_DELEGATE` (must run as the EOA, never on the deployed artifact) | `OnlyDelegatedExecution` |
| Helper pin | `intent.helper == THIS_DELEGATE` | `WrongHelper` |
| Relayer pin | `msg.sender == intent.relayer` | `UnauthorizedRelayer` |
| Signature | `ECDSA.recover(digest, sig) == address(this)` (the EOA) — **never EIP-1271** | `InvalidGaslessSignature` |
| Protocol allowlist | `execution_data.protocol ∈ {router, nft}` (resolved from ChainConfig) | `UnsupportedProtocol` |
| Deadline (commit) | `block.timestamp <= intent.create_deadline` | `CreateDeadlineExpired` |

`THIS_DELEGATE` / `SAFE_SWAP_ROUTER` / `SAFE_SWAP_NFT` are immutables (router/NFT from ChainConfig at deploy). EIP-1271 is
**structurally impossible** here: only an EOA can author a 7702 authorization, and an `isValidSignature` callback would re-enter
this delegate, which exposes no such function — so the scheme is hardcoded to ECDSA.

## Reentrancy — none

The delegate is a thin forwarder: it sets the EOA's BondRoute allowance (`safeApproveWithRetry`, infinite, **to BondRoute
only** — the one trusted singleton) and calls `BondRoute.create_bond` / `execute_bond`, which carry BondRoute's own reentrancy
lock. `receive()` accepts only empty-calldata native payouts (no payable `fallback()`, so no arbitrary call surface). The
delegate holds no persistent state and has no value-handling path an attacker can re-enter.

## Griefing / bricking — the central design concern, closed

- **User-staking create is safe** because it does **not** reuse BondRoute's `execute_bond_as` signature. The `SafeSwapGaslessBond`
  intent is signed over the **`commitment_hash` itself**; at execute, `_validate_execution_data_matches_intent` recomputes the
  commitment from the revealed `ExecutionData` (`__OFF_CHAIN__calc_commitment_hash`) and asserts equality, and re-derives the
  protocol's `gasless_type_hash` / `action_struct_hash` and checks them. So a relayer cannot pair a valid signature with a
  garbage commitment to lock the user's stake into an unexecutable bond — the surface that doomed the rejected design.
  (`CommitmentMismatch`, `StakeMismatch`, `GaslessTypeHashMismatch`, `ActionStructHashMismatch` — all tested.)
- **Type-string splice** (`_calculate_gasless_type_hash`) reuses only the protocol's action tail under the SafeSwap prefix and
  validates the exact BondRoute prefix (`InvalidProtocolTypedStringPrefix`); a malformed leading definition is rejected.
- **7702 persistence**: the delegation persists on the EOA until re-delegated/cleared — acceptable given the minimal,
  single-purpose code (approve-to-BondRoute + drive a signed bond) and no arbitrary call surface.

## Off-chain relayer (server) — relevant guards (not this contract, summarized)

`server/relayer.ts`: validates chain / helper / relayer / deadline / **signature** off-chain before spending gas; fail-closed
gas ceiling; a **global submit lock** (in-process mutex / postgres advisory lock) serializes the single relayer EOA's
commit+execute so nonces never collide across green/blue; reverted-receipt detection prevents phantom bonds.

## Slither (triaged)

| Detector | Where | Assessment |
| --- | --- | --- |
| `unused-return` | `execute_bond{value}(...)` in `execute_bond_from_user` | **False positive** — the `(status, output)` is `return`-forwarded. |
| `unused-return` | `BondRoute_get_signing_info(call)` third value (`TokenAmount_offset`) in `_get_protocol_signing_info` | Intentional — only `typed_string` + `struct_hash` are used. |

No reentrancy, access-control, arbitrary-send, delegatecall, or uninitialized findings.

## Recommendations

1. **On-chain verification before any real use** — the deploy/fork pass must exercise create → wait → execute against a live
   chain (the 22 tests are real-env but local).
2. **Verify `PostgresStore`** against a live DB during the docker pass (currently the memory store is the exercised path).
3. Keep the relayer EOA's submission strictly single-writer (the global submit lock) when running more than one app container.
