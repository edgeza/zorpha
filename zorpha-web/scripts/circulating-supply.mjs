#!/usr/bin/env node
/**
 * Print $ZOR circulating supply, read from chain, in the form a listing form
 * wants.
 *
 * WHY A SCRIPT AND NOT A NUMBER IN A DOCUMENT
 *
 * docs/listing-submissions.md carried the figure and a warning in bold that it
 * moves and must be recomputed before every submission. The warning was right
 * and it did not help: the file said 23,328,016 and said to report that, and by
 * the time anyone read it the real figure was 27,423,499, because ZOR bought
 * out of the pool leaves the pool and becomes float. At this size one purchase
 * is a large fraction of the float, so any number written down is wrong within
 * days.
 *
 * So the document now points here and carries no figure of its own.
 *
 * WHAT COUNTS AS CIRCULATING, AND WHY IT IS THE STRICTER SENSE
 *
 * CoinGecko excludes anything locked, reserved, or held by the team, treasury
 * or foundation. That means the governance Safe, the insurance fund, the
 * vesting contract, the leader bond, AND the protocol-owned liquidity: the Safe
 * holds those Uniswap LP NFTs and can withdraw them at will, so tokens sitting
 * in the pool are treasury-controlled, not public float.
 *
 * lib/tokenomics.ts uses a broader sense for the website, counting the Safe's
 * own float and protocol-owned liquidity as circulating, and says so in its own
 * note. The two are not in conflict; they answer different questions. Do not
 * copy the site's 8% into a listing form, and do not copy this figure onto the
 * site.
 *
 *   node scripts/circulating-supply.mjs
 *   ZOR_RPC_URL=... node scripts/circulating-supply.mjs
 */

const RPC = process.env.ZOR_RPC_URL ?? 'https://rpc.mainnet.chain.robinhood.com';
const ZOR = '0x9684AFe2422a0B03719201c78959b6B70e8d4ae8';
const TOTAL = 1_000_000_000n;

/**
 * Every holder that is not public float.
 *
 * Adding one here is the whole maintenance burden of this script. If the
 * protocol ever holds ZOR somewhere new -- a second pool, a staking contract,
 * a new treasury -- it belongs on this list, or the figure overstates the
 * float by that balance.
 */
const EXCLUDED = [
  ['ZorphaVesting', '0x81613D9914F7b4c02c897941757a99BC191De88e', 'non-revocable lock'],
  ['MerkleDistributor', '0x1045AeCaCad091eC791815Be8c28DA12Ed94D4E3', 'airdrop, claimed out 6 Sep'],
  ['InsuranceFund', '0x9D3B787a3492b4fe6D2a2C12062a4164263522Fd', 'governance release only'],
  ['governance Safe', '0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4', 'treasury, incl. Season 1 tranche'],
  ['ZOR/USDG pool', '0x42AeA5CF1534498Db2f66F14bB9B9BeD2aB98d8d', 'protocol-owned liquidity, Safe holds the LP NFTs'],
  ['VaultLauncher', '0x9eD12842A222aeD986E768b3D50aDCf89691159A', 'leader bond, locked'],
];

async function balanceOf(holder) {
  const data = `0x70a08231${holder.slice(2).toLowerCase().padStart(64, '0')}`;
  const res = await fetch(RPC, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      jsonrpc: '2.0',
      id: 1,
      method: 'eth_call',
      params: [{ to: ZOR, data }, 'latest'],
    }),
  });
  if (!res.ok) throw new Error(`RPC returned HTTP ${res.status} for ${holder}`);
  const json = await res.json();
  if (json.error) throw new Error(`${holder}: ${json.error.message}`);
  // Whole tokens. Every balance here is a round number of them.
  return BigInt(json.result) / 10n ** 18n;
}

const fmt = (n) => n.toLocaleString('en-US');
const pad = (s, n) => String(s).padStart(n);

try {
  const onChainTotal = (await (async () => {
    const res = await fetch(RPC, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: 1,
        method: 'eth_call',
        // totalSupply()
        params: [{ to: ZOR, data: '0x18160ddd' }, 'latest'],
      }),
    });
    const j = await res.json();
    if (j.error) throw new Error(j.error.message);
    return BigInt(j.result) / 10n ** 18n;
  })());

  if (onChainTotal !== TOTAL) {
    console.error(
      `total supply is ${fmt(onChainTotal)}, not the ${fmt(TOTAL)} this script assumes. ` +
        'ZOR has no mint function, so this should be impossible: check the address.',
    );
    process.exit(1);
  }

  const rows = [];
  let excluded = 0n;
  for (const [label, address, why] of EXCLUDED) {
    const bal = await balanceOf(address);
    excluded += bal;
    rows.push([label, bal, why]);
  }
  const circulating = onChainTotal - excluded;

  console.log(`\n$ZOR circulating supply, read from ${RPC}`);
  console.log(`as of ${new Date().toISOString()}\n`);
  console.log(`  ${'total supply'.padEnd(22)} ${pad(fmt(onChainTotal), 15)}`);
  console.log(`  ${'max supply'.padEnd(22)} ${pad(fmt(onChainTotal), 15)}   fixed, no mint function`);
  console.log('');
  for (const [label, bal, why] of rows) {
    console.log(`  ${('- ' + label).padEnd(22)} ${pad(fmt(bal), 15)}   ${why}`);
  }
  console.log('  ' + '-'.repeat(40));
  const pct = (Number(circulating) / Number(onChainTotal)) * 100;
  console.log(`  ${'CIRCULATING'.padEnd(22)} ${pad(fmt(circulating), 15)}   ${pct.toFixed(2)}% of supply`);
  console.log('\nReport the CIRCULATING figure. Do not report the website\'s 8%, which');
  console.log('counts the Safe float and protocol-owned liquidity and answers a');
  console.log('different question. See the header of this file.\n');
} catch (err) {
  console.error(`\nfailed: ${err.message}\n`);
  console.error('Nothing is printed rather than a guess, because the only reason to run');
  console.error('this is to put a number on a public listing form.\n');
  process.exit(1);
}
