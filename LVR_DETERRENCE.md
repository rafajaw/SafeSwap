# SafeSwap LP Repricing Rebate — Why & Economics

> Companion docs: **`REPRICING_REBATE_ADDRESS_CONFIG.md`** (architecture: router / NFT / hook / address encoding) and
> **`DYNAMIC_FEE_REBATE_PLAN.md`** (implementation: mechanism formula, work breakdown, tests). This doc is the *why*. Where
> they disagree, `DYNAMIC_FEE_REBATE_PLAN.md` is the binding spec.

## 1. The problem: LVR

In a classic AMM the external price moves, the pool price lags, an arbitrageur trades the pool back to the true price, and
the LPs are rebalanced *through the stale curve*. The arbitrageur keeps the difference. That difference — loss-versus-rebalancing
(LVR) — is value the LPs created (by being moveable) but did not capture.

BondRoute alone does not fix this. A bonded arbitrageur can still move a stale pool and keep the repricing value; the action is
*authorized* but not *priced*. SafeSwap turns protected access into **priced** access.

## 2. The mechanism in one line

> When a swap moves the pool price, SafeSwap estimates the **surplus** that swap extracts and routes a configurable share of
> it to the LPs whose liquidity served the move.

```
total swap fee = base LP fee + repricing fee
repricing fee  = capture% × estimated repricing surplus
```

`capture%` (the pool's "C" config, 0–90% in 10% steps) is **the share of the surplus paid to LPs** — not a fee rate applied
to price movement. This distinction is the whole ballgame (see §4).

## 3. What "surplus" is (and why it is oracle-free)

The surplus of a swap is the value it extracts by moving the price:

```
surplus = (output valued at the post-swap price) − (input paid)      // in input-token units, ≥ 0
```

Geometrically it is the price-impact area between the AMM curve and the swap's terminal price — exactly the profit an
arbitrageur earns when they push the pool to the external price. SafeSwap reads the **post-swap pool price it simulates**, not
an external feed, so the mechanism stays oracle-free: it never needs to know the "true" price, only how far *this* swap moved
the pool and what that move was worth.

It measures **displacement, not intent**. A large trade in deep liquidity barely moves the price → tiny surplus → tiny fee. A
small trade in thin liquidity moves it a lot → larger surplus → larger fee. SafeSwap does not classify tokens; the pool's own
depth does the work.

## 4. Why surplus, not "capture × displacement" (the calibration trap)

The tempting shortcut is to charge a fee *rate* equal to `capture% × price movement`. It is wrong, and badly so.

A flat fee rate `r` is charged on the whole input, so the fee is `r × input`. But the surplus is only the price-impact
*triangle*, roughly `½ × movement × input`. So:

```
fee / surplus  =  (movement · capture · input) / (½ · movement · input)  =  2 × capture
```

A "50% capture" dial would actually take **~100% of the surplus**; a "90%" dial would try to take **~180%** — i.e. the
repricing trade goes underwater and never happens, leaving the pool stale. The factor is ~2× and scale-invariant. Defining
`capture%` directly against the surplus removes it: C5 means LPs get ~half the surplus and the arbitrageur keeps ~half, which
is what the name always implied.

This is why the **90% ceiling** is meaningful: it guarantees arbitrageurs keep **at least 10% of the surplus**, preserving
their incentive to keep the pool fresh. A 100% capture would halt price correction. (That guarantee is only true *because*
the fee is surplus-based.)

## 5. Splitting: honest framing

Economically, the total surplus of moving the pool from price A to price B is the same whether done in one swap or ten — you
are right to expect that. But the fee is decided **per swap**, oracle-free, and a single `beforeSwap` only sees where *that*
swap starts and ends. It cannot tell that ten small swaps are one repricing campaign aimed at B. So a split trade is charged
on each swap's *locally visible* surplus, and the sum is less than the single-swap fee — the gap is the profit on
early-acquired tokens later sold at the final price, which no myopic per-swap fee can observe.

Therefore SafeSwap makes **no claim** that the fee formula alone is splitting-proof. The splitting deterrent is **BondRoute**:
every swap requires its own stake, two-transaction commit-reveal, and execution delay, so slicing one arb into many is
operationally expensive and slow. v1 deliberately does **not** add cross-swap cumulative-movement tracking — it is immutable,
and that stateful machinery would add more attack surface and parameter risk than the residual leak BondRoute already taxes.

> Correct claim: *the fee captures each swap's visible repricing surplus; BondRoute makes systematic splitting expensive.*
> Not: *the formula makes splitting irrelevant.*

## 6. Parameterization

`base fee` and `capture%` are chosen per pool and encoded in the hook address (see the architecture doc). There is no single
right value:

```
USDC/USDT     low capture  (deep, low toxicity)
ETH/USDC      medium capture
long-tail     high capture (thin, volatile)
```

LPs and routers discover the equilibrium: too little capture and LPs migrate away; too much and routers route around the pool
and arbitrage stops (pool goes stale). Capture is quantized to 10% steps to keep liquidity from fragmenting across
indistinguishable variants and to block odd/predatory values.

## 7. Fee destination

100% of the repricing fee accrues to LPs, natively, as a Uniswap V4 dynamic LP fee — so it is paid **path-fairly** to each
range the swap crosses, in proportion to the liquidity that served the move. SafeSwap takes its protocol fee separately from
output (unchanged), so the repricing rebate is not diluted by a protocol cut.

## 8. What this is and is not

SafeSwap **does**: price pool displacement, rebate LPs for repricing, stay oracle-free, reduce uncompensated repricing
leakage, and make bots pay LPs when they move the pool toward a focal price.

SafeSwap **does not**: know the external fair price, detect "toxic" trades by intent, measure true LVR exactly, guarantee LP
profit, or capture the exact arbitrage surplus (it estimates per-swap visible surplus).

## 9. Versus auction designs (e.g. Angstrom)

Auctions sell the *right to reprice* to searchers via off-chain sequencing — better price discovery, but trust, liveness, and
complexity costs. SafeSwap posts a **deterministic on-chain toll** on the repricing surplus — simpler, trustless, oracle-free,
no sequencer — at the cost of not discovering the exact MEV value. Positioning:

> Auctions auction the right to reprice. SafeSwap posts a deterministic toll on the repricing surplus and pays it to LPs.
