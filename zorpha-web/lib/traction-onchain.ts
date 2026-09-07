import { activeChain } from '@/lib/chains';
import { contracts, ZERO_ADDRESS } from '@/lib/contracts';
// VESTING_ONCHAIN carries the governance Safe address, which is not in
// `contracts` because it is an owner rather than a deployment. Taken from the
// schedule that names it as sole beneficiary rather than copied a third time.
import { TOKEN, VESTING_ONCHAIN } from '@/lib/tokenomics';

/**
 * What the buyback and the vaults have actually DONE, as opposed to what they
 * are designed to do.
 *
 * WHY THIS EXISTS
 *
 * The token page describes a mechanism: vaults charge a performance fee, half
 * of it buys ZOR on the open market and burns it, and the burn is a real
 * `totalSupply` reduction. Every sentence of that is true about the contracts.
 * None of it had happened.
 *
 * A reader doing diligence asked, reasonably, how much buyback and burn had
 * occurred since launch and what the real external TVL was. The answers were
 * zero and zero, and the page offered no way to find that out: a hero stat
 * reading "Fees to burn 50%" next to "Of all protocol revenue" reads as a
 * figure being reported, not a policy awaiting its first dollar.
 *
 * So the actuals are read from the chain and rendered beside the design. The
 * burn is exact and unfalsifiable, because a burn is the only way
 * `totalSupply` can move on a token with no mint function: whatever is missing
 * from one billion was destroyed, and nothing else can produce that number.
 *
 * THE POINT OF READING RATHER THAN WRITING
 *
 * Typed prose saying "no revenue yet" is wrong the day the first fee lands,
 * and nobody edits a paragraph they are proud of. These figures correct
 * themselves: the first real deposit moves `externalPct` off zero without
 * anyone touching this file, and the first burn moves `burnedZor`.
 *
 * Follows lib/custody-onchain.ts: plain fetch with `next.revalidate` rather
 * than viem, because viem's transport sets `cache: 'no-store'` and would opt
 * /token out of static rendering, turning one shared read per five minutes
 * into three eth_calls per pageview.
 */

export type TractionSource = 'chain' | 'unavailable';

export interface TractionReading {
  /** Tokens destroyed since launch. Max supply minus current total supply. */
  burnedZor: number;
  /** Performance fee accrued and not yet paid out, in the vault's asset units. */
  feeAccruedRaw: bigint;
  /**
   * Share of the flagship vault's shares held by anyone other than the
   * governance Safe, as a percentage. Zero means every deposit is the
   * protocol's own seed capital.
   */
  externalPct: number;
  source: TractionSource;
  /** Why the chain was not used. Null when it was. */
  reason: string | null;
}

/** How long a reading is reused. Matches `revalidate` on /token. */
const CACHE_SECONDS = 300;

const UNAVAILABLE: Omit<TractionReading, 'reason'> = {
  burnedZor: 0,
  feeAccruedRaw: 0n,
  externalPct: 0,
  source: 'unavailable',
};

export async function readTraction(): Promise<TractionReading> {
  const { zor, spotVault } = contracts;

  const unset = [
    zor === ZERO_ADDRESS ? 'the token' : null,
    spotVault === ZERO_ADDRESS ? 'the vault' : null,
  ].filter((x): x is string => x !== null);

  if (unset.length > 0) {
    return { ...UNAVAILABLE, reason: `no address is configured for ${unset.join(', ')}` };
  }

  const rpc = activeChain.rpcUrls.default.http[0];

  /** One `eth_call`, cacheable, so the route stays statically rendered. */
  const call = async (to: string, data: string): Promise<bigint> => {
    const res = await fetch(rpc, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_call', params: [{ to, data }, 'latest'] }),
      next: { revalidate: CACHE_SECONDS },
    });
    if (!res.ok) throw new Error(`RPC returned HTTP ${res.status}`);
    const json = (await res.json()) as { result?: string; error?: { message: string } };
    if (json.error) throw new Error(json.error.message);
    if (!json.result) throw new Error('RPC returned no result');
    return BigInt(json.result);
  };

  const balanceOfCall = (holder: string) =>
    `0x70a08231${holder.slice(2).toLowerCase().padStart(64, '0')}`;

  try {
    const [supply, feeAccruedRaw, vaultShares, safeShares] = await Promise.all([
      call(zor, '0x18160ddd'), // totalSupply()
      call(spotVault, '0x70a63a85'), // performanceFeeAccrued()
      call(spotVault, '0x18160ddd'), // totalSupply()
      call(spotVault, balanceOfCall(VESTING_ONCHAIN.beneficiary)),
    ]);

    /**
     * A burn is the only thing that can move this. ZorphaToken has no mint
     * function, so any shortfall against max supply was destroyed.
     */
    const burnedZor = TOKEN.maxSupply - Number(supply / 10n ** 18n);

    /**
     * An empty vault is not 100% externally held. Guarded because the naive
     * `1 - safe/total` reads as fully external at zero supply, which would put
     * the most flattering possible number on the page in exactly the state
     * where it is least earned.
     */
    const externalPct =
      vaultShares === 0n
        ? 0
        : Math.max(0, (1 - Number(safeShares) / Number(vaultShares)) * 100);

    return { burnedZor, feeAccruedRaw, externalPct, source: 'chain', reason: null };
  } catch (err) {
    // Logged rather than swallowed, for the same reason custody-onchain does:
    // an outage that quietly rendered zeros would be indistinguishable from
    // the truth, and here the zeros happen to be the truth, which is precisely
    // why an unreported failure would be impossible to catch.
    const message = err instanceof Error ? err.message : String(err);
    console.error('[traction] chain read failed:', message);
    return { ...UNAVAILABLE, reason: 'the RPC did not answer' };
  }
}
