import { activeChain } from '@/lib/chains';
import { contracts, ZERO_ADDRESS } from '@/lib/contracts';
import { custodyFrom, LAST_MEASURED, type CustodyLine } from '@/lib/tokenomics';

export type CustodySource = 'chain' | 'last-measured';

export interface CustodyReading {
  lines: CustodyLine[];
  source: CustodySource;
  /** Why the chain was not used. Null when it was. */
  reason: string | null;
}

/** How long a custody read is reused. Matches `revalidate` on /token. */
const CACHE_SECONDS = 300;

/**
 * Custody read from the chain, for server components that can await.
 *
 * The /token page is headed "What the chain actually holds" and its lede tells
 * the reader to verify the table on a block explorer. This is what makes that
 * literally true rather than true-on-the-day-it-was-typed.
 *
 * WHY PLAIN FETCH AND NOT VIEM
 *
 * viem's http transport sets `cache: 'no-store'`, which opts the calling route
 * out of static rendering entirely. /token stopped emitting prerendered HTML
 * and became fully dynamic, so every single pageview would have fired three
 * eth_calls at the public RPC: slower for the reader, needless load on a node
 * this project does not run, and one hiccup away from showing the fallback
 * banner to a visitor. `next.revalidate` restores the intended shape, which is
 * one read per five minutes shared by everyone.
 *
 * EVERY ADDRESS IS CHECKED, not just the token and the Safe.
 *
 * The first version guarded `zor` and `safe` and read `vesting` and `insurance`
 * unchecked. `normalise` in lib/contracts.ts returns the zero address for an
 * unset or malformed env var, and `balanceOf(0x0)` does not revert, it returns
 * zero. So an unset NEXT_PUBLIC_VESTING_ADDRESS would have rendered
 * "Locked in vesting: 0" and, because circulating is computed as the remainder,
 * "Circulating: 880,000,000" -- 88% where the truth is 8% -- labelled as
 * measured from chain. The table would still have summed to max supply, so
 * nothing about it would have looked wrong. There is a test for that figure.
 *
 * AND THE FALLBACK IS VISIBLE.
 *
 * `source` used to be returned and never rendered, so the doc comment claiming
 * it said so "rather than silently" was not kept by the only caller. It now
 * carries a reason too, and /token renders both.
 */
export async function readCustody(): Promise<CustodyReading> {
  // The Safe is not in `contracts`: it is an owner, not a deployment. Taken
  // from the custody table itself so there is one place naming it.
  const safe = custodyFrom().find((c) => c.label.startsWith('Community airdrop'))!.address as
    | `0x${string}`
    | null;
  const { zor, vesting, insurance } = contracts;

  const unset = [
    zor === ZERO_ADDRESS ? 'the token' : null,
    !safe ? 'the governance Safe' : null,
    vesting === ZERO_ADDRESS ? 'the vesting contract' : null,
    insurance === ZERO_ADDRESS ? 'the insurance fund' : null,
  ].filter((x): x is string => x !== null);

  if (unset.length > 0 || !safe) {
    return {
      lines: custodyFrom(LAST_MEASURED),
      source: 'last-measured',
      reason: `no address is configured for ${unset.join(', ')}`,
    };
  }

  const rpc = activeChain.rpcUrls.default.http[0];

  /** `balanceOf(holder)` by eth_call. Cacheable, so the route stays ISR. */
  const balanceOf = async (holder: string): Promise<bigint> => {
    const data = `0x70a08231${holder.slice(2).toLowerCase().padStart(64, '0')}`;
    const res = await fetch(rpc, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: 1,
        method: 'eth_call',
        params: [{ to: zor, data }, 'latest'],
      }),
      next: { revalidate: CACHE_SECONDS },
    });
    if (!res.ok) throw new Error(`RPC returned HTTP ${res.status}`);
    const json = (await res.json()) as { result?: string; error?: { message: string } };
    if (json.error) throw new Error(json.error.message);
    if (!json.result) throw new Error('RPC returned no result');
    return BigInt(json.result);
  };

  try {
    const [v, s, i] = await Promise.all([
      balanceOf(vesting),
      balanceOf(safe),
      balanceOf(insurance),
    ]);

    // Whole tokens. Truncation cannot unbalance the table: circulating is the
    // remainder, so a token lost to rounding lands there and the four lines
    // still sum to max supply.
    const whole = (x: bigint) => Number(x / 10n ** 18n);

    return {
      lines: custodyFrom({ vesting: whole(v), safe: whole(s), insurance: whole(i) }),
      source: 'chain',
      reason: null,
    };
  } catch (err) {
    // Logged rather than swallowed. A bare catch here would leave a total RPC
    // outage rendering stale figures with no trace anywhere, which is the
    // failure this file exists to remove.
    const message = err instanceof Error ? err.message : String(err);
    console.error('[custody] chain read failed, serving last measured figures:', message);
    return {
      lines: custodyFrom(LAST_MEASURED),
      source: 'last-measured',
      reason: 'the RPC did not answer',
    };
  }
}
