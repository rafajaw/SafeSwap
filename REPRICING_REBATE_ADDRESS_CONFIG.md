# SafeSwap Repricing Rebate — Architecture & Address Config

> Companion docs: **`LVR_DETERRENCE.md`** (why / economics) and **`DYNAMIC_FEE_REBATE_PLAN.md`** (mechanism formula, work
> breakdown, tests). This doc is the *shape* of the system: contracts, the hook-address encoding, and the registry.

## Topology

Three roles, split so that V4 position ownership lives in exactly one contract:

```
SafeSwapRouter      canonical user entrypoint; BondRoute-protected swaps; hook registry; treasury; quoting.
                    Owns no positions.
SafeSwapNft         BondRoute-protected position lifecycle (create / add / remove / collect); ERC721 LP registry.
                    OWNS the V4 positions (it is the modifyLiquidity caller; salt = tokenId). Resolves the hook via the router.
SafeSwapSigningDescriptor
                    Immutable external REFERENCE_2 renderer shared by the router and NFT signing-info surfaces.
SafeSwapHook        one implementation (SafeSwapHookImpl) + many permissionlessly-deployed config clones, one per
                    (base fee, capture) profile, all sharing one runtime codehash. Dynamic-fee override logic.
```

Both `SafeSwapRouter` and `SafeSwapNft` are `BondRouteProtected`. Shared primitives (pool-key building, fee math, the swap
simulator, ChainConfig wiring, types, constants) live under `contracts/Common/`. Both contracts forward their BondRoute
signing-info calls to one immutable descriptor, keeping dynamic string and price/liquidity math out of their runtimes.

**`donate` is removed**, not relabeled: the rebate is a native dynamic fee, so there is no bonded donate and the hook does not
request the `beforeDonate` permission. Pools still accept permissionless `PoolManager.donate` (a harmless V4 primitive that
credits in-range LPs) — SafeSwap simply does not mediate it.

## Why the hook address encodes the config

A V4 `PoolId = hash(token0, token1, fee, tickSpacing, hooks)` includes the hook address. SafeSwap uses that directly: each
`(base fee, capture)` profile gets its own hook address, hence its own `PoolId`. This avoids smuggling the profile into
`tickSpacing` and avoids letting the first pool initializer lock a profile for everyone wanting the same plain parameters.

Pools are initialized with the V4 dynamic-fee flag — the base fee does **not** live in `PoolKey.fee`:

```solidity
PoolKey.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
```

The base fee and the capture share are read from the hook address; the hook returns `base fee + repricing fee` as a V4
override fee (`LPFeeLibrary.OVERRIDE_FEE_FLAG | swapFeePips`) in `beforeSwap`. `100 V4 fee pips = 1 bps`.

## Hook address format (BCD, self-describing)

The clone's CREATE2 address carries the economics as readable binary-coded decimal in its top bytes, with the V4 permission
bitmap in its low 14 bits:

```
0x F d2 d1 d0 C r 0 ....(free salt)…. PPPP
   │ └──┬───┘ │ └┬┘                  └─ low 14 bits: V4 hook permission bitmap
   │    │     │  └─ capture digits → 10·r + 0              (0..90, forced 10% steps)
   │    │     └──── capture marker 0xC
   │    └────────── 3 base-fee digits → base_fee_bps = 100·d2 + 10·d1 + d0   (0..999 → 0.00%..9.99%)
   └─────────────── fee marker 0xF  (also marks the address as a SafeSwap config hook)
```

Decode (lives in `contracts/Common/HookAddress.sol`): assert `digit0 == 0xF`, `digit4 == 0xC`, every data nibble `≤ 9`, and
the capture ones digit is exactly zero; then `base_fee_bps = 100·d2 + 10·d1 + d0` and `capture_percent = 10·r`. `0xF` and
`0xC` are both `> 9`, so a marker can never be confused with a data digit and the address self-parses. Examples:
`0xF030C50…` → base 0.30%, capture 50%; `0xF150C90…` → base 1.50%, capture 90%.

**Base fee is open** (any whole bps ≤ 9.99%); **capture is quantized** to 10% steps and capped at 90% (see
`LVR_DETERRENCE.md` §4–6). Fragmentation is rate-limited by *real friction*, not a governance allowlist: every profile must be
GPU-vanity-mined, deployed, registered, and seeded by a first LP. ~42 bits to mine (28 config + 14 permission), one-time per
profile, practical as a protocol-deployment operation on a modern GPU.

### Required V4 permissions

`REQUIRED_PERMISSIONS = 0x2A80` = `beforeInitialize | beforeAddLiquidity | beforeRemoveLiquidity | beforeSwap`. `beforeDonate`
is intentionally **not** requested. The low 14 bits of every clone address must equal this exactly.

## Registry

Deployment is permissionless; *usage* is registry-gated. After deploying a clone, the deployer calls `initialize_once()` on
it, which calls `SafeSwapRouter.register_hook(base_fee_bps, rebate_percent)` with `msg.sender = the clone`. Registration binds
three independent proofs:

```
1. runtime codehash  == approved clone-stub codehash   (published in ChainConfig under SAFESWAP_HOOK_CODEHASH_KEY)
2. address BCD config decodes to the submitted (base_fee_bps, rebate_percent)
3. address low 14 bits == REQUIRED_PERMISSIONS
```

Registry shape (`contracts/Router/HookRegistry.sol`):

```solidity
mapping(uint256 => address) public hookByConfig;     // key = (base_fee_bps << 8) | rebate_percent
mapping(address => bool)    public registeredHook;
function get_hook(uint16 base_fee_bps, uint8 rebate_percent) external view returns (address);
```

Users and the NFT pass `(base_fee_bps, rebate_percent)`, never raw hook addresses; the router resolves the clone.

### Why codehash, not self-identification

Authorize by **exact runtime codehash** of `msg.sender`, never by `isSafeSwapHook()`-style self-identification or `tx.origin`.
An EIP-7702 delegated EOA's code is the `0xef0100 || delegate` designator, whose hash never equals the clone-stub codehash, so
exact-codehash matching rejects it. The approved codehash is the EIP-1167 clone stub's (the `SafeSwapHookImpl` address
baked in), so an approved hook provably delegatecalls the implementation.

> **Status:** the `SafeSwapHookProxy` (EIP-1167 stub) is not yet a contract in the repo — only the impl exists. The test
> harness synthesizes a clone with the standard EIP-1167 runtime via `vm.etch` (see `test/helpers/SafeSwapRealEnv.t.sol`). A
> deploy script must produce the stub initcode and publish its codehash before mainnet.

## Hook implementation (config-from-address, no per-clone storage)

`SafeSwapHookImpl` holds `PoolManager`, `SafeSwapRouter`, and `SafeSwapNft` as immutables read from ChainConfig at deploy. The
economics are decoded from `address(this)` (the clone) on every call — no per-clone storage, no constructor decode — so every
clone shares one runtime codehash (what the registry approves). Gating:

```
beforeSwap                                  ⇒ sender == SafeSwapRouter
beforeInitialize / before{Add,Remove}Liquidity ⇒ sender == SafeSwapNft
all callbacks                               ⇒ msg.sender == PoolManager
```

A `_require_clone_context()` guard reverts if `address(this) == IMPLEMENTATION_SELF`, so direct calls to the implementation
(which carry no valid F/C config) are rejected; the impl is non-upgradeable and non-`selfdestruct`, so the clones' hardcoded
target is permanent.

## V4 position ownership & NFT metadata

The user owns the NFT `tokenId`; `SafeSwapNft` executes the V4 liquidity actions and owns the V4 position with `salt =
bytes32(tokenId)`. This keeps all positions under one canonical executor rather than spread across hook addresses. Metadata
stored per position (immutable, cheap to render and verify):

```solidity
struct SafeSwapPositionInfo {
    address hook; IERC20 token0; IERC20 token1;
    uint16 base_fee_bps; uint8 rebate_percent;     // derivable from hook; stored for cheap display/verification
    int24 tick_spacing; int24 tick_lower; int24 tick_upper;
}
```

## Permissionless deployment flow

```
1. Choose base_fee_bps and capture_percent.
2. GPU-mine a CREATE2 salt for a clone address with the F/d/d/d/C/r/0 config nibbles and REQUIRED_PERMISSIONS low bits.
3. CREATE2-deploy the EIP-1167 clone of the SafeSwapHookImpl.
4. Call clone.initialize_once() → router.register_hook(base_fee_bps, capture_percent).
5. Router validates codehash + address config + permissions, then records the clone.
6. Users create positions and swap via (base_fee_bps, capture_percent) through the router/NFT.
```

## Security rules

Required: runtime-codehash allowlist for registration; address-config validation; V4 permission validation; router/NFT-owned
public workflow; NFT ownership/approval checks for tokenId actions. Never authorize by `tx.origin`, interface
self-identification, address prefix alone, delegate target, or a user-supplied hook address alone. **Address bits prove
config; runtime codehash proves behavior; the registry binds both.**
