import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

// Mirrors the on-chain SafeSwapPositionDescriptor render (mock locked in nft-renders/reference9.svg).
// Used to stress the SVG layout against long symbols, huge/tiny numbers, out-of-range, and price-off pools.

const outDir = "nft-renders";

const SAMPLE_NFT = "0x5Afe5Wap000000000000000000000000000A1234";
const SAMPLE_HOOK = "0xF005C2000000000000000000000000000000beef";

const examples = [
  {
    label: "canonical, in range",
    tokenIdHex: "0x1122334455667788",
    symbol0: "ETH", symbol1: "USDC", decimals0: 18, decimals1: 6,
    baseFeePercent: "0.05", rebatePercent: 20, ageDays: 120, tickSpacing: 10, tickLower: -120, tickUpper: 120,
    position0: 420000000000000000n, position1: 1280000000n,
    claimable0: 9300000000000000n, claimable1: 180500000n,
    earned0: 78000000000000000n, earned1: 2450000000n,
    lifetimeYieldBps: 80, annualizedYieldBps: 243,
    priceKnown: true, inRange: true, status: "In Range",
    currentPrice: 3002, lowPrice: 2850, highPrice: 3150,
  },
  {
    label: "out of range — price BELOW",
    tokenIdHex: "0x00000000000004d2",
    symbol0: "WBTC", symbol1: "USDC", decimals0: 8, decimals1: 6,
    baseFeePercent: "0.3", rebatePercent: 50, ageDays: 41, tickSpacing: 60, tickLower: 69000, tickUpper: 70200,
    position0: 25000000n, position1: 0n,
    claimable0: 12000n, claimable1: 0n,
    earned0: 410000n, earned1: 92000000n,
    lifetimeYieldBps: 137, annualizedYieldBps: 612,
    priceKnown: true, inRange: false, status: "Out of Range",
    currentPrice: 58200, lowPrice: 60000, highPrice: 66000,
  },
  {
    label: "out of range — price ABOVE",
    tokenIdHex: "0x000000000000abcd",
    symbol0: "ARB", symbol1: "USDC", decimals0: 18, decimals1: 6,
    baseFeePercent: "0.3", rebatePercent: 30, ageDays: 7, tickSpacing: 60, tickLower: -6960, tickUpper: -4080,
    position0: 0n, position1: 880250000n,
    claimable0: 0n, claimable1: 4310000n,
    earned0: 0n, earned1: 51200000n,
    lifetimeYieldBps: 58, annualizedYieldBps: 3020,
    priceKnown: true, inRange: false, status: "Out of Range",
    currentPrice: 1.42, lowPrice: 0.95, highPrice: 1.21,
  },
  {
    label: "huge supply (comma + overflow stress)",
    tokenIdHex: "0x0000000fffffffff",
    symbol0: "PEPE", symbol1: "USDC", decimals0: 18, decimals1: 6,
    baseFeePercent: "1", rebatePercent: 60, ageDays: 305, tickSpacing: 200, tickLower: -120000, tickUpper: -90000,
    position0: 12450000000000000000000000n, position1: 8900000000000000n,
    claimable0: 36000000000000000000000n, claimable1: 14250000000n,
    earned0: 990000000000000000000000n, earned1: 412000000000n,
    lifetimeYieldBps: 689, annualizedYieldBps: 824,
    priceKnown: true, inRange: true, status: "In Range",
    currentPrice: 0.00000712, lowPrice: 0.0000061, highPrice: 0.0000082,
  },
  {
    label: "long symbol (12-char cap)",
    tokenIdHex: "0x0000000000bada55",
    symbol0: "wstETH", symbol1: "SAFE-USDC-LP", decimals0: 18, decimals1: 18,
    baseFeePercent: "0.05", rebatePercent: 40, ageDays: 88, tickSpacing: 10, tickLower: -50, tickUpper: 50,
    position0: 3120000000000000000n, position1: 3344000000000000000000n,
    claimable0: 21000000000000000n, claimable1: 18900000000000000000n,
    earned0: 180000000000000000n, earned1: 161000000000000000000n,
    lifetimeYieldBps: 96, annualizedYieldBps: 398,
    priceKnown: true, inRange: true, status: "In Range",
    currentPrice: 1.072, lowPrice: 1.045, highPrice: 1.121,
  },
  {
    label: "dust amounts (<0.0001)",
    tokenIdHex: "0x0000000000000001",
    symbol0: "ETH", symbol1: "DAI", decimals0: 18, decimals1: 18,
    baseFeePercent: "0.3", rebatePercent: 10, ageDays: 2, tickSpacing: 60, tickLower: -1800, tickUpper: 1800,
    position0: 30000000000000n, position1: 90000000000000000n,
    claimable0: 12000000000n, claimable1: 41000000000000n,
    earned0: 88000000000n, earned1: 250000000000000n,
    lifetimeYieldBps: 3, annualizedYieldBps: 540,
    priceKnown: true, inRange: true, status: "In Range",
    currentPrice: 3001.5, lowPrice: 2460, highPrice: 3660,
  },
  {
    label: "closed / zero liquidity (hex-symbol fallback)",
    tokenIdHex: "0x0000000000000007",
    symbol0: "0x1234567890abcdef", symbol1: "TOKEN", decimals0: 18, decimals1: 18,
    baseFeePercent: "0.3", rebatePercent: 10, ageDays: 60, tickSpacing: 60, tickLower: -1800, tickUpper: 1800,
    position0: 0n, position1: 0n,
    claimable0: 0n, claimable1: 0n,
    earned0: 50000000000000000n, earned1: 120000000000000000000n,
    lifetimeYieldBps: 0, annualizedYieldBps: 0,
    inRange: true, status: "In Range",
    currentPrice: 3001, lowPrice: 2800, highPrice: 3200,
  },
  {
    label: "max fee / 90% rebate / 999d",
    tokenIdHex: "0xfedcba9876543210",
    symbol0: "MOG", symbol1: "WETH", decimals0: 18, decimals1: 18,
    baseFeePercent: "9.99", rebatePercent: 90, ageDays: 999, tickSpacing: 200, tickLower: 60000, tickUpper: 120000,
    position0: 45000000000000000000000n, position1: 0n,
    claimable0: 1200000000000000000000n, claimable1: 0n,
    earned0: 88000000000000000000000n, earned1: 14000000000000000000n,
    lifetimeYieldBps: 1844, annualizedYieldBps: 673,
    priceKnown: true, inRange: false, status: "Out of Range",
    currentPrice: 0.0000402, lowPrice: 0.0000071, highPrice: 0.0000133,
  },
];

// ━━━━ formatters (mirror StringHelperLib, + thousands grouping) ━━━━

function groupThousands(intStr) {
  const neg = intStr.startsWith("-");
  const digits = neg ? intStr.slice(1) : intStr;
  return (neg ? "-" : "") + digits.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

function trimZeros(s) {
  return s.replace(/\.?0+$/, "");
}

function formatTokenAmount(amount, decimals) {
  if (amount === 0n) return "0";
  const display = Math.min(decimals, 4);
  const scale = 10n ** BigInt(decimals);
  const whole = amount / scale;
  const remainder = amount % scale;
  const divisor = 10n ** BigInt(decimals - display);
  const fractional = display === 0 ? 0n : remainder / divisor;
  const wholeStr = groupThousands(whole.toString());

  if (fractional === 0n) {
    if (whole === 0n) return `<0.${"0".repeat(Math.max(display - 1, 0))}1`;
    return wholeStr;
  }
  const fraction = fractional.toString().padStart(display, "0").replace(/0+$/, "");
  return `${wholeStr}.${fraction}`;
}

function formatPrice(n) {
  if (n === 0) return "0";
  if (n >= 1000) return groupThousands(Math.round(n).toString());
  if (n >= 1) return trimZeros(n.toFixed(2));
  if (n >= 0.001) return trimZeros(n.toFixed(4));
  // sub-0.001: plain decimal with ~3 significant figures (no exponential)
  const lead = Math.floor(-Math.log10(n));
  return trimZeros(n.toFixed(Math.min(lead + 3, 18)));
}

// Sample render time for the snapshot stamp (on-chain this is block.timestamp at the eth_call): 2026-06-05 14:32 UTC.
const SAMPLE_RENDERED_AT = 1780669920;

function formatUtcDatetime(ts) {
  const d = new Date(ts * 1000);
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getUTCFullYear()}-${p(d.getUTCMonth() + 1)}-${p(d.getUTCDate())} ${p(d.getUTCHours())}:${p(d.getUTCMinutes())} UTC`;
}

function formatBpsAsPercentString(valueBps) {
  const whole = Math.floor(valueBps / 100);
  const fractional = valueBps % 100;
  if (fractional === 0) return `${whole}%`;
  const pad = fractional < 10 ? "0" : "";
  return `${whole}.${pad}${String(fractional).replace(/0$/, "")}%`;
}

// on-chain symbol sanitize: keep [0-9A-Za-z.-], cap 12, fallback TOKEN
function sanitize(symbol) {
  const clean = [...symbol].filter((c) => /[0-9A-Za-z.\-]/.test(c)).slice(0, 12).join("");
  return clean.length === 0 ? "TOKEN" : clean;
}

// ━━━━ SVG sections ━━━━

function renderMarket(p) {
  // A minted SafeSwap NFT always has an initialized pool (create_position initializes before _mint),
  // so the price is always known. The sqrtPrice!=0 guard survives only as div-by-zero defense on-chain.
  const accent = p.inRange ? "#37d6a3" : "#b7c0cf";
  const accentClass = p.inRange ? "g" : "n";
  const badgeX = p.inRange ? 40 : 33;
  const badgeWidth = p.inRange ? 104 : 118;
  const dotX = p.inRange ? 62 : 51;
  const textX = p.inRange ? 98 : 99;

  const span = p.highPrice - p.lowPrice;
  let f = span > 0 ? (p.currentPrice - p.lowPrice) / span : 0;
  f = Math.max(0, Math.min(1, f));
  const barX = 201, barW = 85;
  const fillW = Math.round(f * barW * 100) / 100;
  const thumbX = Math.round((barX + f * barW) * 100) / 100;
  const unit = `${sanitize(p.symbol1)} / ${sanitize(p.symbol0)}`;

  return [
    `<text x='326' y='404' text-anchor='end' class='t w4 lbl' font-size='9'>${unit}</text>`,
    `<text x='244' y='417' text-anchor='middle' class='m ${accentClass}' font-size='12'>${formatPrice(p.currentPrice)}</text>`,
    `<rect x='${badgeX}' y='402' width='${badgeWidth}' height='30' rx='15' fill='#000' fill-opacity='.14'/>`,
    `<circle cx='${dotX}' cy='417' r='3.5' fill='${accent}'/>`,
    `<text x='${textX}' y='421' text-anchor='middle' class='t ${accentClass}' font-size='12' font-weight='600'>${p.status}</text>`,
    `<text x='193' y='431' text-anchor='end' class='m w5' font-size='10'>${formatPrice(p.lowPrice)}</text>`,
    `<rect x='${barX}' y='426.5' width='${barW}' height='3' rx='1.5' fill='#fff' fill-opacity='.08'/>`,
    fillW > 0 ? `<rect x='${barX}' y='426.5' width='${fillW}' height='3' rx='1.5' fill='#fff' fill-opacity='.16'/>` : "",
    `<circle cx='${thumbX}' cy='428' r='2.5' fill='${accent}' fill-opacity='.9'/>`,
    `<text x='294' y='431' text-anchor='start' class='m w5' font-size='10'>${formatPrice(p.highPrice)}</text>`,
  ].join("");
}

function renderYield(p) {
  return [
    "<line x1='24' y1='288' x2='326' y2='288' class='rule'/>",
    "<text x='58' y='320' text-anchor='middle' class='t w4 lbl' font-size='11'>YIELD</text>",
    `<text x='196' y='320' text-anchor='end' class='m w val' font-size='18'>${formatBpsAsPercentString(p.lifetimeYieldBps)}</text>`,
    "<text x='202' y='320' class='t w5' font-size='11'>life</text>",
    `<text x='290' y='320' text-anchor='end' class='m w val' font-size='18'>${formatBpsAsPercentString(p.annualizedYieldBps)}</text>`,
    "<text x='296' y='320' class='t w5' font-size='11'>ann.</text>",
  ].join("");
}

function renderSvg(p) {
  const sym0 = sanitize(p.symbol0);
  const sym1 = sanitize(p.symbol1);
  const amt0 = formatTokenAmount(p.position0, p.decimals0);
  const amt1 = formatTokenAmount(p.position1, p.decimals1);
  const earned0 = formatTokenAmount(p.earned0, p.decimals0);
  const earned1 = formatTokenAmount(p.earned1, p.decimals1);
  const claim0 = formatTokenAmount(p.claimable0, p.decimals0);
  const claim1 = formatTokenAmount(p.claimable1, p.decimals1);

  return [
    "<svg xmlns='http://www.w3.org/2000/svg' width='350' height='480' viewBox='0 0 350 480'>",
    "<defs>",
    "<linearGradient id='bg' x1='0' y1='0' x2='1' y2='1'>",
    "<stop offset='0' stop-color='#276f61'/><stop offset='.46' stop-color='#13233a'/><stop offset='1' stop-color='#584a34'/>",
    "</linearGradient>",
    "<radialGradient id='glow' cx='18%' cy='6%' r='72%'>",
    "<stop offset='0' stop-color='#37d6a3' stop-opacity='.42'/><stop offset='1' stop-color='#37d6a3' stop-opacity='0'/>",
    "</radialGradient>",
    "<style>",
    ".t{font-family:'Inter','Helvetica Neue',Arial,sans-serif}.m{font-family:'Roboto Mono',ui-monospace,monospace}",
    ".w{fill:#fff}.w9{fill:#fff;fill-opacity:.9}.w6{fill:#fff;fill-opacity:.6}.w5{fill:#fff;fill-opacity:.5}.w4{fill:#fff;fill-opacity:.4}",
    ".g{fill:#37d6a3}.n{fill:#b7c0cf}.gs{fill:#37d6a3;fill-opacity:.6}.val{font-weight:700}.lbl{font-weight:600;letter-spacing:.4}.rule{stroke:#fff;stroke-opacity:.1}",
    "</style>",
    "</defs>",
    "<rect width='350' height='480' rx='24' fill='url(#bg)'/>",
    "<rect width='350' height='480' rx='24' fill='url(#glow)'/>",
    "<rect x='.5' y='.5' width='349' height='479' rx='23.5' fill='none' stroke='#fff' stroke-opacity='.1'/>",

    `<text x='24' y='43' class='m w9 val' font-size='15'>${p.tokenIdHex}</text>`,
    "<text x='326' y='43' text-anchor='end' class='t' font-size='13' font-weight='700'><tspan class='w9'>Safe</tspan><tspan class='g'>Swap</tspan></text>",
    "<line x1='24' y1='58' x2='326' y2='58' class='rule'/>",

    "<text x='175' y='88' text-anchor='middle' class='t w4 lbl' font-size='11'>CURRENT POSITION</text>",
    `<text x='90' y='126' text-anchor='middle' class='t w val' font-size='24'>${sym0}</text>`,
    `<text x='90' y='155' text-anchor='middle' class='m w6' font-size='19'>${amt0}</text>`,
    `<text x='260' y='126' text-anchor='middle' class='t w val' font-size='24'>${sym1}</text>`,
    `<text x='260' y='155' text-anchor='middle' class='m w6' font-size='19'>${amt1}</text>`,
    "<line x1='24' y1='184' x2='326' y2='184' class='rule'/>",

    "<line x1='175' y1='196' x2='175' y2='278' class='rule' stroke-opacity='.08'/>",
    "<ellipse cx='72' cy='211' rx='6' ry='4' fill='#1f9d77'/>",
    "<ellipse cx='72' cy='209' rx='6' ry='4' fill='#37d6a3'/>",
    "<ellipse cx='70' cy='208' rx='2' ry='1.2' fill='#fff' fill-opacity='.5'/>",
    "<text x='104' y='213' text-anchor='middle' class='t w4 lbl' font-size='11'>EARNED</text>",
    `<text x='99' y='241' text-anchor='middle' class='m w val' font-size='16'>${earned0}<tspan class='t w5' dx='5' font-size='12'>${sym0}</tspan></text>`,
    `<text x='99' y='263' text-anchor='middle' class='m w val' font-size='16'>${earned1}<tspan class='t w5' dx='5' font-size='12'>${sym1}</tspan></text>`,
    "<path d='M213 202 v7 m-3 -3 l3 3 l3 -3' stroke='#37d6a3' stroke-width='1.6' fill='none' stroke-linecap='round' stroke-linejoin='round'/>",
    "<path d='M209 213 h8' stroke='#37d6a3' stroke-width='1.6' stroke-linecap='round'/>",
    "<text x='256' y='213' text-anchor='middle' class='t w4 lbl' font-size='11'>CLAIMABLE</text>",
    `<text x='251' y='241' text-anchor='middle' class='m g val' font-size='16'>${claim0}<tspan class='t gs' dx='5' font-size='12'>${sym0}</tspan></text>`,
    `<text x='251' y='263' text-anchor='middle' class='m g val' font-size='16'>${claim1}<tspan class='t gs' dx='5' font-size='12'>${sym1}</tspan></text>`,

    renderYield(p),

    "<rect x='0' y='338' width='350' height='42' fill='#fff' fill-opacity='.05'/>",
    "<line x1='0' y1='338' x2='350' y2='338' class='rule'/>",
    "<line x1='117' y1='348' x2='117' y2='370' class='rule' stroke-opacity='.12'/>",
    "<line x1='233' y1='348' x2='233' y2='370' class='rule' stroke-opacity='.12'/>",
    `<text x='58' y='363' text-anchor='middle' class='t' font-size='12'><tspan class='w4 lbl' font-size='10'>FEE</tspan><tspan class='m w9 val' dx='5'>${p.baseFeePercent}%</tspan></text>`,
    `<text x='175' y='363' text-anchor='middle' class='t' font-size='12'><tspan class='w4 lbl' font-size='10'>REBATE</tspan><tspan class='m w9 val' dx='5'>${p.rebatePercent}%</tspan></text>`,
    `<text x='292' y='363' text-anchor='middle' class='t' font-size='12'><tspan class='w4 lbl' font-size='10'>AGE</tspan><tspan class='m w9 val' dx='5'>${p.ageDays}d</tspan></text>`,

    renderMarket(p),

    `<text x='175' y='468' text-anchor='middle' class='m w5' font-size='9'>as of ${formatUtcDatetime(SAMPLE_RENDERED_AT)}</text>`,
    "</svg>",
  ].join("");
}

// ━━━━ metadata (self-locating attributes) ━━━━

function renderMetadata(p, idx, svg) {
  const image = `data:image/svg+xml;base64,${Buffer.from(svg).toString("base64")}`;
  const sym0 = sanitize(p.symbol0), sym1 = sanitize(p.symbol1);
  return {
    name: `SafeSwap Positions ${p.tokenIdHex} ${sym0}/${sym1}`,
    description: "Trustless MEV-protected Uniswap LP positions",
    image,
    attributes: [
      { trait_type: "Pair", value: `${sym0}/${sym1}` },
      { trait_type: "Base Fee", value: `${p.baseFeePercent}%` },
      { trait_type: "LP Rebate", value: `${p.rebatePercent}%` },
      { trait_type: "Status", value: p.status },
      { trait_type: "Tick Lower", value: `${p.tickLower}` },
      { trait_type: "Tick Upper", value: `${p.tickUpper}` },
      { trait_type: "Tick Spacing", value: `${p.tickSpacing}` },
      { trait_type: "Fee Yield Current Basis", value: formatBpsAsPercentString(p.lifetimeYieldBps) },
      { trait_type: "Annualized Fee Yield Estimate", value: formatBpsAsPercentString(p.annualizedYieldBps) },
      // self-locating: chain + contract + id (+ pool identity)
      { trait_type: "Chain Id", value: "1" },
      { trait_type: "NFT Contract", value: SAMPLE_NFT },
      { trait_type: "Token Id", value: p.tokenIdHex },
      { trait_type: "Hook", value: SAMPLE_HOOK },
      { trait_type: "Pool Id", value: `0x${(idx + 1).toString(16).padStart(64, "0")}` },
    ],
  };
}

function renderGallery(items) {
  const figures = items.map(({ p, svg }, i) => `      <figure>
        ${svg}
        <figcaption><strong>#${i + 1}</strong> &mdash; ${p.label}</figcaption>
      </figure>`).join("\n");

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>SafeSwap NFT — layout stress test</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=Roboto+Mono:wght@400;500;700&display=swap" rel="stylesheet">
  <style>
    body { margin: 0; background: #0b1118; color: #e7eef6;
      font-family: Inter, ui-sans-serif, system-ui, sans-serif; }
    main { max-width: 1240px; margin: 0 auto; padding: 32px; }
    h1 { margin: 0 0 4px; font-size: 22px; }
    p { margin: 0 0 28px; color: #8a97a6; font-size: 14px; }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(350px, 1fr)); gap: 28px; align-items: start; }
    figure { margin: 0; }
    figure svg { display: block; border-radius: 24px; box-shadow: 0 18px 50px rgba(0,0,0,0.45); }
    figcaption { margin-top: 12px; font-size: 13px; color: #9fb0c0; }
  </style>
</head>
<body>
  <main>
    <h1>SafeSwap LP NFT — layout stress test</h1>
    <p>Generated from <code>script/render-nft-examples.mjs</code> (mirrors <code>SafeSwapPositionDescriptor</code>, layout = reference9).</p>
    <div class="grid">
${figures}
    </div>
  </main>
</body>
</html>
`;
}

mkdirSync(outDir, { recursive: true });

const items = examples.map((p, i) => {
  const svg = renderSvg(p);
  const metadata = renderMetadata(p, i, svg);
  writeFileSync(join(outDir, `example-${i + 1}.svg`), svg);
  writeFileSync(join(outDir, `example-${i + 1}.json`), `${JSON.stringify(metadata, null, 2)}\n`);
  return { p, svg };
});

writeFileSync(join(outDir, "index.html"), renderGallery(items));
console.log(`Rendered ${examples.length} cards + index.html to ${outDir}/`);
