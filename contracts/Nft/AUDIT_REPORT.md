# SafeSwapNft — Security Audit (focused pass)

Date: 2026-06-09 · Tools: Slither 0.11.5 + manual review · Focus: reentrancy, access control, griefing / bricking.

Scope: `contracts/Nft/` — `SafeSwapNft.sol`, `SafeSwapPositionDescriptor.sol`, and `libraries/{ModifyLiquidityLib,PriceLib,
StringHelperLib}.sol`. The NFT owns every V4 position (salt = tokenId); the user owns the NFT.

## Verdict

**No Critical / High / Medium findings.** One **Low/Informational** item (direct `collect_fees` reentrancy bounded by the
"V4-compatible assets only" policy). Access control is layered and correct.

## Access control — strong (layered)

| Entry point | Guard |
| --- | --- |
| `bonded_create_position` | `BondRoute_initialize()` — BondRoute-only; mints a fresh NFT to `context.user` (no ownership precondition, by design). |
| `bonded_add_liquidity` / `bonded_remove_liquidity` | `BondRoute_initialize()` **and** `_require_lp_position_authority(token_id, context.user)`. |
| `collect_fees` | direct (no bond — no MEV surface), but `_require_lp_position_authority(token_id, msg.sender)`. |
| `unlockCallback` | `msg.sender == PoolManager`, else `Unauthorized`. |
| `tokenURI` / `get_lp_position` / `get_lp_fee_totals` | `_requireOwned` / `view`. |

`_require_lp_position_authority` = `owner || getApproved || isApprovedForAll` (standard Uniswap NFT-periphery model), so **one
LP cannot modify another LP's position**. The bonded actions take their actor from `context.user` (the signed bond owner),
never `msg.sender`.

## Reentrancy

- **Bonded create/add/remove**: wrapped by BondRoute's reentrancy lock; `unlockCallback` is PoolManager-gated; the
  modify-liquidity → settle/take flow is the standard V4 unlock pattern.
- **`collect_fees` is NOT BondRoute-gated** (intentional — collection is realized, not MEV-sensitive). It is a single
  `unlock → modifyLiquidity(0) → take`. A malicious **rebasing/ERC-777-style token** could attempt reentrancy during `take`,
  but (a) the caller must already be authorized for the position, and (b) re-entering would operate on the caller's own
  position whose fees are already zeroed — so it self-limits to the caller's own funds. The protocol's launch policy is
  **V4-compatible assets only** (no callback tokens), which removes the vector. *Low / Informational; documented.*

## Griefing / bricking — none found

- `create_position` is permissionless (mints a new NFT, no precondition) — the standard separate-NFT-per-LP model; cannot
  grief existing positions.
- Native deposit legs and unused-native refunds flow to `context.user` via BondRouteProtected's native path (only the
  BondRoute singleton may move native into the protocol — `"BondRouteProtected: unknown native transfer"` otherwise).
- The pool is initialized by `bonded_create_position` at the signed price if absent; benign price drift on an existing pool is
  tolerated and bounded by the signed deposit band (no revert-bricking of legitimate creates).

## Slither (triaged)

| Detector | Where | Assessment |
| --- | --- | --- |
| `unused-return` | `PoolManager.unlock(...)` (create/add/remove/collect), `sort_token_amount_pair` partials, `getSlot0` partials, `PoolManager.initialize`, `build_nft_signing_info` forward, `DateTimeLib.timestampToDateTime` partial | Intentional — unlock result handled via the callback; named-return subsets; forwarded signing info. |
| `too-many-digits` | `PriceLib.Q96` constant | **False positive** — fixed-point constant. |

No reentrancy, access-control, arbitrary-send, uninitialized, or delegatecall findings.

## Recommendations

None required. Keep the **V4-compatible-assets-only** launch policy enforced (frontend/indexer rejection rules) so the
`collect_fees` token-reentrancy note stays moot.
