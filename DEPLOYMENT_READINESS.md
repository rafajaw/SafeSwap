# SafeSwap Deployment Readiness

Date: 2026-06-06

This is the release-level checklist. Implementation history stays in `TODO.md`; this file answers whether the current
router + NFT + config-hook system is ready for a target-chain deployment.

## Current Verdict

**Not ready for target-chain deployment yet.**

The core mechanism and active local suite are mature. The NFT signing-size blocker and signing execution-parity review are
resolved, but setup blockers remain:

1. Deployment/mining/config tooling does not exist yet.
2. `CONFIG_SIGNER`, target chains, canonical addresses, and initial pools are not finalized.
3. Deployed-address fork coverage, documentation refresh, and external audit remain open.

## Current Architecture

```
SafeSwapRouter
  BondRoute-protected exact-input/output swaps
  hook registry and profile resolution
  protocol-fee treasury

SafeSwapNft
  BondRoute-protected create/add/remove/collect lifecycle
  ERC721 ownership
  owns every V4 position; salt = tokenId

SafeSwapHookImpl
  immutable implementation
  deploys canonical EIP-1167 config clones via CREATE2
  each clone address encodes base fee + capture profile + exact V4 permission bits

SafeSwapPositionDescriptor
  external on-chain tokenURI/contractURI renderer

SafeSwapSigningDescriptor
  external immutable REFERENCE_2 renderer
  shared by router and NFT through one ChainConfig address
  keeps signing strings and price/liquidity math out of both runtimes
```

Pools are Uniswap V4 **dynamic-fee** pools. SafeSwap has no bonded `donate` action. Repricing capture is delivered as a native
dynamic LP fee. Protocol fees accrue to `SafeSwapRouter` and are withdrawn by the two-step treasury role.

## P0: Code and Review

### Router and NFT Deployability: Resolved

The canonical BondRoute signing ABI remains unchanged. Both `BondRoute_get_signing_info` surfaces forward to one immutable
`SafeSwapSigningDescriptor` configured through ChainConfig. Each router/NFT ABI adds a `SigningDescriptor` getter.

Measured runtime sizes:

| Revision/profile | Runtime size | EIP-170 margin |
| --- | ---: | ---: |
| Pre-signing `fe1d68f`, 25,000 runs | 24,462 bytes | +114 |
| Pre-fix NFT, 10,000 runs | 33,018 bytes | -8,442 |
| Current NFT, 10,000 runs | 24,075 bytes | +501 |
| Pre-fix router, 25,000 runs | 24,369 bytes | +207 |
| Current router, 25,000 runs | 19,471 bytes | +5,105 |
| Current signing descriptor, 10,000 runs | 17,141 bytes | +7,435 |
| Current descriptor, 1,000 runs | 24,284 bytes | +292 |

Existing router and NFT signing tests pass through the forwarding boundary and preserve typed strings, struct hashes,
offsets, token-metadata behavior, and unsupported-call reverts.

### Complete Signing Review

Review all six protected actions:

- exact-input swap;
- exact-output swap;
- create position;
- add liquidity;
- remove liquidity;
- collect fees.

For each action, prove:

- decoded signed parameters are the parameters that execute;
- every economically relevant raw parameter changes a committed typed/display value;
- operators (`=`, `<=`, `>=`) match execution semantics;
- token symbols are sanitized display labels, while token addresses remain typed anchors;
- pool/range/price values use the same orientation and derivation as execution;
- `protocol` and token addresses are treated as the trust anchors;
- forwarded helper calls cannot be redirected or upgraded.

## P1: Deployment and Configuration

### Build Tooling

`script/` currently contains only the NFT example renderer. Add:

- off-chain CREATE2 salt miner for the BCD profile bits plus exact V4 permission bits (about 38 constrained bits);
- deployment scripts for descriptor/signing helper, router, NFT, hook implementation, and per-profile hook clones;
- `deploy_hook` success plus `CONFIG_MISMATCH` / `PERMISSIONS` integration paths;
- publication of the canonical clone runtime codehash;
- ChainConfig write/check tooling;
- deployment artifact generation and explorer-verification commands;
- idempotent dry-run and post-deploy verification.

The artifact must record chain id, deployer, salt, init-code hash, runtime hash, deployed address, compiler version,
optimizer profile, `via_ir`, dependency commits, ChainConfig values, and transaction hashes.

### Replace and Document `CONFIG_SIGNER`

- Replace `0xDeaDbeef...` in `contracts/Common/Definitions.sol`.
- Decide multisig/hardware-backed control and rotation policy.
- Archive every signed ChainConfig write.
- Keep config authority separate from the operational treasury.

### Publish ChainConfig in Dependency Order

For every launch chain, verify ChainConfig, BondRoute, Cancun/transient-storage support, and canonical V4 PoolManager, then
publish/archive:

- `uniswap_v4/pool_manager`;
- `safeswap/initial_treasury`;
- `safeswap/router`;
- `safeswap/nft`;
- `safeswap/hook_codehash`;
- `safeswap/position_descriptor`;
- `safeswap/signing_descriptor`.

The deployment script must encode and enforce the actual constructor/dependency order.

## P2: Integration and SDK

### Target-Chain Fork Coverage

Against deployed canonical infrastructure:

- verify BondRoute and ChainConfig runtime-bytecode parity with pinned dependencies;
- execute ERC20 and native ETH swaps;
- execute create/add/remove/collect position flows;
- verify native escrow/refund behavior and timing limits;
- verify router, NFT, descriptor, implementation, clone codehash, BCD profile, and V4 permissions;
- verify protocol fees reach the router and treasury withdrawals work.

### SDK

- [x] Implement the BondRoute message-values path for REFERENCE_2.
- [x] Test all six actions against on-chain `BondRoute_get_signing_info` and descriptor-exported values.
- Populate canonical router/NFT addresses only after deterministic deployment artifacts are final.
- Update SDK docs for profile selection, NFT ownership, signing trust anchors, and target-chain support.

## P3: Launch Policy

Before selecting a launch chain/pool:

- confirm Cancun/transient-storage support and canonical V4 availability;
- define supported token behavior as V4-compatible assets only;
- select deep initial pools and exclude thin/manipulable pools;
- calibrate 1% bond stake assumptions by chain, volatility, depth, gas, and expected MEV;
- decide initial base-fee/capture profiles and mine only those salts;
- define frontend/indexer rejection rules before bond creation;
- document NFT/V4 custody: user owns the NFT; `SafeSwapNft` owns the V4 position; lifecycle execution uses BondRoute;
- document migration and incident-response policy for immutable, unpausable contracts.

## P4: Release Verification

- Run full Foundry suite from a clean build.
- Run SDK tests and production build.
- Check every deploy profile against EIP-170/EIP-3860.
- Refresh gas benchmarks after signing extraction and deployment architecture changes.
- Run Slither and triage direct findings separately from dependency noise.
- Reconcile `README.md`, `AUDIT_REPORT.md`, architecture docs, SDK docs, test counts, size tables, fee custody, and deployment
  claims with the final code.
- Prepare external-audit scope covering BondRoute semantics, signing commitments, V4 callbacks/settlement, dynamic-fee math,
  hook registration/deployment, NFT accounting, native ETH, treasury, and deterministic configuration.
- Rehearse deployment, verification, ChainConfig writes, hook mining/registration, pool initialization, and rollback/migration
  communications on a testnet or fork.

## Setup/Deploy Entry Criteria

- [x] `SafeSwapNft` and the new signing helper fit deployment size limits.
- [x] Signing execution-parity review is complete.
- [x] Full contract and SDK suites pass.
- [ ] Deploy/mining/config/artifact tooling is complete and dry-run tested.
- [ ] `CONFIG_SIGNER` and treasury control are documented.
- [ ] Target-chain infrastructure and EVM features are verified.
- [ ] All ChainConfig entries are published and archived.
- [ ] Canonical deployed-address fork tests pass, including native ETH.
- [ ] Initial chains, pools, tokens, and capture profiles are approved.
- [ ] Stake economics and user-risk documentation are published.
- [ ] Public docs and SDK addresses match final deployments.
- [ ] Static-analysis triage and external audit are complete.

## Next Work

1. Keep signing golden vectors synchronized with any action-parameter change.
2. Build deployment, salt-mining, ChainConfig, and artifact tooling.
3. Choose signer, launch chain, initial pools, and profile set.
4. Add deployed-address fork coverage; SDK message values are complete and digest-verified.
5. Refresh docs, benchmarks, static analysis, and audit materials.
