# SafeSwap Frontend — Spec Decisions

Running log of decisions made while dialing in `safeswap_frontend_handoff.md`, screen by screen, before
wiring. Where this conflicts with the handoff, **this doc wins** (the handoff is the starting draft; these are
the agreed corrections). Each screen is locked as we walk through it.

---

## Brand & design system

**Core rule: the NFT card is the only fully-saturated surface; the app chrome is its desaturated grey twin.** The app shares
the card's fonts, green accent, opacity ramp, and shape grammar (unified family), but its background is desaturated to
neutral greys so the colorful NFT visibly **pops** when embedded in Portfolio (instead of melting into a same-palette page).
Tokens are lifted from the locked NFT render (`nft-renders/reference9.svg` / `reference10.svg`):

```text
App background   gradient #1b1f24 → #0f1115 → #1c1a17   (desaturated echo of the card's teal/navy/warm diagonal)
Surfaces/cards   #161a1f · hairline border #fff@8% · rx 16–20
Rules / bands    #fff@10% / #fff@5%   (matches card)
Accent (green)   #37d6a3  ← the ONLY saturated color in the app; dim variant #37d6a3@60%
Text             #fff at 100 / 90 / 60 / 50 / 40%   (matches card ramp)
Amber (low-conf) #e0b54a  — estimate/assumption warnings only, sparing
Red              loss / failed constraint / destructive only
Fonts            Inter (UI) · Roboto Mono (numbers, addresses, amounts)
Type             values 700 · small uppercase labels 600 + letter-spacing .4
Shapes           cards rx 16–20 · fully-rounded pills · translucent-black pills (#000@14%)
Wordmark/logo    "Safe" (#fff@90%) + "Swap" (#37d6a3), Inter 700 — the half-white/half-green identity (text wordmark)
NFT in-app       give the card padding + a faint #fff@8% frame so it reads as a distinct collectible
```

DECIDED: app background = **desaturated diagonal gradient** (family resemblance to the card) over a flat neutral; this is a
first pass — test and adjust later. Rationale for the whole approach: green stays meaningful as the single accent, the
NFT remains the visual hero, and the muted chrome keeps financial information legible (handoff §14 restraint).

## Data-fetching & app architecture (Phase 1: wallet-provider reads + Deno relay)

DECIDED: **no read RPC, no API key.** All chain reads come from the **connected wallet's** provider
(`transport: custom(provider)` — what `frontend/src/wallet.ts` already does). Every meaningful screen is chain-dependent, so
**wallet connection is the entry gate**:

- **On `.html` load → immediately show a "Connecting wallet…" modal and fire the connect prompt** (`eth_requestAccounts`).
  Everything downstream (quotes, pool cards, positions, balances) bootstraps from the connected wallet. No
  read-before-connect; only static brand/marketing exists pre-connect. No-wallet / rejected → connect/install state, never a
  fake-data screen.
- Reads (quotes, `slot0`, `tokenURI`, `HookRegistered` logs, `Transfer` enumeration) run through the wallet RPC. Watch-item:
  some wallet RPCs cap `eth_getLogs` block ranges → query bounded ranges for discovery.
- `walletClient` over `custom(window.ethereum)` for signing/sending.

**Backend = a single Deno server** that (1) **serves the `.html`** and (2) exposes **`POST /relay`** — the gasless relayer.
The funded relayer key lives **server-side only**. Demo runs the relayer on **one chain: Unichain.**

### Gasless execution via EIP-7702 (confirmed live on Unichain)

The user sends **zero on-chain txns — including first-touch token approval** — by sponsoring everything through the relayer.
The user signs only, **off-chain**: the `ExecuteBondAs` envelope **and** a **7702 authorization** delegating their **EOA** to
an immutable SafeSwap **execution helper**. The user pays the relayer **off-chain, up front** — a trust relation, but because
the relayer is prepaid and controls execution it **cannot be on-chain-griefed** (reverts, allowance revocation, etc.); the
relayer never seeks on-chain profit, so all on-chain value flows to the user.

Flow:
1. User signs `ExecuteBondAs` + the 7702 authorization (EOA → helper); client
   `POST /relay { chain_id, execution_data, user, signature, is_eip1271, authorization }`.
2. Relayer **validates before spending anything**: (a) valid signature; (b) valid/well-formed execution matching the signed
   digest; (c) targets the canonical **BondRoute**; (d) **no native fundings**; (e) protocol is the **SafeSwap Router or NFT**
   (no arbitrary protocols relayed); (f) estimated total gas of both txns **< $1 USD** (named threshold const).
3. **Commit:** the bond is created (`create_bond`). *(Stake sourcing is the open item below.)*
4. Wait the execution delay. If the EOA lacks funding-token **balance**, the relayer **transfers the missing token(s) to the
   EOA in a single tx** beforehand (balance only — allowance is handled in step 5 by the helper).
5. **Execute:** relayer submits the **7702 type-0x04 tx** → the EOA (running helper code) **approves the funding tokens to
   BondRoute**, then calls **`execute_bond_as(execution_data, user, signature, is_eip1271)`**. `transferFrom(user=EOA)` now
   succeeds; **stake, refunds, and protocol output all flow to the `user`**. Relayer pays all gas.

**Why `execute_bond_as`, never `execute_bond` (intentional):** even though the 7702-delegated EOA *could* self-execute, we
route through `execute_bond_as` so execution stays **gated on the user's explicit `ExecuteBondAs` signature**
(authorization-for-execution) — not merely on the 7702 delegation.

**The 7702 delegate contract — the one new immutable artifact (audit-grade, minimal).** `BondRoute` is **deployed immutable;
nothing is added to it.** This separate contract is the EOA's 7702 delegation target, so its code runs *as the user's EOA*.
It exposes **only one entrypoint** and **no** arbitrary call surface:

- **`approve_fundings_and_execute_bond_as_user`** — approve the funding tokens → `BondRoute.execute_bond_as(...)`. BondRoute
  itself verifies the user's signature here, so nobody can *execute* on the user's behalf without their signed message.

Plus a bare **`receive()`** (no payable `fallback()`). A gasless op can *release* native back to the user's EOA mid-execution
— a native-output swap, a remove/collect that pays out ETH, or a stake/refund return at settlement — arriving as an
empty-calldata value transfer; without `receive()` that payout (and the whole `execute_bond_as`) reverts, and the delegated
account would also bounce ordinary ETH while the 7702 delegation persists. The native-funding *rule* only blocks native
*inbound* funding (the relayer can't attach the user's value), so it doesn't cover released/outbound native — hence `receive()`.

**No create entrypoint on the delegate (resolved security decision).** The relayer fronts and creates the bond itself from
inventory (a normal `create_bond` from the relayer's own key — see *Stake sourcing* below), so the delegate **never stakes
the user's funds**. We deliberately do **not** add an `approve_stake_and_create_bond_as_user` that stakes the user's own
tokens from opaque commitment data: it could not be safely gated by the reused `execute_bond_as` signature. That signature
binds `fundings`/`call` through their **EIP-712 hashes** (`hash_fundings_for_eip712`, the protocol struct hash), while the
BondRoute **commitment** binds them through *different* (plain) hashes (`hash_fundings`, `keccak(call)`). At commit time, with
only hashes on hand, those two pairs are **independent calldata** and nothing on-chain proves they share the same `fundings`/
`call` preimage — so the signature leaves the commitment's hashes **unsigned**. A griefer (anyone, while the EOA stays
delegated) could pair the user's real EIP-712 hashes (signature passes) with garbage commitment hashes and lock the user's
stake into a fresh, **unexecutable** bond that gets liquidated → user loss. (This is a *delegate* invariant, not a BondRoute
bug: BondRoute's own `create_bond` is self-funded — you stake your own tokens — and `execute_bond_as` always has the full
`ExecutionData`, so its two hash pairs are derived from one source and can't desync.) Fronting the stake from relayer
inventory removes the user-fund griefing surface entirely.

Implemented at **`contracts/Relayer/Relayer.sol`**, verified by **`test/Relayer/Relayer.t.sol`**: the BondRoute approval uses
Solady `safeApproveWithRetry` (auto reset-to-zero) and is covered (zero→infinite, idempotent, USDT reset-first, native-skip).
Deferred to the SafeSwap real-env integration: the execute-path funding pull (native/ERC20) — needs a real protocol that
consumes fundings plus a signed execution.

Shared approval loop (handles non-standard tokens like USDT that require resetting to zero before a new allowance):

```solidity
uint256 constant INFINITE_TOKEN_AMOUNT = type(uint256).max;   // named const, not raw type(uint256).max

// for each funding token (execute) or the stake token (create):
uint256 allowance = token.allowance(address(this) /* = EOA */, BONDROUTE);
if (allowance > 0 && allowance < INFINITE_TOKEN_AMOUNT) {
    token.approve(BONDROUTE, 0);                  // some tokens require resetting first (USDT-style)
}
if (allowance < INFINITE_TOKEN_AMOUNT) {
    token.approve(BONDROUTE, INFINITE_TOKEN_AMOUNT);
}
```

Infinite approval is to **BondRoute only** (the trusted canonical contract), so the one-time dance means future actions need
no re-approval; the delegate never approves any other spender. The entrypoint is invoked by a relayer-sponsored 7702
type-0x04 tx; the user only signs (the 7702 authorization + the `ExecuteBondAs` envelope).

**Caveats:** 7702 is **confirmed live on Unichain**; the connected wallet must support signing 7702 authorizations; the 7702
delegation **persists** on the EOA until re-delegated/cleared (acceptable given the helper's minimal scope; can be cleared in
the same flow). **Fallback** when a wallet/chain lacks 7702: one-time user `approve(BondRoute)` then relayer-executed
`execute_bond_as` (or self-execute).

### Stake sourcing for the commit (`create_bond`)

**The relayer fronts a small stake from inventory** (a normal `create_bond` from the relayer's own key). Sized to the
normalized ~1–2% of committed value (+~2% drift margin so the post-delay execute can't revert), **never the full amount** —
the fronted stake is at liquidation risk if a bond ever expired unexecuted, so keep the relayer's exposure tiny. Stake is
refunded to the `user` at settlement (the relayer is already made whole off-chain). No contract change, and the user's funds
are never staked — so there is no user-fund griefing surface at commit (see *No create entrypoint* above for why a
user-staking `create` delegate was rejected).

**Rejected:** a user-staking `approve_stake_and_create_bond_as_user` delegate for the case where the stake token is one only
the user holds (an exotic token the relayer can't front). Staking the user's own tokens from opaque commitment data can't be
safely gated by the reused `execute_bond_as` signature (the signature binds fundings/call via EIP-712 hashes; the commitment
binds them via different plain hashes; the two are independent calldata at commit, so the commitment stays unsigned and a
griefer can lock the user's stake into an unexecutable bond). If an exotic-stake path is ever needed, it must gate on a
dedicated commit-authorization signature **over the commitment hash itself**, not the execute signature.

The relayer key is the system's only secret and is server-side by design. Phase-2 indexing/caching is separate, not part of `/relay`.

## Terminology: "Repricing rebate", not "Capture"

The profile's surplus-share dimension (`rebate_percent` in code, encoded as `C00`…`C90`) is labeled **"Repricing rebate"**
in the UI — the % of a swap's estimated repricing surplus paid back to LPs — with an **info icon / hover** explaining it.
"Capture" / "C50" is misleading and is demoted to a compact secondary technical tag only. From the **trader** side the
matching quote line is **"Repricing fee"** (same mechanism, LP-benefit vs trader-cost framing; handoff §15). Underlying
on-chain naming (`rebate_percent`, NFT attribute "LP Rebate") is unchanged.

## SDK: profile discovery via `HookRegistered` events

There are only a few deployed `(base_fee_bps, rebate_percent)` profiles. The SDK enumerates them by reading the router's
`HookRegistered(address indexed hook, uint16 indexed base_fee_bps, uint8 indexed rebate_percent)` logs (all three indexed →
cheap to query/filter) and returns `{ hook, base_fee_bps, rebate_percent }[]`. This powers the Create screen's
profile selector (show **only deployed** profiles; no dead options) and the profile half of Earn discovery — **no indexer
required** for profiles. (Token *pairs* still come from a curated token list crossed with these profiles, probing
PoolManager `slot0` for initialized pools.)

## Cross-cutting

### Two execution modes per protected op
Every BondRoute-protected operation (swap, create position, add liquidity, remove liquidity) runs in one of two modes:

- **Gasless (default)** — user signs an `ExecuteBondAs` envelope **+ a 7702 authorization**; the **relayer** sponsors the
  whole lifecycle and the user sends **zero on-chain txns** (including approval). See "Gasless execution via EIP-7702" below.
- **Self-execute (fallback)** — user sends the bond txns themselves (`create_bond` + `execute_bond`) and pays the gas;
  used when a wallet/chain lacks 7702, or when forced by the native-funding rule.

This **corrects handoff §5**, which wrongly states there is no Direct/Relayer mode. The SDK already exposes both
(`op.dispatch()` self-drives; `op.sign_verified_execution()` + a relayer `execute_as` is gasless). **Collect fees** is
single-mode — a plain direct call, no bond, no mode choice. Gasless is **native day 0**; a relayer backend is assumed
present. If a chain has no relayer configured, Gasless is unavailable (disabled, same treatment as the native rule).

### Lifecycle facts
- **Gasless (7702):** user sends **zero on-chain txns** — signs the `ExecuteBondAs` envelope + a 7702 authorization
  (off-chain) and pays the relayer off-chain. The relayer sponsors commit + execute and the helper sets the funding
  allowance in-flight. (Stake sourcing for the commit is the open item in the architecture section.)
- **Self-execute (fallback):** user sends `create_bond` (posts the user's own stake, refunded to the user) + the post-delay
  `execute_bond`, plus any one-time `approve(BondRoute)`.

### Native-funding rule
If any **inbound funding** is the native token, **disable Gasless and force Self-execute** — a relayer cannot attach the
user's native value to `execute_bond_as`. Applies to native-input swaps and create/add where a deposit leg is native.
Remove and collect take no fundings, so they are unaffected. Disabled-radio hover copy: `Native swap not supported via relayer`.

---

## Screen 1 — Swap

- Green **"Estimated value protected"** rendered in **input-token terms** (no USD day 1; USD is an optional overlay once a
  price source exists). Always starred as a modeled estimate.
- **Capture profile (e.g. C50) removed from the route line** — capture% is a *cost* to the trader (higher repricing fee),
  not a perk, so badging it there is misleading. It lives inside **Quote details**, framed as a fee driver.
- **Execution mode toggle** (Gasless default / Self-execute) on the card; native-funding rule disables Gasless.
- **Quote details** (collapsed): Minimum received · Price impact · Base LP fee · Estimated repricing fee · Protocol fee ·
  Network cost · Estimated total cost. Split: `repricing_fee_pips = total_fee_pips - base_fee_pips`
  (quoter returns `total_fee_pips`; `base_fee_pips = base_fee_bps × 100`).

## Screen 2 — Swap progress

- **No in-app Review step.** In gasless, the wallet's typed-data signing screen **is** the review — the REFERENCE_2 fields
  are named for exactly that. The page shows **"Pending signature"** and opens the wallet automatically.
- Rail (gasless/7702): **Sign → In progress → Done** — user signs the `ExecuteBondAs` envelope + 7702 authorization (no
  user commit tx), then the relayer sponsors the whole lifecycle. Self-execute fallback rail: **Commit → Active → Execute →
  Done.** Status copy is **"in progress / pending"**, never "close this page"; it is safe to leave and return.
- **Resume on reopen:** the SDK surfaces the active pending bond (`on_pending_bond`), so reopening the app lands the user
  back on this progress page at the correct sub-state (aligns handoff §17 persistence requirement).
- **Self-execute fallback summary (TEMPORARY):** because self-execute fires plain `create_bond`/`execute_bond` txns and the
  wallet renders **raw transaction data** (no readable fields), show a compact in-app human summary (Pay / Receive ≥ min /
  est. value protected) before firing the txns. **This is a stopgap only while wallets lack clear signing for these plain
  txns** (Ledger clear signing / ERC-7730 / EIP-712 structured display). Once clear signing renders them in-wallet, remove
  the in-app summary. Gasless never needs it.
- **Completion receipt** is shared by both modes: Received · Estimated value retained* · Total SafeSwap cost · Execution
  status (Protected) · [View transaction] [Swap again].

## Position card = the on-chain NFT (`tokenURI`)

The LP position card's visual identity and text fields come **from the `SafeSwapPositionDescriptor` `tokenURI`** — do not
fabricate position metrics. The descriptor computes, fully on-chain per position:
- **Identity:** Pair, Chain Id, NFT Contract, Token Id, Tick Spacing, Hook, Pool Id
- **Position:** Base Fee %, LP Rebate %, Tick Lower/Upper, Opened At, Liquidity, Current Position (`amount0 / amount1`)
- **Fees:** Claimable Fees, Lifetime Fees (one combined figure per token — **no base/repricing split**, matches handoff §9)
- **Yield:** Fee Yield (current basis) + **Annualized Fee Yield Estimate** (lifetime earned ÷ current value, scaled to a
  year; a **per-position estimate, not a pool-wide APR**)
- **Status:** In Range / Out of Range / Uninitialized
- The **SVG card image** itself (render it as the position's visual identity).

There is **no** on-chain pool-level TVL / pool APR / 30d-revenue — those are indexer-only (handoff §13). The earlier
"projected APR" pool-card fields were fabricated and are dropped.

## Position lifecycle & screen order

`create_position` **mints a new NFT** (no ownership precondition). `add` / `remove` / `collect` operate only on a `token_id`
the caller **owns or is approved for** (`_require_lp_position_authority`: `owner || getApproved || isApprovedForAll`) — you
cannot modify another LP's position. This is the standard Uniswap NFT-periphery model (separate NFT per LP per pool+range).
So **Create is modeled first**; add/remove/collect are secondary actions reached from a held position in Portfolio.

**Launch-pool and create-in-existing-pool are one call.** `create_position`'s `sqrt_price_x96` *initializes* the pool if it
doesn't exist; for an **existing** pool it is **display-only — the contract does not enforce equality** with the live price.
This is deliberate: under BondRoute's commit→execute delay the pool price can drift, so a strict equality would revert a Create
that the user's deposit bounds would still satisfy. The economic guard for an existing pool is the signed **Deposit /
`Minimum deposited` band** (`SlippageExceeded` below the minimum, funded `Maximum to deposit` as the cap) — not the price. One
Create flow; the Price field is editable for a new pool and shown live but advisory for an existing one. Frontend therefore
does **not** need a "re-sign after price moved" path for existing-pool Create — benign drift is tolerated; only drift past the
deposit band reverts (and that surfaces as the normal minimum/maximum-bound error).

Screen order: 1 Swap · 2 Swap progress · 3 Earn list · **4 Create position** · 5 Add liquidity · 6 Remove/Collect ·
7 Portfolio + Position detail.

### Human↔raw conversions already exist on-chain (`SigningLib`)
The Create/Add previews mirror the **signed receipt** fields using existing functions (and the wallet signing is the review):
`render_range_value` → **Range**, `render_price_value` → **Price**, `calculate_amounts_for_liquidity(price,lower,upper,liq)`
→ **Deposit**, `render_burn_value` → remove amount. These go *liquidity → display*. The only client-side piece is the
inverse a UI needs when the user types **amounts** (`amounts → liquidity` = stock Uniswap `getLiquidityForAmounts`); the
signed `liquidity` is already a caller-supplied input. Raw `Liquidity` integer stays in the wallet/Advanced, never a primary input.

## The minimum bound is the product — set it directly, no slippage lingo

The signed protective bound (`minimum_received` on swaps/remove, `maximum to pay` on exact-output, `maximum_deposit` /
`minimum_deposit_a/b` on create/add) is set **directly and explicitly by the user**, labeled by what it is
(**"Minimum received"**, **"Maximum to pay"**, **"Minimum deposited"**) — **never** the word "slippage", and never a raw
internal field the user can't reason about. Below the bound, the action reverts. Whatever the user sets **is** the
signed/enforced value.

**This is a core product statement, displayed succinctly and clearly on-screen (not a hover tooltip):** on an ordinary DEX
your slippage tolerance *is* the MEV extraction surface — sandwich bots take exactly up to it, so you must keep it tight. Under
BondRoute there is no sandwiching, so a **generous minimum is safe** — the gap between quote and minimum is not a target anyone
can extract. Lead with that. Example copy:

```text
Minimum received   2,805 USDC   [edit]
You'll get at least this or the swap reverts.
Protected execution means no bots can take the gap — set it as safe as you like.
```

(The earlier "slippage-derived default" model is replaced by this direct-and-explicit model.)

**Pinned default pre-fill:** the bound is pre-filled (not blank) at **quote × (1 ∓ 1.0%)** and is editable — `Minimum
received` = quote − 1.0%, `Maximum to pay` / `Maximum to deposit` = quote + 1.0%, `Minimum deposited` = quote − 1.0%. The
default leans **generous on purpose**: under BondRoute a loose floor cannot be extracted, costs nothing when price doesn't
drift, and minimizes post-delay reverts. Phase-2 refinement: scale the default by pair volatility class and/or the bond's
`min_execution_delay_in_blocks` (longer delay → more drift room). Applied symmetrically across swap/create/add/remove.

## Screen 4 — Create position (Launch-pool + create-in-existing, one call)

Inputs: Pair · Profile (Base fee + Repricing rebate, **selectors offer only deployed profiles** from `HookRegistered`) ·
Range (presets + custom) · Price (editable for a new pool; live but advisory for an existing one — the deposit band is the guard) · Deposit (type one amount,
derive the other from range+price) · `Maximum to deposit` + `Minimum deposited` (direct, per the minimum-bound model) ·
Execution mode (native rule). Preview rows = the signed receipt (`Deposit · Minimum · Liquidity · Range · Price · Pool`);
raw `Liquidity` stays in the wallet/Advanced. A deep-link to an unregistered profile shows handoff §11's "not deployed"
message and disables Create. No projected-earnings block in Phase 1 (no truthful projection without an indexer).

## Screen 5 — Add liquidity (increase on an owned position)

Reached from Portfolio → position → Add. Range and profile are fixed by the position (read-only). Inputs: Add deposit
(type one, derive other at live price within the fixed range; if out of range, only the single active token) ·
`Maximum to deposit` + `Minimum deposited` · Execution mode (native rule). Signed receipt = `Position · Deposit · Minimum ·
Liquidity · Pool` (no Range/Price). Reuses Screen 2's progress machine.

## Screen 6 — Remove / Collect (two different things)

**Remove** is BondRoute-protected: Amount-to-remove presets + custom · `Minimum received` for both tokens (direct, with the
core no-bots statement) · Execution mode. **Remove takes no inbound funding** (tokens flow out), so the native rule does not
fire — **Gasless is available even when ETH is released.** Signed receipt built from `render_burn_value` + minimums.

**Collect** is a plain **direct call** — no bond, no stake/delay/signing, no protection language, no "value protected"
estimate (handoff §12; collection is realized, not MEV-sensitive). Single tx. Shows `Available to collect` (on-chain
`claimable0/1`) and an optional advanced `Minimum received`.

**Green = realized/collectible value here (both states).** The collectible amount is rendered in **green** both pre-collect
("Available to collect" — the hero CTA value) and on the receipt ("collected … sent to your wallet"), because it is real
on-chain earned value, not an estimate. It carries **no `*`, no `%`, no "vs ordinary execution"** — those markers stay
exclusive to the *estimated* green numbers elsewhere (swap value-protected, projections). Green means "value you keep / earn
/ can collect"; restraint rule applies (it's the single strongest green object on the screen).

## Screen 7 — Portfolio + Position detail (the NFT `tokenURI`)

Position cards/detail **are** the `tokenURI` (SVG art as identity; text fields from on-chain attributes). Show Current
Position, Lifetime fees (**one combined figure per token, no base/repricing split**), Claimable now, Annualized Fee Yield
Estimate (**per-position, starred — not a pool APR**), Base fee %, Repricing rebate %, Range, Status, and self-locating
attrs under "Verify on-chain". The "Modeled SafeSwap uplift" line from the handoff is **dropped** (no truthful split without
an indexer). `[Add] [Remove] [Collect]` route to Screens 5/6/6.

**Position discovery (Phase 1, no indexer):** SDK reads the NFT's ERC-721 `Transfer` logs filtered to the user and confirms
current `ownerOf` (same read-events approach as `HookRegistered`). **Activity center:** in-flight bonds persist across
refresh (`on_pending_bond` / serialize); **Resume** re-enters Screen 2's progress machine.

## Screen 3 — Earn (Explore pools): facts-only cards

Pool cards show **on-chain facts only** — no TVL/APR/30d revenue:
- Pair, Base Fee %, Capture profile (here it favors the LP, so showing e.g. `C50` is correct — opposite of the swap screen),
  Hook, Pool Id, and live price/tick from PoolManager `slot0`.
- **Data source:** there is no on-chain pool directory, so the *candidate pairs* come from a curated token list; each
  displayed field is then an on-chain fact (pool initialized? base fee, capture, hook, pool id, current price). No invented
  metrics. Real pool aggregates and the richer card wait for the indexer (Phase 2).
