#!/usr/bin/env node
/*
 * Emits a Safe Transaction Builder batch that creates and seeds the ZOR/WETH
 * Uniswap V3 pool on Robinhood Chain (4663). Encodes calldata only -- it never
 * signs or sends. Import the JSON at app.safe.global -> Transaction Builder.
 *
 *   node script/pool-batch.js                       # defaults
 *   ETH_SEED=0.03 ZOR_SEED=10000000 node script/pool-batch.js
 *   MODE=single ZOR_SEED=50000000 node script/pool-batch.js
 *
 * MODE=both   (default) full-range two-sided position: needs ETH *and* ZOR.
 * MODE=single ZOR-only position in a range above spot: needs NO ETH.
 */
const fs = require('fs');

const ZOR   = '0x9684AFe2422a0B03719201c78959b6B70e8d4ae8';
const WETH  = '0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73';
const NPM_  = '0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3';
const SAFE  = '0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4';

const FEE      = Number(process.env.FEE || 10000);      // 1%
const SPACING  = FEE === 10000 ? 200 : FEE === 3000 ? 60 : 10;
const ETH_SEED = process.env.ETH_SEED || '0.03';
const ZOR_SEED = process.env.ZOR_SEED || '10000000';
const MODE     = process.env.MODE || 'both';
const ETH_USD  = Number(process.env.ETH_USD || 2455.98);
const OUT      = process.env.OUT || 'safe-batches';

const E18 = 10n ** 18n;
const toWei = s => { const [a, b = ''] = String(s).split('.'); return BigInt(a) * E18 + BigInt((b + '0'.repeat(18)).slice(0, 18)); };

// token0 is the lower address. WETH < ZOR here, so token0=WETH, token1=ZOR.
const token0 = WETH.toLowerCase() < ZOR.toLowerCase() ? WETH : ZOR;
const token1 = token0 === WETH ? ZOR : WETH;
const amount0 = token0 === WETH ? toWei(ETH_SEED) : toWei(ZOR_SEED);
const amount1 = token0 === WETH ? toWei(ZOR_SEED) : toWei(ETH_SEED);

// integer sqrt
function isqrt(n) { if (n < 2n) return n; let x = n, y = (x + 1n) / 2n; while (y < x) { x = y; y = (x + n / x) / 2n; } return x; }
// sqrtPriceX96 = sqrt(amount1/amount0) * 2^96
const sqrtPriceX96 = isqrt((amount1 * (1n << 192n)) / amount0);

const MIN_TICK = -887272, MAX_TICK = 887272;
const floorT = t => Math.floor(t / SPACING) * SPACING;
const ceilT  = t => Math.ceil(t / SPACING) * SPACING;
const MIN_T = ceilT(MIN_TICK), MAX_T = floorT(MAX_TICK);   // stay INSIDE the legal range

// Raw pool price P = token1 per token0 = ZOR per WETH (both 18dp).
// ZOR appreciating in ETH terms means P *falls*.
const priceRatio = Number(amount1) / Number(amount0);
const curTick = Math.floor(Math.log(priceRatio) / Math.log(1.0001));

// A V3 position holds 100% token1 only when the current price is at or ABOVE
// the range. ZOR is token1, so a ZOR-only (no-ETH) position must sit strictly
// BELOW the current tick -- which is exactly the band ZOR trades into as its
// ETH price rises. Putting it above spot would have required WETH instead.
const RANGE_X = Number(process.env.RANGE_X || 10);   // covers a RANGE_X price rise
const RANGE_TICKS = Math.round(Math.log(RANGE_X) / Math.log(1.0001));
const upSingle = floorT(curTick) - SPACING;
const loSingle = Math.max(MIN_T, floorT(curTick - RANGE_TICKS));

const tickLower = MODE === 'single' ? loSingle : MIN_T;
const tickUpper = MODE === 'single' ? upSingle : MAX_T;
if (tickLower >= tickUpper) throw new Error('empty tick range');
if (tickLower < MIN_TICK || tickUpper > MAX_TICK) throw new Error('tick out of bounds');

const pad = (h, n = 64) => h.replace(/^0x/, '').padStart(n, '0');
const addr = a => pad(a.toLowerCase());
const num  = n => pad(BigInt(n).toString(16));
const int  = n => { const v = BigInt(n); return pad((v < 0n ? (1n << 256n) + v : v).toString(16)); };

const deadline = Math.floor(Date.now() / 1000) + 3600;
const sel = {
  approve: '0x095ea7b3', deposit: '0xd0e30db0',
  create: '0x13ead562',  // createAndInitializePoolIfNecessary(address,address,uint24,uint160)
  mint:   '0x88316456',  // mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))
};

const txs = [];
const needEth = MODE === 'both';
if (needEth) {
  txs.push({ to: WETH, value: toWei(ETH_SEED).toString(), data: sel.deposit, note: `wrap ${ETH_SEED} ETH -> WETH` });
  txs.push({ to: WETH, value: '0', data: sel.approve + addr(NPM_) + num(toWei(ETH_SEED)), note: 'approve WETH to position manager' });
}
txs.push({ to: ZOR, value: '0', data: sel.approve + addr(NPM_) + num(toWei(ZOR_SEED)), note: 'approve ZOR to position manager' });
txs.push({ to: NPM_, value: '0', data: sel.create + addr(token0) + addr(token1) + num(FEE) + num(sqrtPriceX96), note: 'create + initialize pool' });
txs.push({
  to: NPM_, value: '0', note: 'mint liquidity position (owner = Safe)',
  data: sel.mint + addr(token0) + addr(token1) + num(FEE) + int(tickLower) + int(tickUpper)
       + num(MODE === 'single' ? 0n : amount0)
       + num(amount1)
       + num(0) + num(0) + addr(SAFE) + num(deadline),
});

fs.mkdirSync(OUT, { recursive: true });
const file = `${OUT}/4-create-pool-${MODE}.json`;
fs.writeFileSync(file, JSON.stringify({
  version: '1.0', chainId: '4663', createdAt: Date.now(),
  meta: { name: `4 - Create ZOR/WETH ${FEE / 10000}% pool (${MODE})`, description: txs.map(t => t.note).join('; '), txBuilderVersion: '1.16.5' },
  transactions: txs.map(({ to, value, data }) => ({ to, value, data, contractMethod: null, contractInputsValues: null })),
}, null, 2));

const priceEthPerZor = Number(toWei(ETH_SEED)) / Number(toWei(ZOR_SEED));
console.log(`mode=${MODE}  fee=${FEE / 10000}%  token0=${token0 === WETH ? 'WETH' : 'ZOR'}`);
console.log(`sqrtPriceX96 = ${sqrtPriceX96}`);
console.log(`ticks        = ${tickLower} .. ${tickUpper} (spacing ${SPACING})`);
if (MODE === 'both') {
  console.log(`seed         = ${ETH_SEED} ETH + ${Number(ZOR_SEED).toLocaleString()} ZOR`);
  console.log(`start price  = $${(priceEthPerZor * ETH_USD).toFixed(8)} / ZOR`);
  console.log(`implied FDV  = $${(priceEthPerZor * ETH_USD * 1e9).toLocaleString('en-US', { maximumFractionDigits: 0 })}`);
} else {
  console.log(`seed         = ${Number(ZOR_SEED).toLocaleString()} ZOR only, no ETH required`);
  console.log(`range ${loSingle}..${upSingle} sits below spot tick ${curTick}: ZOR-only, covers a ${RANGE_X}x rise`);
}
txs.forEach((t, i) => console.log(`  [${i}] ${t.note}`));
console.log(`\nwrote ${file}`);
