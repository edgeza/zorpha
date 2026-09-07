import { createPublicClient, http, erc20Abi } from 'viem';
import { activeChain } from '@/lib/chains';
import { contracts } from '@/lib/contracts';
import { custodyFrom, LAST_MEASURED, type CustodyLine } from '@/lib/tokenomics';

/**
 * Custody read from the chain, for server components that can await.
 *
 * The /token page is headed "What the chain actually holds" and its lede tells
 * the reader to verify the table on a block explorer. This is what makes that
 * literally true rather than true-on-the-day-it-was-typed.
 *
 * Falls back to LAST_MEASURED when the RPC does not answer, and says so in the
 * return value rather than silently. A page that quietly served stale figures
 * under that heading would be the exact failure this file exists to remove; a
 * page that serves them and admits it is honest.
 */
export async function readCustody(): Promise<{
  lines: CustodyLine[];
  source: 'chain' | 'last-measured';
}> {
  const zor = contracts.zor;
  const vesting = contracts.vesting;
  const insurance = contracts.insurance;

  // The Safe is not in `contracts`: it is an owner, not a deployment. Taken
  // from the custody table itself so there is one place naming it.
  const safe = custodyFrom()
    .find((c) => c.label.startsWith('Community airdrop'))!
    .address as `0x${string}` | null;

  if (!safe || zor === '0x0000000000000000000000000000000000000000') {
    return { lines: custodyFrom(), source: 'last-measured' };
  }

  try {
    const client = createPublicClient({ chain: activeChain, transport: http() });
    const read = (holder: `0x${string}`) =>
      client.readContract({
        address: zor,
        abi: erc20Abi,
        functionName: 'balanceOf',
        args: [holder],
      });

    const [v, s, i] = await Promise.all([read(vesting), read(safe), read(insurance)]);
    const whole = (x: bigint) => Number(x / 10n ** 18n);

    return {
      lines: custodyFrom({ vesting: whole(v), safe: whole(s), insurance: whole(i) }),
      source: 'chain',
    };
  } catch {
    return { lines: custodyFrom(LAST_MEASURED), source: 'last-measured' };
  }
}
