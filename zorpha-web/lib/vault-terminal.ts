import type { Address } from 'viem';
import { contracts, ZERO_ADDRESS } from '@/lib/contracts';

/**
 * The manager terminal's model of what a vault is and who may act on it.
 *
 * WHY THIS FILE EXISTS
 *
 * Until now the portal had no way for a manager to operate a vault at all.
 * Depositors could deposit and redeem; a leader could launch a vault through
 * the UI and then had to reach for Foundry, a keystore and a shell to do
 * anything with it. The leader programme's front door was finished before the
 * room behind it existed.
 *
 * THE CONSTRAINT THAT SHAPES EVERYTHING HERE
 *
 * A manager's entire on-chain power is `rebalanceTo(...)` and `evaluateFees()`.
 * There is no buy, no sell, no venue choice, no asset choice. That narrowness
 * is the product: "a track record you can verify" is only true because a
 * manager cannot do anything except move one number inside a slippage bound.
 * So this terminal is not a trading screen. It is the complete set of
 * permitted actions, made fast, with the state you need to choose between them.
 *
 * AND THE ONE THAT SURPRISES PEOPLE
 *
 * A leader who launches a vault holds NO role on it. VaultLauncher grants
 * DEFAULT_ADMIN, RISK_COUNCIL_ROLE and KEEPER_ROLE to `vaultAdmin` -- an
 * immutable governance address fixed at launcher deploy -- and the only two
 * functions gated on `msg.sender == launch.leader` are `reallocate` and
 * `reclaimBond`. That is deliberate, and it is why a leader cannot rug a
 * depositor. But it means a terminal that assumed "launched it, therefore can
 * drive it" would render a screen of buttons that all revert.
 *
 * Hence: every action here is gated on a role READ FROM THE CHAIN for the
 * connected address, and the actions you cannot take are shown with the reason
 * rather than hidden. Hiding them produces the question "where is the
 * rebalance button"; showing them answers it.
 */

// --- Roles -----------------------------------------------------------------
// Hashes rather than a `vault.KEEPER_ROLE()` call per vault per render. These
// are keccak256 of the literal role names and cannot drift without the
// contracts changing the string, which is a breaking change either way.
export const ROLE = {
  admin: '0x0000000000000000000000000000000000000000000000000000000000000000',
  keeper: '0xfc8737ab85eb45125971625a9ebdb75cc78e01d5c1fa80c4c6e5203f47bc4fab',
  riskCouncil: '0x9957de8c5d95da580823ca52e598d0c0d2818cb1f8fd9773a5166d2a45d82b05',
  adapterSetter: '0xed54ff7db9a8ce035eac750f4b17ad29e924c6bb0bc2e0a38976c7f74ef8aeb2',
} as const;

export type RoleKey = keyof typeof ROLE;

export const ROLE_LABEL: Record<RoleKey, string> = {
  admin: 'Admin',
  keeper: 'Keeper',
  riskCouncil: 'Risk council',
  adapterSetter: 'Adapter setter',
};

/** What each role lets you do, in the manager's words rather than the contract's. */
export const ROLE_POWER: Record<RoleKey, string> = {
  admin: 'Claim accrued fees and set the fee recipient.',
  keeper: 'Rebalance the vault, and mark fees to the high-water mark.',
  riskCouncil: 'Halt deposits immediately, and lift the halt.',
  adapterSetter: 'Repoint the vault at a different venue. Timelocked.',
};

// --- Vault kinds -----------------------------------------------------------
// The three differ in exactly one place a manager touches: the shape of
// `rebalanceTo`. Everything else on this screen is common to all of them.

export type VaultKind = 'spot' | 'rotation' | 'yield';

export interface TerminalVault {
  key: string;
  kind: VaultKind;
  address: Address;
  name: string;
  /** What the manager is actually deciding when they rebalance this vault. */
  decision: string;
}

/**
 * The factory vaults, which are the ones with a fixed address in the
 * environment. Launched vaults are discovered per-leader from the launcher at
 * runtime, so they are deliberately not listed here.
 */
export function factoryVaults(): TerminalVault[] {
  const out: TerminalVault[] = [];
  const add = (
    key: string,
    kind: VaultKind,
    address: string | undefined,
    name: string,
    decision: string,
  ) => {
    if (address && address.toLowerCase() !== ZERO_ADDRESS) {
      out.push({ key, kind, address: address as Address, name, decision });
    }
  };
  add(
    'spot',
    'spot',
    contracts.spotVault,
    'Spot',
    'How much of the vault sits in the underlying, and how much in cash.',
  );
  add(
    'rotation',
    'rotation',
    contracts.rotationVault,
    'Rotation',
    'The weight of each basket leg. They must total 100%.',
  );
  add(
    'yield',
    'yield',
    contracts.yieldVault,
    'Yield',
    'Nothing directly — a rebalance here stamps a checkpoint, it moves no funds.',
  );
  return out;
}

export const hasLauncher = () => contracts.vaultLauncher !== ZERO_ADDRESS;

// --- The preview -----------------------------------------------------------

export interface SpotPreview {
  /** Value the vault would hold in the underlying after the move. */
  desiredAsset: bigint;
  currentAsset: bigint;
  /** Absolute size of the move, in the underlying's units. */
  delta: bigint;
  direction: 'buy' | 'sell' | 'none';
  /**
   * TRUE when the move is smaller than `rebalanceThresholdBps` of TVL.
   *
   * This is the trap the preview exists for. Below the threshold the contract
   * writes the new target and RETURNS -- no swap, no `rebalanceCount` bump, no
   * `Rebalanced` event, no receipt. The transaction succeeds and costs gas. A
   * manager who did not know that would sign it, wait for a receipt that never
   * arrives, and have no way to tell a no-op from a failure.
   */
  belowThreshold: boolean;
  /** The floor the swap must clear, derived from `maxSlippageBps`. */
  minOut: bigint;
  currentBps: number;
}

export function previewSpot(args: {
  targetBps: number;
  grossValue: bigint;
  currentAsset: bigint;
  thresholdBps: number;
  slippageBps: number;
}): SpotPreview {
  const { targetBps, grossValue, currentAsset, thresholdBps, slippageBps } = args;
  const bps = BigInt(Math.max(0, Math.min(10000, Math.round(targetBps))));

  if (grossValue === 0n) {
    return {
      desiredAsset: 0n,
      currentAsset,
      delta: 0n,
      direction: 'none',
      belowThreshold: true,
      minOut: 0n,
      currentBps: 0,
    };
  }

  const desiredAsset = (grossValue * bps) / 10000n;
  const delta =
    desiredAsset > currentAsset ? desiredAsset - currentAsset : currentAsset - desiredAsset;

  // The contract's own test, reproduced exactly rather than approximated:
  //   if (diff * 10000 < rebalanceThresholdBps * tvl) { write target; return; }
  const belowThreshold = delta * 10000n < BigInt(thresholdBps) * grossValue;

  const direction: SpotPreview['direction'] =
    delta === 0n || belowThreshold ? 'none' : desiredAsset > currentAsset ? 'buy' : 'sell';

  const minOut = (delta * BigInt(10000 - slippageBps)) / 10000n;
  const currentBps = Number((currentAsset * 10000n) / grossValue);

  return { desiredAsset, currentAsset, delta, direction, belowThreshold, minOut, currentBps };
}

/** Basket weights are valid only if they total exactly 10000. */
export function weightsProblem(weights: number[]): string | null {
  if (weights.some((w) => !Number.isFinite(w) || w < 0)) return 'Every weight must be zero or more.';
  if (weights.some((w) => w > 10000)) return 'No single weight may exceed 100%.';
  const total = weights.reduce((a, b) => a + b, 0);
  if (total !== 10000) {
    const pct = (total / 100).toFixed(2).replace(/\.?0+$/, '');
    return `Weights total ${pct}%. They must total exactly 100%.`;
  }
  return null;
}

// --- Oracle staleness ------------------------------------------------------

export type OracleState =
  | { status: 'fresh'; ageSeconds: number; expiresInSeconds: number }
  | { status: 'expiring'; ageSeconds: number; expiresInSeconds: number }
  | { status: 'stale'; ageSeconds: number; expiresInSeconds: number }
  | { status: 'unknown'; ageSeconds: number; expiresInSeconds: number };

/**
 * `_oraclePrice` reverts with `StaleOracle` once `block.timestamp - updatedAt`
 * exceeds `maxOracleStaleness`, and every rebalance goes through it. Knowing
 * that BEFORE signing is the difference between "not yet, wait for the next
 * report" and an opaque revert after the gas is spent.
 */
export function oracleState(
  updatedAt: bigint | undefined,
  maxStaleness: bigint | undefined,
  now: number,
): OracleState {
  if (updatedAt === undefined || maxStaleness === undefined || updatedAt === 0n) {
    return { status: 'unknown', ageSeconds: 0, expiresInSeconds: 0 };
  }
  const ageSeconds = now - Number(updatedAt);
  const max = Number(maxStaleness);
  const expiresInSeconds = max - ageSeconds;

  if (expiresInSeconds <= 0) return { status: 'stale', ageSeconds, expiresInSeconds: 0 };
  // A tenth of the window is enough time to notice and not enough to start a
  // rebalance you expect to land.
  if (expiresInSeconds < max / 10) return { status: 'expiring', ageSeconds, expiresInSeconds };
  return { status: 'fresh', ageSeconds, expiresInSeconds };
}

export function humanDuration(seconds: number): string {
  const s = Math.max(0, Math.round(seconds));
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m ${s % 60}s`;
  const h = Math.floor(s / 3600);
  return `${h}h ${Math.floor((s % 3600) / 60)}m`;
}
