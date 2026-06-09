# SafeSwapRouter — Security Audit (focused pass)

Date: 2026-06-09 · Tools: Slither 0.11.5 + manual review · Focus: reentrancy, access control, griefing / bricking.

Scope: `contracts/Router/` — `SafeSwapRouter.sol`, `User.sol`, `Orchestrator.sol`, `BondRouteIntegration.sol`, `Treasury.sol`,
`HookRegistry.sol`, and `libraries/{ExactInputSwapLib,ExactOutputSwapLib}.sol`.

## Verdict

**No Critical / High / Medium findings.** One **Informational** item (Treasury withdrawal pattern, non-exploitable). Access
control on every state-changing path is explicit and correct.

## Access control — strong

| Entry point | Guard |
| --- | --- |
| `bonded_swap_exact_input` / `bonded_swap_exact_output` | `BondRoute_initialize()` — only the canonical BondRoute singleton (`0xb01d…`) can drive them; the trader identity is `context.user` from the bond, not `msg.sender`. |
| `unlockCallback` (Orchestrator) | `msg.sender == PoolManager`, else `Unauthorized`. |
| `register_hook` (HookRegistry) | caller's runtime **codehash** must equal the ChainConfig-published clone stub; address-bit config + V4 permissions re-validated. |
| `transfer_treasury` / `accept_treasury` / `withdraw_protocol_fees` | current-treasury (or pending-treasury) only. |
| `__OFF_CHAIN__*` views, `get_*` | `view`, no state. |

Sandwiching/MEV on swaps is structurally prevented by BondRoute's commit-reveal; the hook fee is the canonical profile's
`base + repricing` (capped by `RepricingFeeExceedsV4Limit`), so a swap cannot be over-charged beyond its registered config.

## Reentrancy

- **Swap path**: BondRoute holds a reentrancy lock around protected execution, and `unlockCallback` is PoolManager-gated; the
  V4 settle/take flow is the standard unlock pattern. No SafeSwap-side reentrancy surface.
- **`Treasury.withdraw_protocol_fees` (Slither: `reentrancy-balance` / `reentrancy-events`) — Informational, non-exploitable.**
  It is **treasury-only**, reads the balance fresh, and drains to **1 wei** (`withdraw_amount = balance - 1`). A reentrant
  call re-reads the now-`1`-wei balance and hits `balance <= 1 → return 0`, so no double-withdraw. There is no mutable
  accounting variable to corrupt (the "balance" is the live token/native balance). The trailing event and the `success ==
  false` check are cosmetic. *Optional hardening:* emit before the external call, or add a `nonReentrant` guard, purely for
  belt-and-suspenders; not required for correctness.

## Griefing / bricking — none found

- **`HookRegistry.register_hook` "first valid clone wins" is benign.** Only the canonical codehash, at an address decoding to
  the config with the right permissions, can register; all such clones are behaviorally identical, so the first registrant
  merely fixes which (identical) clone is canonical for that config. A different hook for the same config reverts
  (`HookConfigAlreadyRegistered`); re-registration by the same clone is idempotent.
- **Treasury keeps 1 wei per token** to avoid 0→non-0 writes — intentional, not a lock-up.
- Two-step treasury transfer (`transfer_treasury` → `accept_treasury`) prevents typo loss of the role.

## Slither (triaged)

| Detector | Where | Assessment |
| --- | --- | --- |
| `reentrancy-balance`, `reentrancy-events` | `Treasury.withdraw_protocol_fees` | Informational, non-exploitable (above). |
| `incorrect-equality` | `success == false` in Treasury | **False positive** — boolean comparison (house style avoids `!`), not a balance strict-equality. |
| `low-level-calls` | Treasury native send; `PoolManagerIntegration` staticcalls | Intentional (native transfer; PoolManager shape-validation). |
| `unused-return` | `PoolManager.unlock(...)`, `SwapSimulator.simulate` partials, `getSlot0` partials, `calculate_protocol_fee` in `__OFF_CHAIN__` quotes, `build_router_signing_info` forward | Intentional — named-return subsets / `view` quoting helpers / forwarded signing info. |

## Recommendations

None required. Optional: the Treasury belt-and-suspenders note above.
