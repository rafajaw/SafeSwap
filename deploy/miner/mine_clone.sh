#!/usr/bin/env bash
# Mine a SafeSwap config-hook clone address for a (base_fee_bps, rebate_percent) profile.
# The clone is CREATE2-deployed by the impl; its address must encode the profile as BCD
# (F <3 base-fee digits> C <rebate tens> 0 …) with the V4 permission bits 0x2A80 in the low 14.
#
#   Usage:  ./mine_clone.sh <base_fee_bps> <rebate_percent> [threads]
#   Build:  rustc --edition 2021 -C opt-level=3 -C target-cpu=native -C codegen-units=1 -C lto=fat miner3.rs -o miner3
#           (miner.rs is the portable scalar reference; miner3.rs is the AVX2 build used in practice.
#            `./miner3 selftest` proves the SIMD keccak bit-identical to the scalar reference.)
set -euo pipefail
cd "$(dirname "$0")"
bps="$1"; reb="$2"; threads="${3:-16}"
IMPL=0x00000000818784DDF475b110280562bB35C5c9C1
CLONE_HASH=0xe7baeb1d3c5329241af68801604a7a86d1f27c9720b76942a1710263d76e3c1b
prefix=$(printf 'f%03dc%d0' "$bps" $((reb/10)))
echo "mining clone: base_fee=${bps}bps rebate=${reb}% -> prefix 0x${prefix}  (threads=$threads)"
./miner3 mine "$IMPL" "$CLONE_HASH" "$prefix" 0x3FFF 0x2A80 "$threads"
