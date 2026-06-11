// SafeSwap CREATE2 vanity miner v3 — AVX2 4-way batched keccak-256 (4 salts/permutation).
// The scalar array keccak (verified against real CREATE2 vectors) is kept as the reference; `selftest` proves the
// 4-way SIMD keccak is bit-identical per lane before it is trusted for the long run.
//
// Usage:
//   miner3 selftest
//   miner3 addr <deployer20> <init_hash32> <salt32>
//   miner3 mine <deployer20> <init_hash32> <prefix_hex> <low_mask_hex> <low_target_hex> [threads]

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;
#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

const RC: [u64; 24] = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
    0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
    0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
];
const ROTC: [u32; 24] = [1,3,6,10,15,21,28,36,45,55,2,14,27,41,56,8,25,43,62,18,39,61,20,44];
const PILN: [usize; 24] = [10,7,11,17,18,3,5,16,8,21,24,4,15,23,19,13,12,2,20,14,22,9,6,1];

// ---- scalar reference keccak-f (verified against real addresses) ----
fn keccakf(mut st: [u64; 25]) -> [u64; 25] {
    let mut bc = [0u64; 5];
    for r in 0..24 {
        for i in 0..5 { bc[i] = st[i] ^ st[i+5] ^ st[i+10] ^ st[i+15] ^ st[i+20]; }
        for i in 0..5 {
            let t = bc[(i+4)%5] ^ bc[(i+1)%5].rotate_left(1);
            let mut j = 0; while j < 25 { st[j+i] ^= t; j += 5; }
        }
        let mut t = st[1];
        for i in 0..24 { let j = PILN[i]; let tmp = st[j]; st[j] = t.rotate_left(ROTC[i]); t = tmp; }
        let mut jb = 0;
        while jb < 25 {
            for i in 0..5 { bc[i] = st[jb+i]; }
            for i in 0..5 { st[jb+i] ^= (!bc[(i+1)%5]) & bc[(i+2)%5]; }
            jb += 5;
        }
        st[0] ^= RC[r];
    }
    st
}

// ---- AVX2 4-way keccak-f: same algorithm as the scalar ref, ops broadcast across 4 lanes ----
#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2")]
unsafe fn rotl4(x: __m256i, n: u32) -> __m256i {
    let l = _mm_cvtsi32_si128(n as i32);
    let r = _mm_cvtsi32_si128((64 - n) as i32);
    _mm256_or_si256(_mm256_sll_epi64(x, l), _mm256_srl_epi64(x, r))
}

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2")]
unsafe fn keccakf4(st: &mut [__m256i; 25]) {
    let mut bc = [_mm256_setzero_si256(); 5];
    for r in 0..24 {
        for i in 0..5 {
            bc[i] = _mm256_xor_si256(st[i],
                    _mm256_xor_si256(st[i+5],
                    _mm256_xor_si256(st[i+10],
                    _mm256_xor_si256(st[i+15], st[i+20]))));
        }
        for i in 0..5 {
            let t = _mm256_xor_si256(bc[(i+4)%5], rotl4(bc[(i+1)%5], 1));
            let mut j = 0;
            while j < 25 { st[j+i] = _mm256_xor_si256(st[j+i], t); j += 5; }
        }
        let mut t = st[1];
        for i in 0..24 {
            let j = PILN[i];
            let tmp = st[j];
            st[j] = rotl4(t, ROTC[i]);
            t = tmp;
        }
        let mut jb = 0;
        while jb < 25 {
            for i in 0..5 { bc[i] = st[jb+i]; }
            for i in 0..5 {
                st[jb+i] = _mm256_xor_si256(st[jb+i], _mm256_andnot_si256(bc[(i+1)%5], bc[(i+2)%5]));
            }
            jb += 5;
        }
        st[0] = _mm256_xor_si256(st[0], _mm256_set1_epi64x(RC[r] as i64));
    }
}

#[inline(always)]
fn keccak85(input: &[u8; 85]) -> [u8; 32] {
    let mut block = [0u8; 136];
    block[..85].copy_from_slice(input);
    block[85] = 0x01; block[135] |= 0x80;
    let mut st = [0u64; 25];
    for i in 0..17 { st[i] = u64::from_le_bytes(block[i*8..i*8+8].try_into().unwrap()); }
    let st = keccakf(st);
    let mut out = [0u8; 32];
    for i in 0..4 { out[i*8..i*8+8].copy_from_slice(&st[i].to_le_bytes()); }
    out
}

fn base_lanes(input: &[u8; 85]) -> [u64; 25] {
    let mut block = [0u8; 136];
    block[..85].copy_from_slice(input);
    block[85] = 0x01; block[135] |= 0x80;
    let mut st = [0u64; 25];
    for i in 0..17 { st[i] = u64::from_le_bytes(block[i*8..i*8+8].try_into().unwrap()); }
    st
}

// address bytes from digest lanes 1,2,3 (digest[12..32])
#[inline(always)]
fn addr_from_digest(o1: u64, o2: u64, o3: u64) -> [u8; 20] {
    let mut a = [0u8; 20];
    let d1 = o1.to_le_bytes();
    a[0..4].copy_from_slice(&d1[4..8]);
    a[4..12].copy_from_slice(&o2.to_le_bytes());
    a[12..20].copy_from_slice(&o3.to_le_bytes());
    a
}

fn unhex(s: &str) -> Vec<u8> {
    let s = s.trim_start_matches("0x").trim_start_matches("0X");
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i+2], 16).expect("bad hex")).collect()
}
fn hexstr(b: &[u8]) -> String { let mut s = String::from("0x"); for x in b { s.push_str(&format!("{:02x}", x)); } s }

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 { eprintln!("need a subcommand"); std::process::exit(1); }
    match args[1].as_str() {
        "selftest" => {
            // 4-way SIMD keccak must equal scalar ref on every lane, for many random states.
            let mut s: u64 = 0x243f6a8885a308d3;
            let mut rng = || { s ^= s << 13; s ^= s >> 7; s ^= s << 17; s };
            unsafe {
                for _ in 0..100_000 {
                    let mut scal = [[0u64; 25]; 4];
                    let mut simd = [_mm256_setzero_si256(); 25];
                    for i in 0..25 {
                        let v = [rng(), rng(), rng(), rng()];
                        for l in 0..4 { scal[l][i] = v[l]; }
                        simd[i] = _mm256_set_epi64x(v[3] as i64, v[2] as i64, v[1] as i64, v[0] as i64);
                    }
                    for l in 0..4 { scal[l] = keccakf(scal[l]); }
                    keccakf4(&mut simd);
                    for i in 0..25 {
                        let mut out = [0u64; 4];
                        _mm256_storeu_si256(out.as_mut_ptr() as *mut __m256i, simd[i]);
                        for l in 0..4 {
                            if out[l] != scal[l][i] { eprintln!("4WAY MISMATCH lane {} word {}", l, i); std::process::exit(2); }
                        }
                    }
                }
            }
            // empty-string keccak vector via scalar path
            let mut blk = [0u8; 136]; blk[0] = 0x01; blk[135] |= 0x80;
            let mut st = [0u64; 25];
            for i in 0..17 { st[i] = u64::from_le_bytes(blk[i*8..i*8+8].try_into().unwrap()); }
            let st = keccakf(st);
            let mut out = [0u8; 32];
            for i in 0..4 { out[i*8..i*8+8].copy_from_slice(&st[i].to_le_bytes()); }
            assert_eq!(hexstr(&out), "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470");
            println!("SELFTEST OK (4-way==scalar on 100k x4 states; empty-string vector matches)");
        }
        "addr" => {
            let deployer = unhex(&args[2]); assert_eq!(deployer.len(), 20);
            let init = unhex(&args[3]); assert_eq!(init.len(), 32);
            let salt = unhex(&args[4]); assert_eq!(salt.len(), 32);
            let mut pre = [0u8; 85];
            pre[0] = 0xff; pre[1..21].copy_from_slice(&deployer);
            pre[21..53].copy_from_slice(&salt); pre[53..85].copy_from_slice(&init);
            let d = keccak85(&pre);
            println!("{}", hexstr(&d[12..32]));
        }
        "mine" => {
            let deployer = unhex(&args[2]); assert_eq!(deployer.len(), 20);
            let init = unhex(&args[3]); assert_eq!(init.len(), 32);
            let prefix_nibbles: Vec<u8> = args[4].trim_start_matches("0x").chars()
                .map(|c| c.to_digit(16).expect("bad prefix") as u8).collect();
            let low_mask = u16::from_str_radix(args[5].trim_start_matches("0x"), 16).unwrap();
            let low_target = u16::from_str_radix(args[6].trim_start_matches("0x"), 16).unwrap();
            let threads: usize = if args.len() > 7 { args[7].parse().unwrap() } else { 16 };

            let full_bytes = prefix_nibbles.len() / 2;
            let mut pfx = Vec::new();
            for i in 0..full_bytes { pfx.push((prefix_nibbles[2*i] << 4) | prefix_nibbles[2*i+1]); }
            let odd = prefix_nibbles.len() % 2 == 1;
            let odd_nibble = if odd { prefix_nibbles[prefix_nibbles.len()-1] } else { 0 };

            let seed = {
                let mut b = [0u8; 8];
                use std::io::Read;
                std::fs::File::open("/dev/urandom").unwrap().read_exact(&mut b).unwrap();
                u64::from_le_bytes(b)
            };
            let found = Arc::new(AtomicBool::new(false));
            let result: Arc<Mutex<Option<([u8;32],[u8;20])>>> = Arc::new(Mutex::new(None));
            let counter = Arc::new(AtomicU64::new(0));
            let start = Instant::now();
            let mut handles = Vec::new();
            for tid in 0..threads {
                let deployer = deployer.clone(); let init = init.clone(); let pfx = pfx.clone();
                let found = found.clone(); let result = result.clone(); let counter = counter.clone();
                handles.push(std::thread::spawn(move || unsafe {
                    let mut pre = [0u8; 85];
                    pre[0] = 0xff; pre[1..21].copy_from_slice(&deployer); pre[53..85].copy_from_slice(&init);
                    pre[21..29].copy_from_slice(&seed.to_le_bytes());
                    pre[29..37].copy_from_slice(&(tid as u64).to_le_bytes());
                    let base = base_lanes(&pre);
                    // broadcast base into a 4-way template
                    let mut tmpl = [_mm256_setzero_si256(); 25];
                    for i in 0..25 { tmpl[i] = _mm256_set1_epi64x(base[i] as i64); }
                    let base4 = base[4];
                    let mut ctr: u64 = 0;
                    let mut local: u64 = 0;
                    loop {
                        if local & 0x3FFFF == 0 {
                            if found.load(Ordering::Relaxed) { break; }
                            counter.fetch_add(local, Ordering::Relaxed);
                            local = 0;
                        }
                        let (c0, c1, c2, c3) = (ctr, ctr+1, ctr+2, ctr+3);
                        let mut st = tmpl;
                        // lane4 = base4 | ((c & 0xFFFFFF) << 40);  lane5 = c >> 24
                        st[4] = _mm256_or_si256(_mm256_set1_epi64x(base4 as i64),
                            _mm256_set_epi64x((((c3 & 0xFF_FFFF) << 40) as i64),
                                              (((c2 & 0xFF_FFFF) << 40) as i64),
                                              (((c1 & 0xFF_FFFF) << 40) as i64),
                                              (((c0 & 0xFF_FFFF) << 40) as i64)));
                        st[5] = _mm256_set_epi64x((c3 >> 24) as i64, (c2 >> 24) as i64, (c1 >> 24) as i64, (c0 >> 24) as i64);
                        keccakf4(&mut st);
                        let mut o1 = [0u64; 4]; let mut o2 = [0u64; 4]; let mut o3 = [0u64; 4];
                        _mm256_storeu_si256(o1.as_mut_ptr() as *mut __m256i, st[1]);
                        _mm256_storeu_si256(o2.as_mut_ptr() as *mut __m256i, st[2]);
                        _mm256_storeu_si256(o3.as_mut_ptr() as *mut __m256i, st[3]);
                        let cs = [c0, c1, c2, c3];
                        for j in 0..4 {
                            let addr = addr_from_digest(o1[j], o2[j], o3[j]);
                            let mut ok = true;
                            for i in 0..pfx.len() { if addr[i] != pfx[i] { ok = false; break; } }
                            if ok && odd && (addr[pfx.len()] >> 4) != odd_nibble { ok = false; }
                            if ok {
                                let low = ((addr[18] as u16) << 8) | (addr[19] as u16);
                                if (low & low_mask) == low_target {
                                    let mut salt = [0u8; 32];
                                    salt[0..8].copy_from_slice(&seed.to_le_bytes());
                                    salt[8..16].copy_from_slice(&(tid as u64).to_le_bytes());
                                    salt[16..24].copy_from_slice(&cs[j].to_le_bytes());
                                    *result.lock().unwrap() = Some((salt, addr));
                                    found.store(true, Ordering::Relaxed);
                                    break;
                                }
                            }
                        }
                        ctr = ctr.wrapping_add(4);
                        local += 4;
                    }
                }));
            }
            let pf = found.clone(); let pc = counter.clone();
            let reporter = std::thread::spawn(move || {
                let mut last = 0u64;
                while !pf.load(Ordering::Relaxed) {
                    std::thread::sleep(std::time::Duration::from_secs(30));
                    let c = pc.load(Ordering::Relaxed);
                    let el = start.elapsed().as_secs_f64();
                    let rate = (c - last) as f64 / 30.0; last = c;
                    eprintln!("[{:>7.0}s] {:>15} tries  {:>7.1} M/s", el, c, rate / 1e6);
                }
            });
            for h in handles { h.join().unwrap(); }
            let _ = reporter.join();
            let r = result.lock().unwrap().clone();
            if let Some((salt, addr)) = r {
                println!("SALT={}", hexstr(&salt));
                println!("ADDR={}", hexstr(&addr));
                eprintln!("found in {:.1}s, ~{} tries", start.elapsed().as_secs_f64(), counter.load(Ordering::Relaxed));
            }
        }
        _ => { eprintln!("unknown subcommand"); std::process::exit(1); }
    }
}
