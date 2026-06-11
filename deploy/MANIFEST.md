# SafeSwap — Deterministic Deployment Manifest

Mined CREATE2 vanity addresses for the SafeSwap core contracts.

## ⚠️ Binding (do not break)

Every `init_code_hash` below — and therefore every mined `salt`/`address` — is bound to the **exact source, file paths, and
compiler settings** at the frozen commit. Because `bytecode_hash = "ipfs"`, even a comment/NatSpec edit or a moved file in a
contract's compile graph changes the init code and **invalidates the mined salt**. Re-mine if any of these change.

- **Frozen commit:** `0362b5d` (mine from this repo, this layout)
- **Compiler:** solc `0.8.35` · `evm_version = cancun` · `via_ir = true` · `bytecode_hash = "ipfs"`
- **CREATE2 factory (deployer):** `0x4e59b44847b379578588920cA78FbF26c0B4956C` (canonical)
- **optimizer_runs:** per deploy profile in `foundry.toml` (router/hook/signing/relayer = 2,000,000,000 · nft = 25,000 · descriptor = 900)

## Core contracts

| Contract | Profile | Prefix | init_code_hash | Salt | Address | Status |
|---|---|---|---|---|---|---|
| `SafeSwapHookImpl` | `deploy_hook` | `0x00000000` | `0x4bcc77fdde9def64916d85ab1b3264d85974481acbdd2ec7e30c6a6c25465cc0` | `0x42d7023178d05bd1f9939994b06e81665eb7d55dfe98315a1afa469ecd40cab9` | `0x00000000818784DDF475b110280562bB35C5c9C1` | ✅ mined |
| `SafeSwapRouter` | `deploy_router` | `0x5afe0000` | `0x8658d19837926012c9bc5839c8377350353eb4e2c60a029d698a5f2fa3c36c63` | `0x02255a85af01f9df1c8ce247c5560d4c389128cc5ebd8ff88fcc603032d868f2` | `0x5AFe000018090552d2C02d2884B0B567601332B2` | ✅ mined |
| `SafeSwapNft` | `deploy_nft` | `0x72100000` | `0x94719e873b349e028bf43927a91adce2ab3e9c6965d95225e673a090a5755270` | `0xc4f36ad9f9af608c2aa1491bdf3315f78fb58e5f49d3cfc30154c44bfd9eae6c` | `0x7210000035EE7a4336516E1a0F2615C55ACFa043` | ✅ mined |
| `SafeSwap7702Delegate` | `deploy_relayer` | `0x77020000` | `0x3ef58488368112f9345f9b7ebf02fcab415902e952ea7bdc54add53179fb272b` | `0x213b55587f82c87c49f164e1f20a87c4c624dd0eeabc1ce348a8c83e8bf78513` | `0x77020000a6eF5B111B27d836403EED4Aa3A39620` | ✅ mined |

## Support contracts (descriptors)

Deployed via the canonical CREATE2 factory `0x4e59b44847b379578588920cA78FbF26c0B4956C` (no-arg constructors; both read
their wiring from ChainConfig). Referenced by the NFT/router by address through ChainConfig, so the vanity prefix is cosmetic.

| Contract | Profile | Prefix | init_code_hash | Salt | Address | Status |
|---|---|---|---|---|---|---|
| `SafeSwapPositionDescriptor` | `deploy_descriptor` | `0x40517107` | `0xc26127604eec8d67a5ddfb8eba024cc04f727e9f950a202d121c2f3387abee6f` | `0x4102a0f4a4778ca3d4842e43cf2cb7eba1802b41ed73251b5e352e98875cf50b` | `0x40517107d4EDFeB11118d3cA1CEf372811d2FBec` | ✅ mined |
| `SafeSwapSigningDescriptor` | `deploy_signing_descriptor` | `0x51571750` | `0xbecaf0eacfeed9de9034c55aa9d37a047f134769ef5665a75ccb82a550f4bc00` | `0x0148c11efc73106004337bf434e1016ad55c6de6057a5c6123f6911cdb8fe22e` | `0x51571750eEB8726d30c087912D6892E6E040207F` | ✅ mined |

## Config hooks (clones)

The per-pool hooks are EIP-1167 clones of `SafeSwapHookImpl`, deployed *from the impl* (`Clones.cloneDeterministic`), so the
**deployer is the impl** `0x00000000818784DDF475b110280562bB35C5c9C1` (NOT the `0x4e59…` factory). Their addresses encode
`(base_fee, capture)` as BCD in the high nibbles (`F<3 base-fee bps digits>C<rebate tens><0>`) plus the V4 permission bits in
the low 14 (`addr & 0x3FFF == 0x2A80`) → ~42-bit search per profile. Clone init code is the EIP-1167 stub with the impl baked in.

- **Clone init_code_hash:** `0xe7baeb1d3c5329241af68801604a7a86d1f27c9720b76942a1710263d76e3c1b`
- **Approved clone runtime codehash** (router `register_hook` gate): `0x2e34f2757040c52b65c1249d3726d231af1aea6511426a40dd7d7766bccfc9fa`
- Mined locally with `deploy/miner/miner3` (AVX2 4-way keccak, ~200 M/s; self-test-verified bit-identical to a scalar reference
  and to the 4 core mines). GPU was unavailable in this WSL2 box (broken dxg passthrough).

| Profile | base_fee / capture | Prefix | Salt | Address | Status |
|---|---|---|---|---|---|
| 1% / 70% | 100 bps / 70% | `0xf100c70` | `0xf0b6102a7dd730bb0300000000000000d39c5a2e0c0000000000000000000000` | `0xf100C7054ff14ffcfb1936e67f59a48f1e0DAa80` | ✅ mined |
| 0.3% / 70% | 30 bps / 70% | `0xf030c70` | `0x9b952734b5347c4a0800000000000000c17c8cf95f0000000000000000000000` | `0xF030C70b847E650E4aCE8589cDd96bAbb3382a80` | ✅ mined |

## Reproduce / verify a mine

Core contracts (deployer = canonical factory):
```
cast create2 --starts-with <prefix> \
  --init-code-hash <init_code_hash> \
  --deployer 0x4e59b44847b379578588920cA78FbF26c0B4956C
```

Verify any salt → address independently (works for clones too; deployer = impl for clones):
```
cast keccak 0xff<deployer><salt><init_code_hash>   # CREATE2 address = last 20 bytes
```
