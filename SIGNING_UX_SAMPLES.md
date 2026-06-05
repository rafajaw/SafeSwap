# SafeSwap Signing UX Samples

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

The final struct hash is built from `typeHash, fundingsHash, stakeHash, salt, protocol, actionHash`. SafeSwap can make that
custom action readable by adding short on-chain generated string fields, then keeping only the critical raw fields needed to
anchor security. The display strings are signed for display integrity; execution must still use the raw fields.

All receipt blocks below use spaces only, no tabs.

## Exact Input Swap

Proposed SafeSwap type string:

```text
ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,ExactInputSwap sS__SWAP__Ss)ExactInputSwap(string Action,string Pool,string Warning,address USDC)TokenAmount(address token,uint256 amount)
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
    Action:    Send max 1.2500 WETH for min 4,218.50 USDC
    Pool:      0.3% base-fee, 50% rebate, tick spacing 60
    Warning:   >>>   Check expected token addresses   <<<
    USDC:      0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
```

## Exact Output Swap

Proposed SafeSwap type string:

```text
ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,ExactOutputSwap sS__SWAP__Ss)ExactOutputSwap(string Action,string Pool,string Warning,address USDC)TokenAmount(address token,uint256 amount)
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
    Action:    Send max 1.2000 WETH for exactly 4,000.00 USDC
    Pool:      0.3% base-fee, 50% rebate, tick spacing 60
    Warning:   >>>   Check expected token addresses   <<<
    USDC:      0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
```

## Create LP Position

Proposed SafeSwap type string:

```text
ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,CreatePosition sS__CREATE_POSITION__Ss)CreatePosition(string Action,string Pool,string Warning,address WETH,address USDC)TokenAmount(address token,uint256 amount)
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
    Action:    Create WETH/USDC LP using max 1.2500 WETH and 4,200.00 USDC; min deposit 1.2400 WETH and 4,180.00 USDC; liquidity 340282366920938463463374607431768211
    Pool:      0.3% base-fee, 50% rebate, tick spacing 60, ticks -887220 to 887220, sqrt_price_x96 433950517987477948943152178624
    Warning:   >>>   Check expected token addresses   <<<
    WETH:      0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
    USDC:      0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
```

## Add Liquidity

Proposed SafeSwap type string:

```text
ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,AddLiquidity sS__ADD_LIQUIDITY__Ss)AddLiquidity(string Action,string Pool,string Warning,address WETH,address USDC)TokenAmount(address token,uint256 amount)
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
    Action:    Add liquidity to LP #9166523579416187058 using max 0.5000 WETH and 1,680.00 USDC; min deposit 0.4950 WETH and 1,660.00 USDC; liquidity 1200000000000000000
    Pool:      WETH/USDC, 0.3% base-fee, 50% rebate, tick spacing 60
    Warning:   >>>   Check expected token addresses   <<<
    WETH:      0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
    USDC:      0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
```

## Remove Liquidity

Proposed SafeSwap type string:

```text
ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,RemoveLiquidity sS__REMOVE_LIQUIDITY__Ss)RemoveLiquidity(string Action,string Pool,string Warning,address WETH,address USDC)TokenAmount(address token,uint256 amount)
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
    Action:    Remove liquidity 600000000000000000 from LP #9166523579416187058 for min 0.2450 WETH and 830.00 USDC
    Pool:      WETH/USDC, 0.3% base-fee, 50% rebate, tick spacing 60
    Warning:   >>>   Check expected token addresses   <<<
    WETH:      0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
    USDC:      0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
```

## Collect Fees

Proposed SafeSwap type string:

```text
ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,CollectFees sS__COLLECT_FEES__Ss)CollectFees(string Action,string Pool,string Warning,address WETH,address USDC)TokenAmount(address token,uint256 amount)
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
  salt:     9223372036854775814
  protocol: 0x3333333333333333333333333333333333333333
  sS__COLLECT_FEES__Ss
    Action:    Collect fees from LP #9166523579416187058 for min 0.0100 WETH and 42.00 USDC
    Pool:      WETH/USDC, 0.3% base-fee, 50% rebate, tick spacing 60
    Warning:   >>>   Check expected token addresses   <<<
    WETH:      0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
    USDC:      0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
```

## Notes Before Coding

- `BondRoute_get_signing_info()` must generate the same display strings on-chain that the wallet signs.
- Dynamic strings such as `Action`, `Pool`, and `Warning` are hashed as `keccak256(bytes(value))` inside the
  SafeSwap struct hash.
- `Action` and `Pool` must be canonical commitments, not rounded marketing copy. If a raw parameter changes, at least one
  signed display field must change.
- The current BondRoute SDK reconstructs typed-data messages by decoding the protected calldata. If display strings are
  generated on-chain instead of included in calldata, the SDK needs a companion message-values path; otherwise it can only
  raw-sign the digest and the wallet will not render these fields.
- Existing token amounts in the BondRoute envelope already expose input tokens and input limits; duplicate them in display
  strings for readability, but keep the raw typed security anchors minimal.
- Token formatting should use defensive on-chain `symbol()` / `decimals()` reads with fallbacks, following the NFT descriptor
  style.
