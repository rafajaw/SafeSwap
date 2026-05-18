// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;


// ━━━━  EXTERNAL AUTHORITIES  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

// *PLACEHOLDER*  -  Replace with the canonical SafeSwap protocol config-signer address before mainnet deploy.
// Keyspace under which the PoolManager (and other chain-scoped) entries must be signed in ChainConfig.
// Decoupled from the operational fee collector so each role can rotate independently.
address constant CONFIG_SIGNER  =  0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF;  // ***TODO*** - Fix before deployment!
bytes32 constant POOL_MANAGER_KEY       =  bytes32("uniswap_v4/pool_manager");
bytes32 constant INITIAL_COLLECTOR_KEY  =  bytes32("safeswap/initial_collector");


// ━━━━  SAFESWAP POLICY  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

uint256 constant SWAP_STAKE_PERCENTAGE              =   1;
uint256 constant LIQUIDITY_STAKE_PERCENTAGE         =   1;          // Applied to total normalized value, denominated in token0.

uint256 constant MIN_EXECUTION_DELAY_IN_BLOCKS      =   3;

uint256 constant MAX_EXECUTION_DELAY                =   1 hours;

uint256 constant PROTOCOL_FEE_DIVISOR               =   10_000_000; // E.g. 0.3% pool: LPs get full 0.3%, SafeSwap takes 0.03% from output.
uint256 constant MIN_PROTOCOL_FEE_RATE              =   1000;       // 0.01% floor when pool LP fee < 0.10%.


// ━━━━  STRINGS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

string constant SAFESWAP_PROTOCOL_NAME                  =  "SafeSwap";
string constant SAFESWAP_PROTOCOL_DESCRIPTION           =  "MEV-protected Uniswap pools";

string constant SWAPS_REQUIRE_EXACTLY_ONE_FUNDING       =  "Swaps require exactly 1 funding";
string constant ADD_LIQUIDITY_REQUIRES_TWO_FUNDINGS     =  "Add liquidity requires exactly 2 fundings";
string constant REMOVE_LIQUIDITY_REQUIRES_NO_FUNDINGS   =  "Remove liquidity requires 0 fundings";
string constant DONATE_REQUIRES_TWO_FUNDINGS            =  "Donate requires exactly 2 fundings";
string constant TOKENS_MUST_BE_DIFFERENT                =  "Tokens must be different";
