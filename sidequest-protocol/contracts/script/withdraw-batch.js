#!/usr/bin/env node
/*
 * Safe batch that fully exits Uniswap V3 position `TOKEN_ID`:
 * decreaseLiquidity(all) -> collect(everything, to the Safe) -> burn the NFT.
 * Encodes calldata only; never signs.
 */
const fs = require('fs');
const NPM_ = '0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3';
const SAFE = '0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4';
const TOKEN_ID  = BigInt(process.env.TOKEN_ID  || '1027313');
const LIQUIDITY = BigInt(process.env.LIQUIDITY || '102587694505467941');
const OUT = process.env.OUT || 'safe-batches';
const BURN = process.env.BURN !== '0';

const pad  = h => h.replace(/^0x/, '').padStart(64, '0');
const num  = n => pad(BigInt(n).toString(16));
const addr = a => pad(a.toLowerCase());
const MAX128 = (1n << 128n) - 1n;
const deadline = Math.floor(Date.now() / 1000) + 7200;

const txs = [
  { to: NPM_, value: '0', note: `decreaseLiquidity: burn all ${LIQUIDITY} liquidity from #${TOKEN_ID}`,
    data: '0x0c49ccbe' + num(TOKEN_ID) + num(LIQUIDITY) + num(0) + num(0) + num(deadline) },
  { to: NPM_, value: '0', note: 'collect: sweep both tokens + fees to the Safe',
    data: '0xfc6f7865' + num(TOKEN_ID) + addr(SAFE) + num(MAX128) + num(MAX128) },
];
if (BURN) txs.push({ to: NPM_, value: '0', note: 'burn the now-empty position NFT', data: '0x42966c68' + num(TOKEN_ID) });

fs.mkdirSync(OUT, { recursive: true });
const file = `${OUT}/5-withdraw-position-${TOKEN_ID}.json`;
fs.writeFileSync(file, JSON.stringify({ version: '1.0', chainId: '4663', createdAt: Date.now(),
  meta: { name: `5 - Exit LP position #${TOKEN_ID}`, description: txs.map(t => t.note).join('; '), txBuilderVersion: '1.16.5' },
  transactions: txs.map(({ to, value, data }) => ({ to, value, data, contractMethod: null, contractInputsValues: null })) }, null, 2));
txs.forEach((t, i) => console.log(`  [${i}] ${t.note}`));
console.log(`\nwrote ${file}`);
