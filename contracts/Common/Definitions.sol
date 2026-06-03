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
// When a swap moves the pool price, the pool charges an additional LP fee equal to a share of the repricing SURPLUS the swap
// extracts, and pays it to the LPs the swap crossed. It is a native Uniswap V4 dynamic fee that accrues per swap step, so it
// compensates LPs in proportion to the volume they served across the move. The hook estimates the surplus before the swap
// (via SwapSimulator) and returns an override fee:
//
//     swap fee (pips)  = base LP fee + repricing fee
//     repricing fee    = capture% × surplus, expressed as a flat rate over the input:
//                        repricing_pips = min( capture% × surplus / amount_in × 1e6, MAX_REPRICING_FEE_PIPS )
//     surplus          = (output valued at the post-swap price) − input paid   (input-token units, ≥ 0)
//
// capture% (the hook address's "C" digit, 0..90) is the share of SURPLUS paid to LPs — NOT a rate on price displacement.
// Charging a rate on displacement over-captures by ~2× (a rate hits the whole input; the surplus is only the price-impact
// triangle). See DYNAMIC_FEE_REBATE_PLAN.md / LVR_DETERRENCE.md §4.

uint256 constant BPS_DENOMINATOR            =   10_000;
uint256 constant PERCENT_DENOMINATOR        =   100;        // capture is a percent, so divide by 100.
uint256 constant PIPS_PER_BPS               =   100;        // Uniswap V4 fee units: 1_000_000 = 100%, so 1 bps = 100 pips.
uint256 constant PIPS_PER_PERCENT           =   10_000;     // 1_000_000 pips / 100 percent: converts capture% × (surplus/in) → pips.

// *NOTE*  -  Upper bound on the repricing component of the swap fee, in V4 pips (a share of the swapped amount). Bounds UX and
//            edge-case risk on violent repricing. Tunable; a single global cap is intentional for v1 simplicity.
uint24  constant MAX_REPRICING_FEE_PIPS     =   100_000;    // 10% of the swapped amount.

// *SECURITY*  -  Hard ceiling on the total override fee. Must stay below Uniswap V4's MAX_SWAP_FEE (1_000_000), otherwise a
//                100% fee would make exact-output swaps impossible (the input is entirely consumed by the fee).
uint24  constant MAX_TOTAL_FEE_PIPS         =   500_000;    // 50%.


// *NOTE*  -  The hook address encoding (base fee + capture markers, shifts, permission bits) and its decoder live in the
//            hook-specific `HookAddress` library (contracts/Hook/HookAddress.sol), not here.


// ━━━━  BONDROUTE EXECUTION POLICY  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

uint256 constant MIN_BOND_EXECUTION_DELAY_IN_BLOCKS   =   3;            // 3-block head-start against reorg and frontrunning bots.
uint256 constant MIN_BOND_EXECUTION_DELAY_IN_SECONDS  =   2 seconds;    // Relevant on chains where 3 blocks pass faster than mempool propagation.
uint256 constant MAX_BOND_EXECUTION_DELAY_IN_SECONDS  =   1 hours;      // Caps opportunistic execution.


// ━━━━  STRINGS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

string constant SAFESWAP_PROTOCOL_NAME                  =  "SafeSwap";
string constant SAFESWAP_PROTOCOL_DESCRIPTION           =  "Trustless MEV-protected Uniswap pools with LP repricing rebates";

string constant SAFESWAP_POSITIONS_NAME                 =  "SafeSwap Positions";
string constant SAFESWAP_POSITIONS_DESCRIPTION          =  "Trustless MEV-protected Uniswap LP positions";

string constant SWAPS_REQUIRE_EXACTLY_ONE_FUNDING       =  "Swaps require exactly 1 funding";
string constant ADD_LIQUIDITY_REQUIRES_TWO_FUNDINGS     =  "Add liquidity requires exactly 2 fundings";
string constant REMOVE_LIQUIDITY_REQUIRES_NO_FUNDINGS   =  "Remove liquidity requires 0 fundings";
string constant MODIFY_LIQUIDITY_CREATE_REQUIRES_TWO_FUNDINGS  =  "Modify liquidity create or increase requires exactly 2 fundings";
string constant MODIFY_LIQUIDITY_REMOVE_REQUIRES_NO_FUNDINGS    =  "Modify liquidity remove or collect requires 0 fundings";
string constant DONATE_REQUIRES_TWO_FUNDINGS            =  "Donate requires exactly 2 fundings";
string constant TOKENS_MUST_BE_DIFFERENT                =  "Tokens must be different";
