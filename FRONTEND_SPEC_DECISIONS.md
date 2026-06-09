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
The user signs only, **off-chain**: one **`SafeSwapGaslessBond`** intent **and** a **7702 authorization** delegating their
**EOA** to an immutable SafeSwap **delegate**. The user stakes and funds the bond from their **own EOA balance** and pays the
relayer an **on-chain `relayer_fee`** at commit; the relayer fronts **only gas** and never holds or fronts the user's funds,
so all on-chain value flows to the user.

Flow:
1. User signs the `SafeSwapGaslessBond` intent + the 7702 authorization (EOA → delegate); client
   `POST /relay { chain_id, user, intent, gasless_type_hash, action_struct_hash, signature, execution_data, authorization }`.
2. Relayer **validates before spending any gas**: (a) right chain; (b) intent pins this relayer and its delegate (`helper`);
   (c) protocol is the **SafeSwap Router or NFT**; (d) commit deadline is in the future; (e) the `SafeSwapGaslessBond`
   signature recovers to `user`; (f) estimated total gas of both txns **< $1 USD** (fail-closed if no native price is set).
3. **Commit:** relayer submits a **7702 type-0x04 tx** → `create_bond_from_user_stake`, which pays the relayer its signed fee
   and calls `BondRoute.create_bond` staking the **user's own** tokens (the delegate sets the BondRoute allowance in-flight).
4. **Wait** the reveal delay.
5. **Execute:** relayer submits a second **7702 tx** → `execute_bond_from_user`, which approves the funding tokens to BondRoute
   and calls `BondRoute.execute_bond`. **Stake, refunds, and protocol output all flow to the `user`.** Relayer pays all gas.

**Why `create_bond` / `execute_bond` (msg.sender-owned), never `execute_bond_as`:** the delegate runs *as the user's EOA*, so
the EOA **is** the bond owner — the plain self-owned BondRoute path is correct, and authorization comes from the
`SafeSwapGaslessBond` signature the delegate verifies (see below), not from `execute_bond_as`.

**The 7702 delegate contract — the one new immutable artifact (audit-grade, minimal).** `BondRoute` is **deployed immutable;
nothing is added to it.** This separate contract (`contracts/Relayer/Relayer.sol`, ctor args `(safe_swap_router,
safe_swap_nft)`) is the EOA's 7702 delegation target, so its code runs *as the user's EOA*. It exposes **two entrypoints** and
**no** arbitrary call surface:

- **`create_bond_from_user_stake`** — pay the relayer its fee → `BondRoute.create_bond` with the user's own stake.
- **`execute_bond_from_user`** — approve funding tokens → `BondRoute.execute_bond`; re-derives and equality-checks the revealed
  `ExecutionData` against the signed intent before executing.

Plus a bare **`receive()`** (no payable `fallback()`) for native *released* back to the EOA mid-execution (native-output swap,
remove/collect payout, stake/refund return). Both entrypoints **forbid the relayer attaching native value** and require a
**delegated context** (revert if called directly on the deployed artifact). The signature is recovered via **ECDSA against the
EOA, never EIP-1271** — only an EOA can author a 7702 authorization, and an EIP-1271 callback would re-enter this delegate,
which exposes no `isValidSignature`.

**Commitment-bound create entrypoint (resolved security decision).** A *user-staking* create is safe here because it does
**not** reuse BondRoute's `execute_bond_as` signature. The `SafeSwapGaslessBond` intent is signed over the **`commitment_hash`
itself**; at execute, `execute_bond_from_user` recomputes the commitment from the revealed `ExecutionData` (via
`__OFF_CHAIN__calc_commitment_hash`) and asserts equality, and likewise re-derives the protocol's `gasless_type_hash` /
`action_struct_hash` and checks them. So the full execution is provably the signed commitment's preimage — closing the
griefing surface that *did* doom a delegate reusing the execute signature (that signature binds fundings/call via EIP-712
hashes while the commitment binds them via different plain hashes, leaving the commitment unsigned and a griefer free to lock
the user's stake into an unexecutable bond). The wallet still renders the human-readable action: the delegate strips
BondRoute's `ExecuteBondAs` prefix from the protocol's type string and re-parents the action tail under the
`SafeSwapGaslessBond` struct.

**The relayer is paid on-chain.** `intent.relayer_fee` is paid to the relayer inside `create_bond_from_user_stake` (from the
user's EOA balance), and the intent pins the submitting `relayer` so only it can drive the bond. No off-chain prepayment, no
relayer stake inventory, no funding top-up — the user is solvent for their own stake/fundings/fee.

Implemented at **`contracts/Relayer/Relayer.sol`**, verified end-to-end by **`test/Relayer/Relayer.t.sol`**: the delegate is
etched onto an EOA (7702 simulation) and driven `create → wait → execute` against the **real** router / NFT / pool / BondRoute
(fee paid, swap output to the user), with full revert coverage for every guard (delegated-context, native-value, helper,
relayer, signature, deadline, protocol allowlist, commitment / stake / type-hash / action-hash mismatch) and a direct
unit test of the type-string splice. The SDK reproduces the splice (`compute_gasless_type_hash`, unit-tested in
`sdk/test/safeswap.test.ts`) and signs the `SafeSwapGaslessBond` typed data; the relayer is in `server/relayer.ts`.

**Caveats:** 7702 is **confirmed live on Unichain**; the connected wallet must support signing 7702 authorizations; the 7702
delegation **persists** on the EOA until re-delegated/cleared (acceptable given the delegate's minimal scope; can be cleared
in the same flow). **Fallback** when a wallet/chain lacks 7702: self-execute (`create_bond` + `execute_bond` from the user).

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

- **Gasless (default)** — user signs one `SafeSwapGaslessBond` intent **+ a 7702 authorization**; the **relayer** sponsors the
  commit + execute gas and the user sends **zero on-chain txns** (including approval). See "Gasless execution via EIP-7702" below.
- **Self-execute (fallback)** — user sends the bond txns themselves (`create_bond` + `execute_bond`) and pays the gas;
  used when a wallet/chain lacks 7702.

This **corrects handoff §5**, which wrongly states there is no Direct/Relayer mode. The SDK exposes both
(`op.dispatch()` self-drives; `safeswap.gasless.relay(op)` is gasless). **Collect fees** is single-mode — a plain direct call,
no bond, no mode choice. Gasless is **native day 0**; a relayer backend is assumed present. If a chain has no relayer
configured, Gasless is unavailable (disabled).

### Lifecycle facts
- **Gasless (7702):** user sends **zero on-chain txns** — signs the `SafeSwapGaslessBond` intent + a 7702 authorization
  (off-chain). The relayer sponsors commit + execute as the user's EOA; the user stakes and funds from their own EOA balance
  and pays the relayer `relayer_fee` on-chain at commit, and the delegate sets the BondRoute allowance in-flight.
- **Self-execute (fallback):** user sends `create_bond` (posts the user's own stake, refunded to the user) + the post-delay
  `execute_bond`, plus any one-time `approve(BondRoute)`.

### Native funding (supported)
Native inbound funding **is** supported gaslessly: the delegate runs as the user's EOA, so it pays native stake/fundings from
the **EOA's own balance** via `{ value: ... }` (the relayer attaches no value — it only sponsors gas). The old "disable Gasless
on native funding" rule no longer applies; `safeswap.gasless.is_available` gates only on whether a relayer is configured.
Remove and collect take no inbound funding regardless.

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

- **No in-app Review step.** In gasless, the wallet's typed-data signing screen **is** the review — the `SafeSwapGaslessBond`
  intent re-parents the protocol action so the wallet renders the same readable fields. The page shows **"Pending signature"**
  and opens the wallet automatically.
- Rail (gasless/7702): **Sign → In progress → Done** — user signs the `SafeSwapGaslessBond` intent + 7702 authorization (no
  user commit tx), then the relayer sponsors commit + execute. Self-execute fallback rail: **Commit → Active → Execute →
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
Execution mode. Preview rows = the signed receipt (`Deposit · Minimum · Liquidity · Range · Price · Pool`);
raw `Liquidity` stays in the wallet/Advanced. A deep-link to an unregistered profile shows handoff §11's "not deployed"
message and disables Create. No projected-earnings block in Phase 1 (no truthful projection without an indexer).

## Screen 5 — Add liquidity (increase on an owned position)

Reached from Portfolio → position → Add. Range and profile are fixed by the position (read-only). Inputs: Add deposit
(type one, derive other at live price within the fixed range; if out of range, only the single active token) ·
`Maximum to deposit` + `Minimum deposited` · Execution mode. Signed receipt = `Position · Deposit · Minimum ·
Liquidity · Pool` (no Range/Price). Reuses Screen 2's progress machine.

## Screen 6 — Remove / Collect (two different things)

**Remove** is BondRoute-protected: Amount-to-remove presets + custom · `Minimum received` for both tokens (direct, with the
core no-bots statement) · Execution mode. **Remove takes no inbound funding** (tokens flow out) — **Gasless is available even
when ETH is released** (the delegate's `receive()` accepts the payout). Signed receipt built from `render_burn_value` + minimums.

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
