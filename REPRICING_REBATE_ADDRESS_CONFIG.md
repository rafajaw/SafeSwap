# SafeSwap Repricing Rebate Architecture

## Decision

SafeSwap should use a canonical router, a shared NFT, and many permissionlessly deployed hook config instances.

```text
SafeSwapRouter
  user-facing entrypoint
  BondRoute-protected execution surface
  hook config registry
  PoolKey construction
  LP and swap dispatch

SafeSwapNft
  durable ERC721 LP position registry
  position ownership and approvals
  immutable display metadata

SafeSwapHook
  Uniswap v4 hook callbacks
  dynamic fee override logic
  one deployed instance per base-fee / rebate-profile pair
  same runtime bytecode for every config instance
```

The router is the contract users and integrators normally touch. The NFT is the durable record of LP positions. Hooks are protocol execution modules selected by config.

This model gives:

```text
one normal user-facing address
one shared NFT covering all SafeSwap pools
many fee/rebate markets without deploying many NFT contracts
permissionless hook deployment
no first-LP rebate lock across unrelated profiles
no per-position fee/rebate accounting
```

## Why Hooks Encode Config

Uniswap v4 pool identity includes the hook address:

```text
PoolId = hash(token0, token1, fee, tickSpacing, hooks)
```

SafeSwap uses that property directly. Each economic profile gets its own hook address, so each profile gets its own `PoolId`.

For example:

```text
TOKEN0/TOKEN1
dynamic fee
tickSpacing = 60
hook = profile(baseFeeBps = 30, rebateProfile = 5)
```

is a different v4 pool from:

```text
TOKEN0/TOKEN1
dynamic fee
tickSpacing = 60
hook = profile(baseFeeBps = 30, rebateProfile = 8)
```

This avoids encoding the rebate in `tickSpacing` and avoids letting the first pool initializer lock the rebate profile for everyone who wanted the same normal pool parameters.

## Dynamic Fee Requirement

SafeSwap repricing rebates need to affect the swap that causes the repricing event. The pool should therefore be initialized with the v4 dynamic fee flag:

```solidity
PoolKey.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
```

The base fee is not stored in `PoolKey.fee`. It is part of the SafeSwap hook config.

The hook computes:

```text
swap fee = base LP fee + repricing fee
```

and returns a v4 override fee:

```solidity
LPFeeLibrary.OVERRIDE_FEE_FLAG | swapFee;
```

`baseFeeBps` is converted to v4 fee units as:

```solidity
uint24 baseFeeUnits = uint24(baseFeeBps) * 100;
```

because:

```text
100 v4 fee units = 1 bps
```

## Hook Address Format

Hook addresses are mined with CREATE2.

Proposed address layout:

```text
0x55        SafeSwap magic byte
8 bits      baseFeeBps
4 bits      rebateProfile
free bits   salt entropy
14 bits     Uniswap v4 hook permission flags
```

`0x55` marks the address as a SafeSwap config hook.

`baseFeeBps` is the normal LP fee:

```text
1   = 0.01%
5   = 0.05%
30  = 0.30%
100 = 1.00%
```

`rebateProfile` is a coarse share of the repricing movement:

```text
0 = 0%
1 = 10%
2 = 20%
3 = 30%
4 = 40%
5 = 50%
6 = 60%
7 = 70%
8 = 80%
9 = 90%
```

Profiles `10..15` are reserved.

The low 14 bits must also satisfy the Uniswap v4 hook permission bitmap. For SafeSwap, the expected permissions are:

```text
beforeInitialize
beforeAddLiquidity
beforeRemoveLiquidity
beforeSwap
beforeDonate
```

The deployment tool mines a salt until both the SafeSwap prefix/config bits and the v4 permission suffix are correct.

## Hook Constructor

The hook constructor decodes its config from `address(this)`:

```solidity
uint160 self = uint160(address(this));
```

It validates:

```text
magic == 0x55
baseFeeBps is supported
rebateProfile <= 9
low 14 bits match required SafeSwap hook permissions
PoolManager address is valid
SafeSwapRouter address is valid
SafeSwapNft address is valid
```

It stores decoded config in normal storage:

```solidity
uint8 public baseFeeBps;
uint8 public rebateProfile;
```

Do not use immutables for these config values. If the values are immutables, runtime bytecode changes per config. Keeping them in storage lets every config instance share the same runtime bytecode, which makes runtime-codehash authorization useful.

## Hook Registration

Deployment is permissionless, but usage is registry-gated.

After deployment, the hook calls:

```solidity
function initialize_once() external {
    SAFE_SWAP_ROUTER.register_hook(baseFeeBps, rebateProfile);
}
```

The router registers `msg.sender` only if all checks pass:

```text
msg.sender has an approved SafeSwap hook runtime codehash
address magic/config bits match submitted baseFeeBps and rebateProfile
address low bits match required v4 hook permissions
profile is allowed
registry entry is empty or already msg.sender
```

Registry shape:

```solidity
mapping(uint16 => address) public hookByConfig;
mapping(address => bool) public registeredHook;
```

Config key:

```solidity
uint16 key = (uint16(baseFeeBps) << 4) | uint16(rebateProfile);
```

Registration sketch:

```solidity
function register_hook(uint8 baseFeeBps, uint8 rebateProfile) external {
    _requireApprovedHookRuntime(msg.sender);
    _requireAddressConfigMatches(msg.sender, baseFeeBps, rebateProfile);
    _requireHookPermissions(msg.sender);

    uint16 key = _hookConfigKey(baseFeeBps, rebateProfile);
    address existing = hookByConfig[key];

    if (existing != address(0) && existing != msg.sender) {
        revert HookConfigAlreadyRegistered(key, existing);
    }

    hookByConfig[key] = msg.sender;
    registeredHook[msg.sender] = true;
}
```

The router is the canonical resolver:

```solidity
function get_hook(uint8 baseFeeBps, uint8 rebateProfile) external view returns (address hook);
```

Normal users pass `baseFeeBps` and `rebateProfile`, not hook addresses.

## Codehash Authentication

Do not authorize callers through interface self-identification:

```solidity
ISafeSwapHook(msg.sender).isSafeSwapHook()
```

An EIP-7702 delegated EOA can execute delegated hook code and return hook-like answers.

The authorization primitive is exact runtime codehash of `msg.sender`:

```solidity
function _requireApprovedHookRuntime(address caller) internal view {
    bytes32 codehash;
    assembly {
        codehash := extcodehash(caller)
    }

    if (!approvedHookRuntimeCodehash[codehash]) {
        revert UnauthorizedHookCode(caller, codehash);
    }
}
```

For an EIP-7702 delegated EOA, account code is a delegation designator:

```text
0xef0100 || delegate_address
```

So `EXTCODEHASH` of the EOA is the hash of that short designator, not the hook runtime codehash. Exact codehash authorization rejects it.

Do not use `tx.origin != msg.sender` as the security boundary. The boundary is exact local code authentication of `msg.sender`.

## Router ABI

The router should be the public protocol interface.

Suggested ABI:

```solidity
contract SafeSwapRouter is BondRouteProtected {
    function create_position(CreatePositionParams calldata params) external returns (uint256 tokenId);
    function add_liquidity(AddLiquidityParams calldata params) external;
    function remove_liquidity(RemoveLiquidityParams calldata params) external;
    function collect_fees(CollectFeesParams calldata params) external;

    function swap_exact_input(ExactInputSwapParams calldata params) external;
    function swap_exact_output(ExactOutputSwapParams calldata params) external;
    function donate(DonateParams calldata params) external;

    function register_hook(uint8 baseFeeBps, uint8 rebateProfile) external;
    function get_hook(uint8 baseFeeBps, uint8 rebateProfile) external view returns (address hook);
}
```

Create params stay user-readable:

```solidity
struct CreatePositionParams {
    IERC20 token_a;
    IERC20 token_b;
    uint8 base_fee_bps;
    uint8 rebate_profile;
    int24 tick_spacing;
    int24 tick_lower;
    int24 tick_upper;
    uint128 liquidity;
    uint160 sqrt_price_x96;
    TokenAmount minimum_deposited_a;
    TokenAmount minimum_deposited_b;
}
```

The router resolves the hook:

```solidity
address hook = hookByConfig[_hookConfigKey(params.base_fee_bps, params.rebate_profile)];
if (hook == address(0)) {
    revert HookConfigNotRegistered(params.base_fee_bps, params.rebate_profile);
}
```

Then it builds the pool key:

```solidity
PoolKey({
    currency0: Currency.wrap(address(token0)),
    currency1: Currency.wrap(address(token1)),
    fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
    tickSpacing: params.tick_spacing,
    hooks: IHooks(hook)
});
```

Follow-up LP actions should be token-id based:

```solidity
struct AddLiquidityParams {
    uint256 token_id;
    uint128 liquidity;
    TokenAmount minimum_deposited_a;
    TokenAmount minimum_deposited_b;
}

struct RemoveLiquidityParams {
    uint256 token_id;
    uint128 liquidity;
    TokenAmount minimum_received_a;
    TokenAmount minimum_received_b;
}

struct CollectFeesParams {
    uint256 token_id;
    TokenAmount minimum_received_a;
    TokenAmount minimum_received_b;
}
```

The router loads the NFT metadata for token-id actions and reconstructs the `PoolKey`.

## NFT ABI

The NFT should be a registry, not the main UX surface.

Suggested ABI:

```solidity
contract SafeSwapNft is ERC721 {
    function mint_position(address owner, SafeSwapPositionInfo calldata info) external returns (uint256 tokenId);
    function get_lp_position(uint256 tokenId) external view returns (SafeSwapPositionInfo memory info);
    function is_position_authorized(uint256 tokenId, address user) external view returns (bool);
}
```

The clean default is:

```text
only the canonical router mints
only the canonical router mutates v4 liquidity for token-id actions
NFT checks ownership/approval
```

If hooks ever call the NFT directly, the NFT must use the same exact runtime-codehash checks as the router. Prefer avoiding that unless implementation constraints require it.

## Position Metadata

The NFT must store hook identity because hook identity is part of the pool.

Recommended metadata:

```solidity
struct SafeSwapPositionInfo {
    address hook;
    IERC20 token0;
    IERC20 token1;
    uint8 base_fee_bps;
    uint8 rebate_profile;
    int24 tick_spacing;
    int24 tick_lower;
    int24 tick_upper;
}
```

`base_fee_bps` and `rebate_profile` are derivable from `hook`, but storing them makes metadata immutable, cheap to render, and easy to verify.

The NFT can display:

```text
Pair: TOKEN0/TOKEN1
Base fee: 0.30%
Repricing rebate: 50%
Tick spacing: 60
Hook: 0x55...
```

## V4 Position Ownership

Target invariant:

```text
SafeSwap user owns NFT tokenId
SafeSwap router executes v4 liquidity actions
v4 position salt is derived from tokenId
NFT metadata records the hook/config/pool parameters
```

Recommended salt:

```solidity
bytes32 salt = bytes32(tokenId);
```

This keeps v4 positions under one canonical executor instead of spreading position ownership across many hook config addresses.

If implementation later requires the NFT to be the direct `PoolManager.modifyLiquidity` caller, that is still compatible with the model. The important part is that hooks should not become the user-facing LP position owner by default.

## Permissionless Deployment Flow

1. Choose:

```text
baseFeeBps
rebateProfile
required hook permission flags
```

2. Mine a CREATE2 salt for an address satisfying:

```text
0x55 SafeSwap magic
encoded baseFeeBps
encoded rebateProfile
required v4 hook low bits
```

3. Deploy the standard audited SafeSwap hook initcode.

4. Constructor decodes and stores config from `address(this)`.

5. Call:

```solidity
hook.initialize_once();
```

6. Hook calls router registration.

7. Router validates codehash, address config, and v4 hook flags.

8. Users can create positions using `(baseFeeBps, rebateProfile)` through the router.

## Security Rules

Required:

```text
runtime-codehash allowlist for hook registration
address config validation
v4 hook permission validation
router-owned public workflow
NFT ownership/approval checks for token-id actions
```

Do not authorize hooks by:

```text
tx.origin
interface self-identification
address prefix alone
delegate target
user-supplied hook address alone
```

Address bits prove config. Runtime codehash proves behavior. The router registry binds both.

## Open Questions

1. Should v4 liquidity actions be executed by the router or by the NFT?

2. Should approved runtime hashes live directly in the router, or be read from `ChainConfig`?

3. Should `baseFeeBps` be an allowlist of known values or any nonzero `uint8`?

4. Should `rebateProfile = 10` eventually mean 100%, or remain reserved?

5. How should exact-output swap quoting handle dynamic repricing fees before execution?

## Summary

SafeSwap should use address-configured hook instances plus a router registry.

The hook address selects the economic profile and creates a unique v4 `PoolId`. The router resolves configs, enforces code authenticity, and remains the normal user interface. The NFT stores the durable LP position record across all pools and configs.

This gives configurable repricing rebates without tick-spacing abuse, per-position fee bookkeeping, or deploying many protocol frontends.
