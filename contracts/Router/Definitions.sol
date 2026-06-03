// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;


// ━━━━  EXTERNAL AUTHORITIES  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

// *PLACEHOLDER*  -  Replace with the canonical SafeSwap protocol config-signer address before mainnet deploy.
// Keyspace under which the PoolManager (and other chain-scoped) entries must be signed in ChainConfig.
// Decoupled from the operational protocol treasury so each role can rotate independently.
address constant CONFIG_SIGNER  =  0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF;  // ***TODO*** - Fix before deployment!
bytes32 constant POOL_MANAGER_KEY        =  bytes32("uniswap_v4/pool_manager");
bytes32 constant INITIAL_TREASURY_KEY    =  bytes32("safeswap/initial_treasury");
bytes32 constant SAFESWAP_ROUTER_KEY     =  bytes32("safeswap/router");
bytes32 constant SAFESWAP_NFT_KEY        =  bytes32("safeswap/nft");
bytes32 constant SAFESWAP_HOOK_CODEHASH_KEY  =  bytes32("safeswap/hook_codehash");


// ━━━━  SAFESWAP ECONOMICS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

uint256 constant SWAP_STAKE_PERCENTAGE              =   1;

// *NOTE*  -  Applied to the TOTAL value across both legs of the bond, normalized to token0 at slot0. Posted in token0 only.
//            Example: 100 USDC + 100 USDT in a 1:1 pool is total value 200 → 1% = 2 USDC stake (assuming USDC is token0).
uint256 constant LIQUIDITY_STAKE_PERCENTAGE         =   1;

uint256 constant PROTOCOL_FEE_DIVISOR               =   10_000_000; // E.g. 0.3% pool: LPs get full 0.3%, SafeSwap takes 0.03% from output.
uint256 constant MIN_PROTOCOL_FEE_RATE              =   1000;       // 0.01% floor when pool LP fee < 0.10%.


// ━━━━  LP REPRICING REBATE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//
// When a swap moves the pool price, SafeSwap charges an additional fee proportional to that price movement and rebates it to
// the LPs of the pool. The fee is measured from the REAL tick movement of the executed swap and donated back to in-range LPs.
//
//     repricing rebate fee = pool price movement caused by the swap × rebate share
//
// The rebate share is selected by a discrete profile. Each profile maps to a share in basis points:
//
//     rebate_bps = rebate_profile × REBATE_PROFILE_BPS_STEP    →    0%, 10%, 20%, … 100%
//

uint256 constant BPS_DENOMINATOR              =   10_000;
uint8   constant MAX_REBATE_PROFILE           =   10;       // Profile 10 = 100%. Profiles 11..15 are reserved (4-bit field).
uint256 constant REBATE_PROFILE_BPS_STEP      =   1000;     // profile × 1000 bps  →  profile 5 = 5000 bps = 50%.

// *NOTE*  -  Upper bound on the extra fee charged for a single swap, as a share of the swapped amount. Bounds UX and edge-case
//            risk on violent repricing. Tunable per the LVR playbook; a single global cap is intentional for v1 simplicity.
uint256 constant MAX_REPRICING_REBATE_BPS     =   1000;     // 10% of the swapped amount.


// ━━━━  SAFESWAP HOOK ADDRESS CONFIG  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//
// Each rebate profile is served by its own permissionlessly-deployed SafeSwapHook instance. The economic profile is encoded in
// the hook's CREATE2 address so that each profile yields a distinct Uniswap V4 PoolId for otherwise-identical pool parameters.
//
// Address bit layout (160 bits):
//     bits [152..159]  magic byte (0x55)            marks the address as a SafeSwap config hook
//     bits [148..151]  rebate_profile (4 bits)      coarse repricing rebate share
//     bits [ 14..147]  free salt entropy
//     bits [  0.. 13]  Uniswap V4 hook permission bitmap
//
// The base LP fee is NOT encoded in the hook address: SafeSwap pools are static-fee, so the base fee lives in PoolKey.fee and
// a single hook instance per rebate profile serves every base-fee tier.

uint8   constant SAFESWAP_HOOK_ADDRESS_MAGIC          =   0x55;
uint256 constant HOOK_ADDRESS_MAGIC_SHIFT             =   152;
uint256 constant HOOK_ADDRESS_REBATE_PROFILE_SHIFT    =   148;
uint160 constant HOOK_ADDRESS_REBATE_PROFILE_MASK     =   0xF;
uint160 constant HOOK_PERMISSIONS_MASK                =   0x3FFF;     // (1 << 14) - 1, matches Hooks.ALL_HOOK_MASK.

// beforeInitialize | beforeAddLiquidity | beforeRemoveLiquidity | beforeSwap | beforeDonate
//   = (1<<13) | (1<<11) | (1<<9) | (1<<7) | (1<<5)
uint160 constant REQUIRED_HOOK_PERMISSIONS            =   0x2AA0;


// ━━━━  BONDROUTE EXECUTION POLICY  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

uint256 constant MIN_BOND_EXECUTION_DELAY_IN_BLOCKS   =   3;            // 3-block head-start against reorg and frontrunning bots.
uint256 constant MIN_BOND_EXECUTION_DELAY_IN_SECONDS  =   2 seconds;    // Relevant on chains where 3 blocks pass faster than mempool propagation.
uint256 constant MAX_BOND_EXECUTION_DELAY_IN_SECONDS  =   1 hours;      // Caps opportunistic execution.


// ━━━━  STRINGS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

string constant SAFESWAP_PROTOCOL_NAME                  =  "SafeSwap";
string constant SAFESWAP_PROTOCOL_DESCRIPTION           =  "Trustless MEV-protected Uniswap pools with LP repricing rebates";

string constant SWAPS_REQUIRE_EXACTLY_ONE_FUNDING       =  "Swaps require exactly 1 funding";
string constant ADD_LIQUIDITY_REQUIRES_TWO_FUNDINGS     =  "Add liquidity requires exactly 2 fundings";
string constant REMOVE_LIQUIDITY_REQUIRES_NO_FUNDINGS   =  "Remove liquidity requires 0 fundings";
string constant MODIFY_LIQUIDITY_CREATE_REQUIRES_TWO_FUNDINGS  =  "Modify liquidity create or increase requires exactly 2 fundings";
string constant MODIFY_LIQUIDITY_REMOVE_REQUIRES_NO_FUNDINGS    =  "Modify liquidity remove or collect requires 0 fundings";
string constant DONATE_REQUIRES_TWO_FUNDINGS            =  "Donate requires exactly 2 fundings";
string constant TOKENS_MUST_BE_DIFFERENT                =  "Tokens must be different";
