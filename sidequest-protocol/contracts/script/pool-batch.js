#!/usr/bin/env node
/*
 * Emits a Safe Transaction Builder batch that creates and seeds a ZOR pool on
 * Uniswap V3 (Robinhood Chain, 4663). Encodes calldata only -- never signs.
 *
 *   QUOTE=usdg QUOTE_SEED=50   ZOR_SEED=5000000  node script/pool-batch.js
 *   QUOTE=weth QUOTE_SEED=0.03 ZOR_SEED=10000000 node script/pool-batch.js
 *   MODE=single ZOR_SEED=50000000 node script/pool-batch.js     # no quote needed
 *
 * QUOTE=usdg is the chain convention: essentially all real volume on 4663 is
 * TOKEN/USDG, and a USDG pair prices directly in USD on screeners.
 */
const fs = require('fs');

const T = {
  zor:  { addr: '0x9684AFe2422a0B03719201c78959b6B70e8d4ae8', dec: 18, sym: 'ZOR'  },
  weth: { addr: '0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73', dec: 18, sym: 'WETH' },
  usdg: { addr: '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168', dec: 6,  sym: 'USDG' },
};
const NPM_ = '0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3';
const SAFE = '0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4';

const QUOTE      = (process.env.QUOTE || 'usdg').toLowerCase();
const FEE        = Number(process.env.FEE || 10000);
const SPACING    = { 100: 1, 500: 10, 3000: 60, 10000: 200 }[FEE];
const MODE       = process.env.MODE || 'both';
const ZOR_SEED   = process.env.ZOR_SEED  || '5000000';
const QUOTE_SEED = process.env.QUOTE_SEED || (QUOTE === 'usdg' ? '50' : '0.03');
const ETH_USD    = Number(process.env.ETH_USD || 2455.98);
const RANGE_X    = Number(process.env.RANGE_X || 10);
const OUT        = process.env.OUT || 'safe-batches';
if (!SPACING) throw new Error('bad FEE');
const q = T[QUOTE]; if (!q || QUOTE === 'zor') throw new Error('QUOTE must be usdg or weth');

const units = (s, d) => { const [a, b = ''] = String(s).split('.'); return BigInt(a) * 10n ** BigInt(d) + BigInt((b + '0'.repeat(d)).slice(0, d)); };
const zorAmt = units(ZOR_SEED, T.zor.dec);
const qAmt   = units(QUOTE_SEED, q.dec);

// token0 = lower address
const zorIs0 = T.zor.addr.toLowerCase() < q.addr.toLowerCase();
const token0 = zorIs0 ? T.zor : q, token1 = zorIs0 ? q : T.zor;
const amount0 = zorIs0 ? zorAmt : qAmt, amount1 = zorIs0 ? qAmt : zorAmt;

const isqrt = n => { if (n < 2n) return n; let x = n, y = (x + 1n) / 2n; while (y < x) { x = y; y = (x + n / x) / 2n; } return x; };

// START_PRICE (quote tokens per 1 whole ZOR) sets the pool price INDEPENDENTLY
// of the seed amounts. That separation matters for MODE=band: in a band the
// required token ratio is not the price ratio, so deriving price from the seed
// amounts -- correct for full range -- would misprice the pool.
const SP = process.env.START_PRICE;
let sqrtPriceX96;
if (SP) {
  // Keep START_PRICE as an exact rational num/den. Rounding it to quote raw
  // units first loses precision badly against a 6dp quote: 0.00000936 USDG is
  // 9.36 raw units and truncates to 9 -- a 4% mispricing, far worse for
  // cheaper tokens. den cancels analytically, so nothing is lost here.
  const [ip, fp = ''] = String(SP).split('.');
  const num = BigInt((ip || '0') + fp);
  const den = 10n ** BigInt(fp.length);
  if (num === 0n) throw new Error('START_PRICE must be > 0');
  const oneZor = 10n ** BigInt(T.zor.dec), oneQ = 10n ** BigInt(q.dec);
  sqrtPriceX96 = zorIs0
    ? isqrt((num * oneQ << 192n) / (den * oneZor))
    : isqrt((oneZor * den << 192n) / (num * oneQ));
} else {
  sqrtPriceX96 = isqrt((amount1 * (1n << 192n)) / amount0);
}
const MIN_SQRT = 4295128739n, MAX_SQRT = 1461446703485210103287273052203988822378723970342n;
if (sqrtPriceX96 <= MIN_SQRT || sqrtPriceX96 >= MAX_SQRT) throw new Error('sqrtPriceX96 out of Uniswap bounds');

const MIN_TICK = -887272, MAX_TICK = 887272;
const floorT = t => Math.floor(t / SPACING) * SPACING;
const ceilT  = t => Math.ceil(t / SPACING) * SPACING;
const MIN_T = ceilT(MIN_TICK), MAX_T = floorT(MAX_TICK);
const spotRaw = Math.pow(Number(sqrtPriceX96) / 2 ** 96, 2);
const curTick = Math.floor(Math.log(spotRaw) / Math.log(1.0001));

// A V3 position is 100% token1 only when spot is at/above the range, and 100%
// token0 only when spot is at/below it. So a ZOR-only (no-quote) position sits
// BELOW spot when ZOR is token1, and ABOVE spot when ZOR is token0.
const RANGE_TICKS = Math.round(Math.log(RANGE_X) / Math.log(1.0001));
const RANGE_DOWN = Number(process.env.RANGE_DOWN || 0.5);  // band floor, x of start price
const RANGE_UP   = Number(process.env.RANGE_UP   || 5);    // band ceiling, x of start price
// ticks move with the RAW price token1/token0. When ZOR is token1 a rising ZOR
// price means FEWER ZOR per quote, so the raw price falls and the tick drops --
// the band bounds invert. When ZOR is token0 they don't.
const tickAtZorMultiple = m => {
  const t = Math.log(m) / Math.log(1.0001);
  return zorIs0 ? curTick + t : curTick - t;
};
let tickLower, tickUpper;
if (MODE === 'single') {
  if (!zorIs0) { tickUpper = floorT(curTick) - SPACING; tickLower = Math.max(MIN_T, floorT(curTick - RANGE_TICKS)); }
  else         { tickLower = floorT(curTick) + SPACING; tickUpper = Math.min(MAX_T, ceilT(curTick + RANGE_TICKS)); }
} else if (MODE === 'band') {
  const a = tickAtZorMultiple(RANGE_DOWN), b = tickAtZorMultiple(RANGE_UP);
  tickLower = Math.max(MIN_T, floorT(Math.min(a, b)));
  tickUpper = Math.min(MAX_T, ceilT(Math.max(a, b)));
} else { tickLower = MIN_T; tickUpper = MAX_T; }
if (tickLower >= tickUpper) throw new Error('empty tick range');
if (tickLower < MIN_TICK || tickUpper > MAX_TICK) throw new Error('tick out of bounds');

const pad  = h => h.replace(/^0x/, '').padStart(64, '0');
const addr = a => pad(a.toLowerCase());
const num  = n => pad(BigInt(n).toString(16));
const int  = n => { const v = BigInt(n); return pad((v < 0n ? (1n << 256n) + v : v).toString(16)); };
const sel  = { approve: '0x095ea7b3', deposit: '0xd0e30db0', create: '0x13ead562', mint: '0x88316456' };
const DEADLINE_HOURS = Number(process.env.DEADLINE_HOURS || 48);
const deadline = Math.floor(Date.now() / 1000) + DEADLINE_HOURS * 3600;

// amountMin protection. With min=0 a hostile pool created first at a different
// price would make createAndInitializePoolIfNecessary a silent no-op and the
// mint would deposit at THEIR price. Non-zero minimums make it revert instead.
const MIN_PCT = Number(process.env.MIN_PCT || 97) / 100;
const rawPrice = Math.pow(Number(sqrtPriceX96) / 2 ** 96, 2);
let exp0 = Number(amount0), exp1 = Number(amount1);
if (MODE === 'both') {                       // full range: ratio == price ratio
  exp0 = Math.min(Number(amount0), Number(amount1) / rawPrice);
  exp1 = Math.min(Number(amount1), Number(amount0) * rawPrice);
}
const min0 = MODE === 'single' ? 0n : BigInt(Math.floor(exp0 * MIN_PCT));
const min1 = BigInt(Math.floor(exp1 * MIN_PCT));

const txs = [];
if (MODE !== 'single') {
  if (QUOTE === 'weth') txs.push({ to: q.addr, value: qAmt.toString(), data: sel.deposit, note: `wrap ${QUOTE_SEED} ETH -> WETH` });
  txs.push({ to: q.addr, value: '0', data: sel.approve + addr(NPM_) + num(qAmt), note: `approve ${q.sym} to position manager` });
}
txs.push({ to: T.zor.addr, value: '0', data: sel.approve + addr(NPM_) + num(zorAmt), note: 'approve ZOR to position manager' });
txs.push({ to: NPM_, value: '0', data: sel.create + addr(token0.addr) + addr(token1.addr) + num(FEE) + num(sqrtPriceX96), note: `create + initialize ZOR/${q.sym} ${FEE/10000}% pool` });
const d0 = MODE === 'single' ? (zorIs0 ? amount0 : 0n) : amount0;
const d1 = MODE === 'single' ? (zorIs0 ? 0n : amount1) : amount1;
txs.push({ to: NPM_, value: '0', note: 'mint position (owner = Safe)',
  data: sel.mint + addr(token0.addr) + addr(token1.addr) + num(FEE) + int(tickLower) + int(tickUpper)
       + num(d0) + num(d1) + num(min0) + num(min1) + addr(SAFE) + num(deadline) });

fs.mkdirSync(OUT, { recursive: true });
const file = `${OUT}/4-create-pool-${QUOTE}-${MODE}.json`;
fs.writeFileSync(file, JSON.stringify({ version: '1.0', chainId: '4663', createdAt: Date.now(),
  meta: { name: `4 - ZOR/${q.sym} ${FEE/10000}% pool (${MODE})`, description: txs.map(t => t.note).join('; '), txBuilderVersion: '1.16.5' },
  transactions: txs.map(({ to, value, data }) => ({ to, value, data, contractMethod: null, contractInputsValues: null })) }, null, 2));

const quoteUsd = QUOTE === 'usdg' ? 1 : ETH_USD;
const priceUsd = (SP ? Number(SP) : Number(QUOTE_SEED) / Number(ZOR_SEED)) * quoteUsd;
console.log(`pair ZOR/${q.sym}  fee ${FEE/10000}%  mode ${MODE}  token0=${token0.sym}(${token0.dec}dp) token1=${token1.sym}(${token1.dec}dp)`);
console.log(`sqrtPriceX96 ${sqrtPriceX96}`);
console.log(`ticks        ${tickLower} .. ${tickUpper} (spacing ${SPACING}, spot tick ${curTick})`);
if (MODE !== 'single') {
  console.log(`seed         ${Number(QUOTE_SEED).toLocaleString()} ${q.sym} + ${Number(ZOR_SEED).toLocaleString()} ZOR`);
  if (MODE === 'band') console.log(`band         $${(priceUsd*RANGE_DOWN).toFixed(8)} .. $${(priceUsd*RANGE_UP).toFixed(8)} per ZOR  (${RANGE_DOWN}x .. ${RANGE_UP}x)`);
  console.log(`start price  $${priceUsd.toFixed(8)} / ZOR      FDV $${(priceUsd*1e9).toLocaleString('en-US',{maximumFractionDigits:0})}`);
} else {
  console.log(`seed         ${Number(ZOR_SEED).toLocaleString()} ZOR only -- no ${q.sym} required`);
  console.log(`start price  $${priceUsd.toFixed(8)} / ZOR (range covers a ${RANGE_X}x rise)`);
}
console.log(`deadline     ${DEADLINE_HOURS}h -> ${new Date(deadline*1000).toISOString().replace('T',' ').slice(0,19)} UTC`);
console.log(`minimums     ${MIN_PCT*100}% -> min0 ${(Number(min0)/10**token0.dec).toFixed(2)} ${token0.sym}, min1 ${(Number(min1)/10**token1.dec).toLocaleString('en-US',{maximumFractionDigits:0})} ${token1.sym}`);
txs.forEach((t, i) => console.log(`  [${i}] ${t.note}`));
console.log(`\nwrote ${file}`);
