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
uint256 constant LIQUIDITY_STAKE_PERCENTAGE         =   2;          // 2x swap rate — only token0 side is measured.

uint256 constant MIN_EXECUTION_DELAY_IN_BLOCKS      =   3;

uint256 constant MAX_SWAP_EXECUTION_DELAY           =   1 hours;
uint256 constant MAX_LIQUIDITY_EXECUTION_DELAY      =   4 hours;

uint256 constant PROTOCOL_FEE_DIVISOR               =   10_000_000; // E.g. 0.3% pool: LPs get full 0.3%, SafeSwap takes 0.03% from output.
uint256 constant MIN_PROTOCOL_FEE_RATE              =   1000;       // 0.01% floor when pool LP fee < 0.10%.
