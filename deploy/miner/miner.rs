// SafeSwap CREATE2 vanity miner — self-contained (std only), hand-rolled keccak-256.
//
// Usage:
//   miner addr  <deployer20> <init_hash32> <salt32>
//        -> prints the CREATE2 address for a given salt (verification mode)
//
//   miner mine  <deployer20> <init_hash32> <prefix_hex> <low_mask_hex> <low_target_hex> [threads]
//        -> searches salts until address matches:
//             - the leading nibbles equal <prefix_hex>, AND
//             - (u16(last 2 bytes) & low_mask) == low_target
//           prints salt + address.
//
// All hex args may omit the 0x prefix.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

// ---- keccak-f[1600] ----
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

#[inline(always)]
fn keccakf(mut st: [u64; 25]) -> [u64; 25] {
    let mut bc = [0u64; 5];
    for r in 0..24 {
        for i in 0..5 { bc[i] = st[i] ^ st[i+5] ^ st[i+10] ^ st[i+15] ^ st[i+20]; }
        for i in 0..5 {
            let t = bc[(i+4)%5] ^ bc[(i+1)%5].rotate_left(1);
            let mut j = 0;
            while j < 25 { st[j+i] ^= t; j += 5; }
        }
        let mut t = st[1];
        for i in 0..24 {
            let j = PILN[i];
            let tmp = st[j];
            st[j] = t.rotate_left(ROTC[i]);
            t = tmp;
        }
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

// keccak256 of a single 85-byte block -> 32-byte digest (specialized; 85 < 136 rate).
#[inline(always)]
fn keccak85(input: &[u8; 85]) -> [u8; 32] {
    let mut block = [0u8; 136];
    block[..85].copy_from_slice(input);
    block[85] = 0x01;       // keccak pad start
    block[135] |= 0x80;     // keccak pad end
    let mut st = [0u64; 25];
    for i in 0..17 {
        st[i] = u64::from_le_bytes(block[i*8..i*8+8].try_into().unwrap());
    }
    let st = keccakf(st);
    let mut out = [0u8; 32];
    for i in 0..4 { out[i*8..i*8+8].copy_from_slice(&st[i].to_le_bytes()); }
    out
}

// Padded-block lanes for an 85-byte preimage -> the 25-lane absorb state (counter region must be zero in `input`).
fn base_lanes(input: &[u8; 85]) -> [u64; 25] {
    let mut block = [0u8; 136];
    block[..85].copy_from_slice(input);
    block[85] = 0x01;
    block[135] |= 0x80;
    let mut st = [0u64; 25];
    for i in 0..17 { st[i] = u64::from_le_bytes(block[i*8..i*8+8].try_into().unwrap()); }
    st
}

// Hot path: clone the precomputed base state, patch only the salt-counter lanes, permute, return the 20-byte address.
// The u64 `ctr` lives at preimage bytes 37..45 -> block byte 37 is bit 296 -> lane 4 bits 40.. and lane 5.
#[inline(always)]
fn addr_from_base(base: &[u64; 25], ctr: u64) -> [u8; 20] {
    let mut st = *base;
    st[4] |= (ctr & 0xFF_FFFF) << 40;   // low 3 bytes of ctr -> block[37..40]
    st[5] = ctr >> 24;                  // high 5 bytes of ctr -> block[40..45]
    let st = keccakf(st);
    let mut a = [0u8; 20];
    // address = digest[12..32] = bytes 12..32 of lanes 0..3 little-endian
    let d1 = st[1].to_le_bytes();
    let d2 = st[2].to_le_bytes();
    let d3 = st[3].to_le_bytes();
    a[0..4].copy_from_slice(&d1[4..8]);
    a[4..12].copy_from_slice(&d2);
    a[12..20].copy_from_slice(&d3);
    a
}

fn unhex(s: &str) -> Vec<u8> {
    let s = s.trim_start_matches("0x").trim_start_matches("0X");
    (0..s.len()).step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i+2], 16).expect("bad hex"))
        .collect()
}

fn hexstr(b: &[u8]) -> String {
    let mut s = String::from("0x");
    for x in b { s.push_str(&format!("{:02x}", x)); }
    s
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 { eprintln!("need a subcommand"); std::process::exit(1); }

    match args[1].as_str() {
        "addr" => {
            let deployer = unhex(&args[2]); assert_eq!(deployer.len(), 20);
            let init    = unhex(&args[3]); assert_eq!(init.len(), 32);
            let salt    = unhex(&args[4]); assert_eq!(salt.len(), 32);
            let mut pre = [0u8; 85];
            pre[0] = 0xff;
            pre[1..21].copy_from_slice(&deployer);
            pre[21..53].copy_from_slice(&salt);
            pre[53..85].copy_from_slice(&init);
            let d = keccak85(&pre);
            println!("{}", hexstr(&d[12..32]));
        }
        "mine" => {
            let deployer = unhex(&args[2]); assert_eq!(deployer.len(), 20);
            let init     = unhex(&args[3]); assert_eq!(init.len(), 32);
            let prefix_nibbles: Vec<u8> = args[4].trim_start_matches("0x").chars()
                .map(|c| c.to_digit(16).expect("bad prefix") as u8).collect();
            let low_mask   = u16::from_str_radix(args[5].trim_start_matches("0x"), 16).unwrap();
            let low_target = u16::from_str_radix(args[6].trim_start_matches("0x"), 16).unwrap();
            let threads: usize = if args.len() > 7 { args[7].parse().unwrap() } else { 16 };

            // Precompute full-byte prefix and optional trailing half-nibble.
            let full_bytes = prefix_nibbles.len() / 2;
            let mut pfx = Vec::new();
            for i in 0..full_bytes { pfx.push((prefix_nibbles[2*i] << 4) | prefix_nibbles[2*i+1]); }
            let odd = prefix_nibbles.len() % 2 == 1;
            let odd_nibble = if odd { prefix_nibbles[prefix_nibbles.len()-1] } else { 0 };

            // per-thread random seed
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
                let deployer = deployer.clone();
                let init = init.clone();
                let pfx = pfx.clone();
                let found = found.clone();
                let result = result.clone();
                let counter = counter.clone();
                handles.push(std::thread::spawn(move || {
                    // salt layout: [seed 8][tid 8][ctr 8][zero 8]; ctr occupies preimage bytes 37..45.
                    let mut pre = [0u8; 85];
                    pre[0] = 0xff;
                    pre[1..21].copy_from_slice(&deployer);
                    pre[53..85].copy_from_slice(&init);
                    pre[21..29].copy_from_slice(&seed.to_le_bytes());
                    pre[29..37].copy_from_slice(&(tid as u64).to_le_bytes());
                    let base = base_lanes(&pre);   // ctr region (bytes 37..45) is zero here
                    let mut ctr: u64 = 0;
                    let mut local: u64 = 0;
                    loop {
                        if local & 0x3FFFF == 0 {
                            if found.load(Ordering::Relaxed) { break; }
                            counter.fetch_add(local, Ordering::Relaxed);
                            local = 0;
                        }
                        let addr = addr_from_base(&base, ctr);
                        // prefix check
                        let mut ok = true;
                        for i in 0..pfx.len() { if addr[i] != pfx[i] { ok = false; break; } }
                        if ok && odd && (addr[pfx.len()] >> 4) != odd_nibble { ok = false; }
                        if ok {
                            let low = ((addr[18] as u16) << 8) | (addr[19] as u16);
                            if (low & low_mask) == low_target {
                                let mut salt = [0u8; 32];
                                salt[0..8].copy_from_slice(&seed.to_le_bytes());
                                salt[8..16].copy_from_slice(&(tid as u64).to_le_bytes());
                                salt[16..24].copy_from_slice(&ctr.to_le_bytes());
                                *result.lock().unwrap() = Some((salt, addr));
                                found.store(true, Ordering::Relaxed);
                                break;
                            }
                        }
                        ctr = ctr.wrapping_add(1);
                        local += 1;
                    }
                }));
            }

            // progress reporter
            let pf = found.clone();
            let pc = counter.clone();
            let reporter = std::thread::spawn(move || {
                let mut last = 0u64;
                while !pf.load(Ordering::Relaxed) {
                    std::thread::sleep(std::time::Duration::from_secs(10));
                    let c = pc.load(Ordering::Relaxed);
                    let el = start.elapsed().as_secs_f64();
                    let rate = (c - last) as f64 / 10.0;
                    last = c;
                    eprintln!("[{:>6.0}s] {:>14} tries  {:>7.1} M/s", el, c, rate / 1e6);
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
