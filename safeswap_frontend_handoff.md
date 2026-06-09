# SafeSwap Frontend Product Handoff

> **Read this with `FRONTEND_SPEC_DECISIONS.md`.** This document is the base product/build spec (screens, flow, §1–§17).
> `FRONTEND_SPEC_DECISIONS.md` is the locked refinement layer keyed to these section numbers — it carries the binding
> architecture (gasless EIP-7702 relayer, signing UX, native-funding rule, facts-only data, existing-pool create price) and
> **wins on any conflict** with this file. Start here for the screen map; defer to the decisions doc wherever they differ.

## 1. Product objective

Build a polished consumer DeFi product that makes SafeSwap's economic benefit visible before and after every action.

The interface must answer two questions immediately:

1. **Trader:** How much value may SafeSwap protect compared with exposing this trade to ordinary execution?
2. **LP:** How much additional revenue may this protected pool return by charging for visible repricing surplus?

Core positioning:

```text
MEV-protected pools. Repricing revenue for LPs.
```

Supporting line:

```text
Protected swaps for traders. Better-paid liquidity for LPs.
```

The product should feel like a trading and earnings application, not a protocol administration console.

---

## 2. Product truth and claims discipline

SafeSwap should confidently visualize value, but it must distinguish facts from estimates.

### Protocol-native facts

These can be presented without an estimation disclaimer:

- quoted input and output;
- base LP fee profile;
- total quoted LP fee;
- repricing-fee component for the quoted swap;
- protocol fee;
- signed minimum output or maximum input;
- pool capture profile;
- position liquidity and range;
- total fees checkpointed by the position contract;
- protected-action status and direct collection transaction status.

### Indexer-derived facts

These require indexed chain history:

- pool TVL and volume;
- historical repricing-fee revenue;
- historical base-fee revenue;
- fee APR and rebate APR;
- per-position earned-fee attribution over time;
- pool utilization and time in range;
- post-action performance history.

### Modeled estimates

These must be visually labeled **Estimated** or **Projected**:

- estimated MEV loss avoided;
- estimated value protected;
- estimated improvement versus ordinary public execution;
- projected LP fee revenue;
- projected repricing revenue;
- projected APR or annual earnings.

Never present a modeled counterfactual as a realized saving.

Recommended fine print:

```text
Estimated improvement compares SafeSwap execution with an assumed ordinary-execution MEV loss of X%.
Actual outcomes vary with route, size, volatility, liquidity, ordering and market conditions.
```

When historical data is used:

```text
Estimate uses the selected pool's trailing 30-day observed execution and repricing data. Past performance is not a guarantee.
```

Every estimate should expose its methodology through an info tooltip or expandable `How calculated` row.

---

## 3. Value contrast is a primary UI primitive

Every price- or liquidity-sensitive action should contain a green value comparison in both preview and completion states.
Direct collection should instead contain a green realized-value summary.

Green communicates **estimated value retained or earned**, not generic success.

### Trader preview

```text
Estimated value protected
+$12.40
+0.31% versus ordinary execution*
```

### Trader completion

```text
Protected execution complete
Estimated value retained: +$12.40*
Minimum received: enforced
```

### Liquidity preview

```text
Projected SafeSwap advantage
+30.0% relative projected annual fee revenue*

Base fee projection       $420 / year
Repricing projection      $126 / year
Total projection          $546 / year
```

### Liquidity completion

```text
Liquidity added
Projected additional repricing revenue: +$126 / year*
Position is now active in a C50 protected pool.
```

### Remove and collect

Removal should summarize what the position earned while active:

```text
Position performance
Total fees earned       $51.10
Modeled SafeSwap uplift +$18.70*
```

Collection should emphasize realized collection, not MEV protection:

```text
Fees collected
$51.10 sent to your wallet
```

Do not invent a green percentage for collection itself. Collection is a direct owner/operator call with no MEV-sensitive
price impact.

---

## 4. Estimation model

The first polished release can support two estimation tiers.

### Tier A: transparent demo model

Use a configurable benchmark assumption for ordinary execution:

```text
assumed_mev_loss_bps
```

For an exact-input swap:

```text
baseline_mev_loss = input_value × assumed_mev_loss_bps / 10,000
incremental_safeswap_cost = repricing_fee + protocol_fee + incremental_gas_cost
estimated_value_protected = max(0, baseline_mev_loss - incremental_safeswap_cost)
estimated_improvement_percent = estimated_value_protected / input_value
```

For exact output, use the quoted required input as the comparison base.

The UI must show:

- the assumed baseline;
- whether gas is included;
- the price source and timestamp;
- that the estimate is not guaranteed.

Do not use a single hidden percentage for every trade. At minimum, select benchmark assumptions by:

- stable pair;
- blue-chip volatile pair;
- long-tail pair;
- trade size relative to pool liquidity.

### Tier B: production analytics model

Replace static assumptions with an analytics service using:

- pool liquidity and trade-size ratio;
- realized volatility;
- historical public-mempool execution loss for comparable trades;
- gas cost;
- historical SafeSwap repricing-fee incidence;
- route and chain.

The frontend should consume an estimate object with provenance:

```typescript
type ValueEstimate = {
    value_usd: number;
    improvement_bps: number;
    confidence: "low" | "medium" | "high";
    methodology: "demo_benchmark" | "historical_pool" | "market_model";
    baseline_mev_loss_bps: number;
    includes_gas: boolean;
    price_timestamp: number;
};
```

The model must remain replaceable without changing the transaction flow.

---

## 5. Correct protocol model

The frontend must reflect the current contracts:

- swaps are BondRoute-protected;
- create position is BondRoute-protected;
- add liquidity is BondRoute-protected;
- remove liquidity is BondRoute-protected;
- collect fees is a direct owner/operator transaction;
- there is no SafeSwap `Direct Mode` for protected actions;
- there is no trusted SafeSwap relayer requirement in the current architecture;
- BondRoute uses commit, delay, reveal and execution;
- the SDK prepares and dispatches the bond lifecycle;
- capture profiles are discrete: `C00`, `C10`, ... `C90`;
- the hook address displays two capture digits, for example `F030C50`;
- the protocol is oracle-free for repricing-fee computation;
- external prices may still be used by the frontend for USD display and counterfactual estimates.

Do not add a `Relayer Mode / Direct Mode` selector unless the underlying execution architecture is deliberately changed.
Calling protected SafeSwap functions directly is not a supported fallback.

Create, add and remove remain protected because they expose economically actionable liquidity intent and depend on mutable
pool state. Pool initialization is especially sensitive because a competing transaction can establish or move the initial
price before the position executes. For existing pools, copying the range and sizing intent or moving price before execution
can alter token composition and required deposits or withdrawals. Signed funding caps and minimum-received bounds limit the
damage by reverting bad execution; BondRoute additionally reduces advance disclosure of the pending intent. Collection does
not change liquidity or price and already enforces ownership and minimum receipts, so it does not justify that lifecycle.

---

## 6. Information architecture

Primary navigation:

```text
[ Swap ]  [ Earn ]  [ Portfolio ]
```

Secondary navigation:

```text
Docs · How it works · Network · Wallet
```

### Swap

Default landing product and highest visual priority.

### Earn

Pool discovery and position creation:

```text
[ Explore pools ]  [ Launch protected pool ]
```

### Portfolio

Owned positions, pending protected actions, earnings and collection.

Do not combine every contract operation into one technical dropdown.

---

## 7. Landing and brand hierarchy

Hero:

```text
SafeSwap

Keep more when you trade.
Earn more when you provide liquidity.

MEV-protected pools. Repricing revenue for LPs.

[ Swap protected ]  [ Explore earnings ]
```

Supporting visual:

```text
Ordinary execution          SafeSwap
Value exposed to MEV        Protected intent
Repricing captured outside  Repricing revenue paid to LPs
```

Avoid leading with hooks, NFTs, BCD addresses, LVR or raw BondRoute mechanics. Those belong in detail views and educational
tooltips.

---

## 8. Swap experience

### Default swap card

```text
Swap

[ You pay                         ]
[ You receive                     ]

Route: ETH / USDC · Protected C50

Estimated value protected
+$12.40
+0.31% versus ordinary execution*

[ Review protected swap ]
```

### Quote details

Collapsed by default:

```text
Minimum received
Price impact
Base LP fee
Estimated repricing fee
Protocol fee
Network cost
Estimated total cost
```

The total LP fee returned by the quoter can be separated for display:

```text
repricing_fee_pips = total_fee_pips - base_fee_pips
```

Use precise wording:

```text
The repricing fee grows only when this swap extracts visible repricing surplus.
```

Do not promise that SafeSwap is cheaper on every swap.

### Protected execution flow

Do not expose `prepare`, `create bond`, `wait` and `execute` as developer concepts in the main flow.

Present them as one guided state machine:

```text
1. Review
2. Commit protection
3. Protection active
4. Execute swap
5. Complete
```

Recommended status copy:

```text
Securing your execution
Your swap details remain hidden until execution is eligible.
```

```text
Protection active
Execution becomes available in approximately N blocks.
```

The wallet signing preview should be a trust panel, not the primary product screen. Show the human fields first and put raw
digest, protocol address, token anchors, stake and salt under `Advanced verification`.

### Swap completion receipt

```text
Swap protected

Received                 0.412 ETH
Estimated value retained +$12.40*
Total SafeSwap cost      $3.18
Execution status         Protected

[ View transaction ] [ Make another swap ]
```

Persist receipts locally and, when indexing exists, in portfolio history.

---

## 9. Earn experience

Top copy:

```text
Earn from protected liquidity

LPs earn normal swap fees plus repricing revenue when their liquidity helps move price.
```

Tabs:

```text
[ Explore pools ] [ My positions ] [ Launch pool ]
```

### Pool card

```text
ETH / USDC
Protected pool · C50

TVL                         $4.2m
Base fee APR                4.8%
Repricing revenue APR       1.3%*
Total estimated APR         6.1%*

30d repricing revenue       $18,420
In-range liquidity          82%

[ Add liquidity ]
```

Only show APR and historical revenue when backed by indexed data. Until then, use a clearly marked scenario:

```text
Projected at current assumptions*
```

### Position card

Use the on-chain NFT art as the visual identity, but call it a **position**.

```text
ETH / USDC
Position #0x8F...21

Value                       $12,840
Total fees earned           $51.10
Modeled SafeSwap uplift     +$18.70*
Status                      In range

[ Add ] [ Remove ] [ Collect ]
```

Important accounting limitation:

The current position contract checkpoints total earned fees. It does not store a historical per-position split between base
fees and repricing fees. A truthful realized split requires an indexer that reconstructs swap fee components and attributes
them across served liquidity. Until that exists:

- label on-chain accounting as `Total fees earned`;
- label any base/repricing split as `Estimated breakdown`;
- never present the estimated split as contract-recorded truth.

---

## 10. Add liquidity flow

Production UX should not ask ordinary users for raw liquidity units or raw sqrt prices.

Flow:

```text
1. Select pool
2. Choose range
3. Enter deposit amounts
4. Review projected earnings
5. Confirm protected action
```

Range choices:

```text
[ Full range ] [ Conservative ] [ Active ] [ Custom ]
```

Show:

- current market price;
- lower and upper human prices;
- in-range probability or historical range occupancy when available;
- token composition;
- funding caps;
- minimum deposited amounts;
- projected base-fee revenue;
- projected repricing revenue;
- projected SafeSwap uplift.

Preview:

```text
Projected earnings*

Ordinary LP fee revenue       $420 / year
SafeSwap repricing revenue   +$126 / year
Projected total               $546 / year
Estimated improvement         +30.0%
```

Define this percentage as:

```text
projected_relative_revenue_uplift =
    projected_repricing_revenue / projected_ordinary_lp_fee_revenue
```

The percentage is a modeled relative revenue scenario, not APR percentage points and not a guarantee.

Completion:

```text
Liquidity added

Position value                $5,000
Projected SafeSwap uplift     +$126 / year*
Capture profile               C50
Protection                    Active
```

---

## 11. Launch protected pool flow

CTA:

```text
Launch protected pool
```

This is an advanced LP flow, not a homepage primary CTA.

Inputs:

```text
Pair
Initial human price
Range
Deposit amounts
Base LP fee
Repricing capture
Tick spacing (advanced)
```

Recommended fee presets:

```text
0.01% · 0.05% · 0.30% · 1.00% · Custom
```

Capture selector:

```text
C00 C10 C20 C30 C40 C50 C60 C70 C80 C90
```

Copy:

```text
C50 pays LPs 50% of the swap's estimated visible repricing surplus.
The remaining surplus preserves the incentive to keep the pool price fresh.
```

Do not show hook-address mining to ordinary users. If the selected profile has no registered hook, show:

```text
This protection profile is not deployed on this network yet.
```

Profile deployment is an operator/power-user workflow, not part of pool creation.

---

## 12. Remove liquidity and collect

### Remove

Keep BondRoute protection and show minimum received amounts.

Preview:

```text
You receive at least
1,485 USDC + 0.49 WETH

Position earnings to date
Total fees earned           $51.10
Modeled SafeSwap uplift    +$18.70*
```

### Collect

Collection is direct and should be fast:

```text
Collect fees

Available total fees       $51.10
Minimum received           Optional advanced setting

[ Collect to wallet ]
```

Do not show BondRoute stake, delay, signing receipt or protection language for collection.

---

## 13. Data and indexing requirements

A polished final product needs more than contract reads.

### Required indexer outputs

- registered pools and profiles;
- pool token metadata;
- pool TVL and volume;
- swap history;
- base and repricing fee components per swap;
- protocol fees;
- position ownership;
- position lifecycle events;
- estimated fee attribution by position/range;
- pending and completed BondRoute actions;
- USD pricing with source and timestamp.

### Contract/API gaps to handle

- no canonical pool-directory endpoint currently exists in the SDK;
- pool discovery requires indexed registry and initialization data;
- position enumeration requires ERC-721 event indexing or wallet NFT discovery;
- realized base-versus-repricing fee split is not stored per position;
- human price/range and token-amount preparation need higher-level SDK helpers;
- create/add currently expose low-level liquidity and price inputs;
- transaction receipts need normalized result summaries.

The frontend should not hardcode demo pools as if they are discovered on-chain. Demo fixtures must be visibly labeled.

---

## 14. Visual system

Use a restrained premium financial aesthetic.

### Green usage

Reserve bright green for:

- estimated value protected;
- estimated improvement;
- projected or realized earnings;
- successful protected execution;
- collectible value.

Do not make every border and background green. The value number should be the strongest green object on screen.

### Supporting colors

- deep neutral background;
- white primary text;
- muted slate secondary text;
- cyan for protocol/protection state;
- amber for estimates with low confidence or assumption warnings;
- red only for loss, failed constraints or destructive actions.

### Value card

Every action uses the same visual grammar:

```text
Small label
Large green +$ value
Green +X.XX% comparison
Muted methodology line*
```

Animate the number only when a quote changes or an action completes. Avoid continuous motion that competes with financial
information.

---

## 15. Marketing language

### Use

```text
Keep more when you trade.
```

```text
Get paid when your liquidity helps move the market.
```

```text
Protected execution. Better-paid liquidity.
```

```text
Estimated value protected.
```

```text
Projected SafeSwap advantage.
```

### Avoid

- `MEV-free`;
- `guaranteed savings`;
- `guaranteed yield`;
- `eliminates LVR`;
- `always cheaper`;
- `risk-free`;
- `exact MEV saved`;
- `base fees earned` as a separate realized number without indexer attribution.

Use `repricing revenue` as the broad LP benefit. Use `repricing fee` from the trader perspective and `repricing revenue` from
the LP perspective.

---

## 16. Responsive behavior

Desktop:

- swap form and value comparison side by side;
- pool grid of two or three columns;
- position detail drawer or modal.

Mobile:

- value-protected card immediately below token amounts;
- sticky primary CTA;
- quote details collapsed;
- protected execution progress full width;
- position actions in a bottom sheet.

The most important green value number must remain above the fold on both layouts.

---

## 17. Empty, loading and failure states

### No wallet

```text
Connect your wallet to swap protected or manage liquidity.
```

### No pools

```text
No protected pools are available for this pair on this network.
```

### No positions

```text
No positions yet.
Put your liquidity to work earning swap fees and repricing revenue.
```

### Estimate unavailable

```text
Value comparison unavailable
The transaction quote is still valid. Market comparison data could not be loaded.
```

Never block execution solely because the marketing estimate service is unavailable.

### Protected action reverted

Translate SafeSwap custom errors into user language and preserve the bond settlement status.

### Pending recovery

Pending BondRoute actions must survive refresh and reconnect. Show them in a persistent activity center.

---

## 18. Analytics and business metrics

Track the funnel separately for traders and LPs.

### Trader funnel

- quote requested;
- estimate displayed;
- review opened;
- bond committed;
- execution eligible;
- execution completed;
- estimated protected value;
- repeat swap within 7/30 days.

### LP funnel

- pool viewed;
- earnings projection viewed;
- position prepared;
- position created or liquidity added;
- projected repricing revenue;
- fees collected;
- liquidity retained after 7/30 days.

### Product north-star metrics

```text
Estimated trader value protected
```

```text
Repricing fees paid to LPs
```

Keep estimated and realized metrics separate in analytics and public reporting.

---

## 19. Implementation phases

### Phase 1: polished hackathon product

- replace the technical action dropdown with `Swap / Earn / Portfolio`;
- build token selectors and human amount inputs;
- use the existing swap quoters;
- add the green value-protected card with a visible demo benchmark assumption;
- wrap BondRoute dispatch in a guided progress state;
- show five protected signing previews under advanced verification;
- support direct fee collection;
- add polished completion receipts;
- use curated demo pools, clearly labeled.

### Phase 2: credible beta

- pool and position indexer;
- wallet position discovery;
- historical pool metrics;
- external USD price service;
- replace static MEV benchmark with pair/size-aware historical estimates;
- human range and liquidity math helpers;
- activity and receipt history;
- mobile optimization.

### Phase 3: production

- robust analytics methodology and public methodology page;
- confidence ranges;
- multi-chain pool registry;
- notification/recovery flows;
- position performance attribution;
- accessibility and localization;
- monitored data freshness and fallback behavior.

---

## 20. Acceptance criteria

The redesign is successful when:

1. A new visitor understands the trader and LP benefits within five seconds.
2. Swap is the default and dominant action.
3. Every swap preview and receipt shows a green estimated-value comparison.
4. Every create/add preview and receipt shows projected base revenue, repricing revenue and estimated uplift.
5. Every estimate shows an assumption or methodology disclosure.
6. Collection is presented as a direct transaction without BondRoute protection claims.
7. Protected actions hide implementation complexity behind a clear progress flow.
8. No screen requires users to understand raw sqrt prices, raw liquidity units, hook addresses or BCD encoding.
9. Realized and estimated values are visually and semantically distinct.
10. The app still permits execution when estimate or analytics services are unavailable.

---

## 21. Demo narrative

The final demo should tell one economic story:

1. A trader enters a swap.
2. SafeSwap shows a green estimated `+$ value protected` versus ordinary execution.
3. The trader commits and executes through protected BondRoute flow.
4. The completion receipt repeats the estimated retained value.
5. The demo switches to the LP side.
6. A pool card shows base fee projection plus repricing revenue projection.
7. Adding liquidity shows a green projected SafeSwap uplift.
8. The owned position shows total fees and an explicitly modeled SafeSwap attribution.
9. Fee collection sends the available fees directly to the wallet.

North-star sentence:

```text
SafeSwap helps traders retain value and pays LPs for the repricing their liquidity makes possible.
```
