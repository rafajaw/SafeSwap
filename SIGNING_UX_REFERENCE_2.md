# SafeSwap Signing UX Samples - Reference 2 (terse symbolic values)

*Variant of `SIGNING_UX_REFERENCE_1.md`: same structure, but amount qualifiers use symbols (`<=`, `>=`, `=`, `+`), the
range separator is `~`, prices use `USDC/WETH`, and the pool line uses `|` separators.*

## Why prefer the symbolic variant

The signed *values* become math notation (`<=`, `>=`, `=`, `+`, `~`, `/`, `|`, `%`, digits, hex addresses) - language
independent (a reader anywhere parses `<= 1.25 WETH + 4,200 USDC` the same way), shorter to scan, and fewer bytes to build
and hash on-chain (gas). Three wins at once: i18n, brevity, gas.

**Boundary - this buys universal _values_, not universal _labels_:**

- EIP-712 field names must be valid identifiers (ASCII letters/digits/underscore, no spaces, symbols, or emoji), so the
  labels (`Pay`, `Receive`, `Deposit`, `Minimum`, `Liquidity`, `Range`, `Price`, `Pool`, `Warning`, `Position`, `Burn`) are
  stuck as English-ish words *by the standard itself*. They are baked into the signed type string, so a wallet cannot
  translate them without changing the hash - true localization must be a wallet-side overlay shown next to the canonical
  English label.
- The `Warning` value is the only prose field and is English-only. It is a nudge, not the real control (the real check is
  `protocol` / token addresses against a known list, which is language-independent hex - see "What the signer must verify").
- Every glyph is plain ASCII (`<=`, `>=`, `=`, `~`, `+`, `/`, `|`, `%`), so the receipt renders identically on every wallet,
  including old hardware-wallet screens. No Unicode separators (the pool line uses `|`, not a middot).

## Goal

Model the gasless BondRoute signing path as the wallet actually sees it: an EIP-712 `ExecuteBondAs` message with a SafeSwap
custom action struct inside it.

BondRoute signs this envelope, in order:

```text
ExecuteBondAs
  fundings: TokenAmount[]
  stake:    TokenAmount
  salt:     uint256
  protocol: address
  <display action>: <SafeSwap custom struct>
```

BondRoute requires the first four envelope fields and lets the protected protocol define the next field name and type. These
examples make that field a loud display label such as `sS__SWAP__Ss` or `sS__COLLECT_FEES__Ss`. The Solidity execution
payload still stores raw bytes as `ExecutionData.call`.

The final struct hash is built from `typeHash, fundingsHash, stakeHash, salt, protocol, actionHash`. SafeSwap makes that
custom action readable by adding short, role-named, on-chain generated string fields, then keeping only the critical raw
address fields needed to anchor security. The display strings are signed for display integrity; execution still uses the raw
fields.

## Design rules for this version

- **Role-named fields, not prose.** The long `Action` / `Pool` blobs are split into short fields whose *names* carry the role
  (`Pay`, `Receive`, `Deposit`, `Minimum`, `Liquidity`, `Range`, `Price`, `Pool`). Field names are plain single words - this is
  user-facing, so no `camelCase` or dev syntax. No field restates what its name already says.
- **Each symbol appears once per role.** A WETH/USDC action shows `WETH` and `USDC` once per line that needs them, never the
  3x repetition of the old single-string form. Less to read, fewer bytes to build and hash on-chain.
- **Amounts are full precision (canonical).** Every amount is rendered with `StringHelperLib.FULL_PRECISION`, so the signed
  string is a true commitment: if a raw amount changes, the string changes. Trailing zeros are trimmed, so clean amounts
  stay short (`1.25`, `4,218.5`) and only genuinely high-precision raw values render long.
- **Raw addresses stay as typed `address` fields** - the hard security anchor the user verifies. The token *address* field is
  labeled with its (sanitized) symbol so the user reads "this `USDC` field is address 0x...".
- **Ranges and init prices are signed as human prices.** Create signs `Range` / `Price` as real quoted prices (via `PriceLib`
  + `StringHelperLib.format_price`); the raw ticks and sqrtPriceX96 are NOT shown. This requires the contract to treat the
  signed price as the source of truth and derive tick / sqrtPrice from it on-chain (snapping to tick spacing) - see the note
  below. A relayer cannot steal funds by nudging the range or init price; the committed `Deposit` (max) and `Minimum` (floor)
  amounts bound the actual deposit, so they are the economic anchor, not the exact tick math.

All receipt blocks below use spaces only, no tabs.

## What the signer must verify (and why)

By signing time the fundings are already approved on BondRoute, so the receipt is not about *how much* - it is about *who
executes and against which tokens*. Two checks, in order:

1. **`protocol`** - the root of trust. BondRoute hands the funded execution to `protocol`, and SafeSwap generates these very
   display strings inside `protocol`'s own `BondRoute_get_signing_info`. A rogue `protocol` can therefore render a receipt
   byte-identical to a legitimate SafeSwap one and still drain the fundings. So **every human-readable field - the `Warning`
   included - is only trustworthy once `protocol` is confirmed to be the canonical SafeSwap router (swaps) or NFT (LP)**,
   checked against the published ChainConfig addresses, never against anything in the receipt itself. If `protocol` is wrong,
   nothing else here means anything.
2. **Token addresses** - with a genuine `protocol`, the contract still pools and swaps any token permissionlessly, so
   the signer must confirm the token addresses are the real assets they intend (especially the token they *receive*) and not
   look-alikes.

Amounts and slippage are shown for confirmation, but the raw `fundings` / `stake` the signer already committed are the hard
limits the contract enforces.

## Exact Input Swap

Proposed SafeSwap type string:

```text
ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,ExactInputSwap sS__SWAP__Ss)ExactInputSwap(string Pay,string Receive,string Pool,string Warning,address USDC)TokenAmount(address token,uint256 amount)
```

Wallet display:

```text
Domain
  name:              BondRoute
  version:           1
  chainId:           1
  verifyingContract: 0x1111111111111111111111111111111111111111

Primary type
  ExecuteBondAs

Message
  fundings[0]
    token:  0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
    amount: 1250000000000000000
  stake
    token:  0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
    amount: 12500000000000000
  salt:     9223372036854775809
  protocol: 0x2222222222222222222222222222222222222222
  sS__SWAP__Ss
    Pay:      = 1.25 WETH
    Receive:  >= 4,218.5 USDC
    Pool:     0.3% base fee | 50% rebate | tick spacing 60
    Warning:  >>  Check protocol and token addresses  <<
    USDC:     0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
```

## Exact Output Swap

Proposed SafeSwap type string:

```text
ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,ExactOutputSwap sS__SWAP__Ss)ExactOutputSwap(string Pay,string Receive,string Pool,string Warning,address USDC)TokenAmount(address token,uint256 amount)
```

Wallet display:

```text
Domain
  name:              BondRoute
  version:           1
  chainId:           1
  verifyingContract: 0x1111111111111111111111111111111111111111

Primary type
  ExecuteBondAs

Message
  fundings[0]
    token:  0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
    amount: 1200000000000000000
  stake
    token:  0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
    amount: 12000000000000000
  salt:     9223372036854775810
  protocol: 0x2222222222222222222222222222222222222222
  sS__SWAP__Ss
    Pay:      <= 1.2 WETH
    Receive:  = 4,000 USDC
    Pool:     0.3% base fee | 50% rebate | tick spacing 60
    Warning:  >>  Check protocol and token addresses  <<
    USDC:     0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
```

## Create LP Position

The two token funding caps are explicit `maximum_deposit_a` / `maximum_deposit_b` action parameters paired with
`minimum_deposit_a` / `minimum_deposit_b`. SafeSwap derives BondRoute's required fundings from those maxima and requires the
executed funding envelope to match them exactly. The displayed `Deposit` remains the deterministic liquidity requirement
calculated from the signed liquidity, range, and initial price; the explicit maxima are the separately signed funding caps.

Proposed SafeSwap type string:

```text
ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,CreatePosition sS__CREATE_POSITION__Ss)CreatePosition(string Deposit,string Minimum,string Liquidity,string Range,string Price,string Pool,string Warning,address WETH,address USDC)TokenAmount(address token,uint256 amount)
```

Wallet display:

```text
Domain
  name:              BondRoute
  version:           1
  chainId:           1
  verifyingContract: 0x1111111111111111111111111111111111111111

Primary type
  ExecuteBondAs

Message
  fundings[0]
    token:  0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
    amount: 1250000000000000000
  fundings[1]
    token:  0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
    amount: 4200000000
  stake
    token:  0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
    amount: 84000000
  salt:     9223372036854775811
  protocol: 0x3333333333333333333333333333333333333333
  sS__CREATE_POSITION__Ss
    Deposit:   <= 1.25 WETH + 4,200 USDC
    Minimum:   >= 1.24 WETH + 4,180 USDC
    Liquidity: 340282366920938463463374607431768211
    Range:     2,850 ~ 3,150 USDC/WETH
    Price:     3,002.5 USDC/WETH
    Pool:      0.3% base fee | 50% rebate | tick spacing 60
    Warning:   >>  Check protocol and token addresses  <<
    WETH:      0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
    USDC:      0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
```

## Add Liquidity

`Deposit` is built from the explicit `maximum_deposit_a` / `maximum_deposit_b` action parameters, not from live pool price.
SafeSwap requires those token+amount pairs to exactly match the two BondRoute fundings at execution. This deliberate
two-level commitment gives the generic BondRoute transfer authorization protocol-specific meaning while keeping the digest
stable if pool price moves after signing. Each paired `minimum_deposit_*` applies to the same token as its maximum.

Proposed SafeSwap type string:

```text
ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,AddLiquidity sS__ADD_LIQUIDITY__Ss)AddLiquidity(string Position,string Deposit,string Minimum,string Liquidity,string Pool,string Warning,address WETH,address USDC)TokenAmount(address token,uint256 amount)
```

Wallet display:

```text
Domain
  name:              BondRoute
  version:           1
  chainId:           1
  verifyingContract: 0x1111111111111111111111111111111111111111

Primary type
  ExecuteBondAs

Message
  fundings[0]
    token:  0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
    amount: 500000000000000000
  fundings[1]
    token:  0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
    amount: 1680000000
  stake
    token:  0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
    amount: 33600000
  salt:     9223372036854775812
  protocol: 0x3333333333333333333333333333333333333333
  sS__ADD_LIQUIDITY__Ss
    Position:  LP #9166523579416187058
    Deposit:   <= 0.5 WETH + 1,680 USDC
    Minimum:   >= 0.495 WETH + 1,660 USDC
    Liquidity: 1200000000000000000
    Pool:      0.3% base fee | 50% rebate | tick spacing 60
    Warning:   >>  Check protocol and token addresses  <<
    WETH:      0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
    USDC:      0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
```

## Remove Liquidity

Proposed SafeSwap type string:

```text
ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,RemoveLiquidity sS__REMOVE_LIQUIDITY__Ss)RemoveLiquidity(string Position,string Burn,string Receive,string Pool,string Warning,address WETH,address USDC)TokenAmount(address token,uint256 amount)
```

Wallet display:

```text
Domain
  name:              BondRoute
  version:           1
  chainId:           1
  verifyingContract: 0x1111111111111111111111111111111111111111

Primary type
  ExecuteBondAs

Message
  fundings: []
  stake
    token:  0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
    amount: 1000000
  salt:     9223372036854775813
  protocol: 0x3333333333333333333333333333333333333333
  sS__REMOVE_LIQUIDITY__Ss
    Position: LP #9166523579416187058
    Burn:     600000000000000000 liquidity
    Receive:  >= 0.245 WETH + 830 USDC
    Pool:     0.3% base fee | 50% rebate | tick spacing 60
    Warning:  >>  Check protocol and token addresses  <<
    WETH:     0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
    USDC:     0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
```

## Notes Before Coding

- `BondRoute_get_signing_info()` must generate the same display strings on-chain that the wallet signs.
- Every display field (`Pay`, `Receive`, `Deposit`, `Minimum`, `Liquidity`, `Range`, `Price`, `Pool`, `Position`, `Burn`,
  `Warning`) is hashed as `keccak256(bytes(value))` inside the SafeSwap struct hash.
- Amounts use `StringHelperLib.FULL_PRECISION` so each display field is a canonical commitment - if a raw parameter changes,
  the signed string changes. Never render a signed amount with the cosmetic card cap.
- The token *address* field name is the token's symbol (`WETH`, `USDC`). Because the EIP-712 type string is generated on-chain
  per call, that symbol is embedded in the type string itself, so it MUST be sanitized the same way the NFT descriptor
  sanitizes symbols (alphanumeric subset, length-capped) - a raw `symbol()` could otherwise inject characters that corrupt
  the type string. Read `symbol()` / `decimals()` defensively once per token and reuse.
- The raw typed fields (`fundings`, `stake`, the `address` token fields) remain the hard security anchors. Input amounts are
  already exposed as raw `uint256` in `fundings`; the display strings duplicate them for readability but the raw values are
  what execution and slippage checks read.
- **Create signs the price, not raw ticks / sqrtPrice (contract requirement).** Because the receipt shows only `Range` /
  `Price`, those strings ARE the committed values, so execution must derive `tickLower` / `tickUpper` / `sqrtPriceX96` from
  the signed price on-chain, snapping to the pool's tick spacing by a fixed rule. The snapped ticks therefore differ slightly
  from the exact signed price; that drift is sub-display-precision and is further bounded by the committed `Deposit` /
  `Minimum` amounts (a manipulated range/price that moved real deposits would breach the `Minimum` floor and revert). The
  raw tick / sqrtPrice are deliberately absent from the receipt - they add bit-exact "where" binding that cannot be stolen
  against and only clutter a user-facing message.
- The current BondRoute SDK reconstructs typed-data messages by decoding the protected calldata. Since these display strings
  are generated on-chain rather than carried in calldata, the SDK needs a companion message-values path; otherwise it can
  only raw-sign the digest and the wallet will not render these fields.
- Gas/UX balance: splitting one long string into a few short role-named fields is roughly hash-neutral (similar total bytes
  plus a small per-field overhead), and dropping repeated symbols is a net byte (gas) saving. The win is paid for by reading
  each token's `symbol()` / `decimals()` exactly once.
