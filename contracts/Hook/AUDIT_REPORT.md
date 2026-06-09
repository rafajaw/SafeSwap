# SafeSwapHookImpl — Security Audit (focused pass)

Date: 2026-06-09 · Tools: Slither 0.11.5 + manual review · Focus: reentrancy, access control, griefing / bricking.

Scope: `contracts/Hook/SafeSwapHookImpl.sol` (`ISafeSwapHook.sol` interface). The hook is a single immutable implementation;
every pool's hook is an EIP-1167 clone whose CREATE2 address encodes `(base fee, capture)` and the V4 permission bits.

## Verdict

**No Critical / High / Medium findings.** Access control is strong and explicit; the swap-pricing callbacks are `view`
(no reentrancy surface); permissionless deployment is constrained to the canonical clone only.

## Access control — strong

| Entry point | Guard |
| --- | --- |
| `beforeSwap` | `_require_swap_action`: `msg.sender == PoolManager` **and** `sender == SafeSwapRouter`. |
| `beforeInitialize` / `beforeAddLiquidity` / `beforeRemoveLiquidity` | `_require_position_action`: `msg.sender == PoolManager` **and** `sender == SafeSwapNft`. |
| every callback + `get_config` / `initialize_once` | `_require_clone_context`: reverts a direct call on the implementation (`address(this) == IMPLEMENTATION_SELF`). |
| `deploy_hook` | permissionless by design, but constrained (below). |

`IMPLEMENTATION_SELF` is captured at the implementation's own deploy, so under a clone's `delegatecall` it differs from
`address(this)`; equality only holds on a direct implementation call, which is rejected. Authorization is by hard address
equality, never `tx.origin` or interface self-identification.

## Reentrancy — none

`beforeSwap` and the liquidity callbacks are `view` and hold no funds (the hook never custodies value). `beforeSwap` calls
`SwapSimulator.simulate` (a `view` read of the same storage the swap will touch) and returns a dynamic-fee override; there is
no external state-mutating call and no value transfer, so there is no reentrancy surface.

## Griefing / bricking — none found

- **`deploy_hook` is canonical-only.** It pre-computes the address with `Clones.predictDeterministicAddress` and, *before*
  cloning, validates occupancy (`ALREADY_EXISTS`), that the address decodes to the requested config (`CONFIG_MISMATCH`), and
  that it carries the required V4 permission bits (`PERMISSIONS`). The deployed code is the canonical EIP-1167 stub, and
  `initialize_once` → `register_hook` re-validates the runtime **codehash** at the router. An attacker cannot place
  non-canonical hook code at a config address.
- **Front-running `deploy_hook` is harmless.** All valid clones for a given config are behaviorally identical (config is
  decoded from the address top-bytes; the mined middle-bits don't affect logic), so it does not matter who deploys first.
- **A reverting `beforeSwap` only fails the caller's own swap** (the simulation is bounded and reads pool state); it cannot
  brick the pool for others, and the fee is capped at the V4 limit (`RepricingFeeExceedsV4Limit` upstream).

## Slither

Only one hook finding, a **false positive**:
- `unused-return` on `Clones.cloneDeterministic(IMPLEMENTATION_SELF, salt)` (`deploy_hook`). The deployed address is the
  pre-computed, already-validated `new_hook`; the return value is redundant with it. No action.

## Recommendations

None required. (Optional nicety: none — the `deploy_hook` validate-then-clone ordering is already the correct, safe shape.)
