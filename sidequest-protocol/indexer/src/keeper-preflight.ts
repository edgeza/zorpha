/**
 * The oracle keeper's startup checks, separated from the process that runs them.
 *
 * WHY THIS IS ITS OWN MODULE
 *
 * `oracle-keeper.ts` validates its environment at module scope and calls
 * `process.exit` when something is missing, which is right for a service whose
 * only sane response to a bad config is to refuse to start -- and which also
 * makes the file impossible to import from a test. So the checks that decide
 * whether the keeper may run lived in a function nothing could execute except
 * the keeper itself, and the diagnoses they produce were verified by reading
 * them. Those diagnoses are the entire value of the checks: the incident that
 * motivated them was not a failure to detect a problem, it was eight restarts
 * blaming four unrelated functions for one swapped variable.
 *
 * Nothing here reads the environment, logs, or exits. It takes what it needs,
 * asks the chain through a narrow interface, and returns a verdict. The keeper
 * supplies the real chain and turns a verdict into a log line and an exit code;
 * a test supplies a fake one and reads the verdict directly.
 */

import type { Address, Hex } from 'viem';

/** The two Robinhood Chain deployments. They differ by one digit. */
export const MAINNET_CHAIN_ID = 4663;
export const TESTNET_CHAIN_ID = 46630;

/** What the keeper was configured to be. */
export interface KeeperEnvironment {
  /** The chain id the operator says this is. */
  chainId: number;
  /** Only ever logged, never called from here -- it is the variable nobody suspects. */
  rpcUrl: string;
  oracle: Address;
  /** The address the keeper signs with. */
  keeper: Address;
}

/**
 * The chain, reduced to the four questions startup actually asks of it.
 *
 * Narrow on purpose. A wider seam would tempt a check into reaching for
 * something else, and the point of this interface is that a fake implementing
 * it is obviously complete.
 */
export interface ChainReader {
  getChainId(): Promise<number>;
  getBytecode(address: Address): Promise<Hex | undefined>;
  getBalance(address: Address): Promise<bigint>;
  readOracle<T>(functionName: string, args?: readonly unknown[]): Promise<T>;
}

/** Something true but not disqualifying. The keeper starts and says it anyway. */
export interface KeeperWarning {
  code: 'single-updater';
  message: string;
  fields: Record<string, unknown>;
}

/** Everything startup learned, for the "keeper ready" line and the run loop. */
export interface KeeperReady {
  chainId: number;
  decimals: number;
  maxStaleness: bigint;
  minQuorum: bigint;
  updaterCount: bigint;
}

export type KeeperCheck =
  | { ok: true; ready: KeeperReady; warnings: KeeperWarning[] }
  | {
      ok: false;
      /** Stable code, so a test asserts on the fault rather than the prose. */
      code:
        | 'chain-id-mismatch'
        | 'oracle-not-a-contract'
        | 'keeper-lacks-updater-role'
        | 'keeper-has-no-gas';
      message: string;
      fields: Record<string, unknown>;
    };

/**
 * Decide whether the keeper may run.
 *
 * The order is not arbitrary. Every check after the first reads something from
 * the chain and decides what it means, and none of them can mean anything until
 * it is settled WHICH chain answered -- so the chain id is established first and
 * alone. Getting this backwards is what made a wrong `RPC_URL` present itself as
 * a bad `ORACLE_ADDRESS`.
 */
export async function checkKeeper(
  env: KeeperEnvironment,
  chain: ChainReader,
): Promise<KeeperCheck> {
  const actualChainId = await chain.getChainId();
  if (actualChainId !== env.chainId) {
    return {
      ok: false,
      code: 'chain-id-mismatch',
      message: 'chain id mismatch, refusing to keep an oracle on the wrong chain',
      fields: {
        expected: env.chainId,
        actual: actualChainId,
        rpcUrl: env.rpcUrl,
        hint:
          actualChainId === MAINNET_CHAIN_ID
            ? `RPC_URL serves mainnet ${MAINNET_CHAIN_ID}, which has no oracle to keep. Point it at testnet ${TESTNET_CHAIN_ID}.`
            : `RPC_URL serves ${actualChainId}, not the CHAIN_ID this keeper was configured with. The two Robinhood Chain ids differ by one digit: ${MAINNET_CHAIN_ID} mainnet, ${TESTNET_CHAIN_ID} testnet.`,
      },
    };
  }

  // One eth_getCode separates "not a contract" from "wrong contract". Without
  // it every subsequent read fails as `returned no data ("0x")` and blames
  // whichever function happened to settle first.
  const code = await chain.getBytecode(env.oracle);
  if (!code || code === '0x') {
    const swapped = env.oracle.toLowerCase() === env.keeper.toLowerCase();
    return {
      ok: false,
      code: 'oracle-not-a-contract',
      message: 'ORACLE_ADDRESS is not a contract on this chain',
      fields: {
        oracle: env.oracle,
        chainId: env.chainId,
        hint: swapped
          ? 'this is the KEEPER address -- ORACLE_ADDRESS and ORACLE_KEEPER_PRIVATE_KEY have been swapped'
          : 'check the address, and that it is deployed on this chain',
      },
    };
  }

  const [role, maxStaleness, minQuorum, updaterCount, decimals] = await Promise.all([
    chain.readOracle<Hex>('UPDATER_ROLE'),
    chain.readOracle<bigint>('maxStaleness'),
    chain.readOracle<bigint>('minQuorum'),
    chain.readOracle<bigint>('updaterCount'),
    chain.readOracle<number>('decimals'),
  ]);

  // Checked at startup rather than discovered on the first send, when the only
  // symptom would be a revert every refresh interval forever.
  const permitted = await chain.readOracle<boolean>('hasRole', [role, env.keeper]);
  if (!permitted) {
    return {
      ok: false,
      code: 'keeper-lacks-updater-role',
      message: 'this key does not hold UPDATER_ROLE on the oracle',
      fields: { keeper: env.keeper, oracle: env.oracle },
    };
  }

  const balance = await chain.getBalance(env.keeper);
  if (balance === 0n) {
    return {
      ok: false,
      code: 'keeper-has-no-gas',
      message: 'keeper has no gas',
      fields: { keeper: env.keeper },
    };
  }

  const warnings: KeeperWarning[] = [];
  if (updaterCount <= 1n) {
    warnings.push({
      code: 'single-updater',
      message: 'a single updater against this quorum has no redundancy and no median',
      fields: { updaters: Number(updaterCount), minQuorum: Number(minQuorum) },
    });
  }

  return {
    ok: true,
    ready: { chainId: actualChainId, decimals, maxStaleness, minQuorum, updaterCount },
    warnings,
  };
}
