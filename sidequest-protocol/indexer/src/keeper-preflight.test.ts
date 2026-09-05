/**
 * The oracle keeper's startup checks.
 *
 * These exist because the value of those checks is not detection, it is
 * diagnosis. The incident behind them was not a fault going unnoticed -- the
 * process crash-looped loudly. It was eight restarts blaming four unrelated
 * contract functions for one swapped environment variable. So most of what
 * follows asserts on WHICH fault is reported and what the operator is told to
 * do about it, not merely that something failed.
 *
 * Until now none of it was reachable from a test: the checks lived inside a
 * module that validates its environment at import time and calls process.exit,
 * so importing it from a test killed the test runner. The checks now take a
 * ChainReader, and this file passes a fake one.
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Address, Hex } from 'viem';
import {
  checkKeeper,
  MAINNET_CHAIN_ID,
  TESTNET_CHAIN_ID,
  type ChainReader,
  type KeeperEnvironment,
} from './keeper-preflight.js';

const ORACLE = '0xF2FEb9B3E49890320539CfdEed28dE8A84da03DF' as Address;
const KEEPER = '0x8058A51BA27b7ff951a8b7C9E456deFCfA7e79e5' as Address;
const UPDATER_ROLE = `0x${'ab'.repeat(32)}` as Hex;

const env: KeeperEnvironment = {
  chainId: TESTNET_CHAIN_ID,
  rpcUrl: 'https://rpc.testnet.example/rpc',
  oracle: ORACLE,
  keeper: KEEPER,
};

type FakeOptions = {
  chainId?: number;
  /** Bytecode at the oracle address. '0x' means nothing is deployed there. */
  oracleCode?: Hex;
  balance?: bigint;
  hasRole?: boolean;
  updaterCount?: bigint;
  minQuorum?: bigint;
};

/** Records what was asked, so a test can assert on what was NOT asked. */
function fakeChain(options: FakeOptions = {}) {
  const calls: string[] = [];
  const reader: ChainReader = {
    async getChainId() {
      calls.push('getChainId');
      return options.chainId ?? TESTNET_CHAIN_ID;
    },
    async getBytecode() {
      calls.push('getBytecode');
      return options.oracleCode ?? ('0x60806040' as Hex);
    },
    async getBalance() {
      calls.push('getBalance');
      return options.balance ?? 10n ** 17n;
    },
    async readOracle<T>(functionName: string): Promise<T> {
      calls.push(`readOracle:${functionName}`);
      const table: Record<string, unknown> = {
        UPDATER_ROLE,
        maxStaleness: 3600n,
        minQuorum: options.minQuorum ?? 1n,
        updaterCount: options.updaterCount ?? 2n,
        decimals: 8,
        hasRole: options.hasRole ?? true,
      };
      return table[functionName] as T;
    },
  };
  return { reader, calls };
}

function failure(result: Awaited<ReturnType<typeof checkKeeper>>) {
  assert.equal(result.ok, false, 'expected the keeper to be refused');
  if (result.ok) throw new Error('unreachable');
  return result;
}

// --- the ordering, which is the whole point --------------------------------

test('a wrong chain is reported as a wrong chain, not as a missing oracle', async () => {
  // Both faults are present: the RPC serves the other deployment AND the
  // oracle has no code there. Only one of them is the cause, and reporting the
  // other sends the operator to inspect an address that was never wrong.
  const { reader, calls } = fakeChain({ chainId: MAINNET_CHAIN_ID, oracleCode: '0x' });
  const result = failure(await checkKeeper(env, reader));

  assert.equal(result.code, 'chain-id-mismatch');
  assert.ok(
    !calls.includes('getBytecode'),
    'the oracle address must not even be examined until the chain is settled',
  );
});

test('nothing is read from the chain before the chain is identified', async () => {
  const { reader, calls } = fakeChain({ chainId: 1 });
  await checkKeeper(env, reader);
  assert.deepEqual(calls, ['getChainId'], 'no other question is worth asking yet');
});

// --- what the operator is told ---------------------------------------------

test('an RPC serving mainnet is told there is no oracle there to keep', async () => {
  const { reader } = fakeChain({ chainId: MAINNET_CHAIN_ID });
  const result = failure(await checkKeeper(env, reader));
  assert.match(String(result.fields.hint), /no oracle to keep/);
  assert.match(String(result.fields.hint), new RegExp(`testnet ${TESTNET_CHAIN_ID}`));
});

test('any other chain is told the two ids differ by one digit', async () => {
  const { reader } = fakeChain({ chainId: 1 });
  const result = failure(await checkKeeper(env, reader));
  assert.match(String(result.fields.hint), /differ by one digit/);
});

test('the RPC url is reported, because it is the variable nobody suspects', async () => {
  const { reader } = fakeChain({ chainId: MAINNET_CHAIN_ID });
  const result = failure(await checkKeeper(env, reader));
  assert.equal(result.fields.rpcUrl, env.rpcUrl);
});

// --- the swapped variable that caused eight restarts -----------------------

test('an oracle address equal to the keeper address names the swap outright', async () => {
  const { reader } = fakeChain({ oracleCode: '0x' });
  const result = failure(await checkKeeper({ ...env, oracle: KEEPER }, reader));

  assert.equal(result.code, 'oracle-not-a-contract');
  assert.match(String(result.fields.hint), /have been swapped/);
});

test('an oracle address that is merely undeployed does not claim a swap', async () => {
  const { reader } = fakeChain({ oracleCode: '0x' });
  const result = failure(await checkKeeper(env, reader));

  assert.equal(result.code, 'oracle-not-a-contract');
  assert.doesNotMatch(String(result.fields.hint), /swapped/);
});

// --- the remaining refusals ------------------------------------------------

test('a key without UPDATER_ROLE is refused at startup, not on the first send', async () => {
  const { reader } = fakeChain({ hasRole: false });
  const result = failure(await checkKeeper(env, reader));
  assert.equal(result.code, 'keeper-lacks-updater-role');
  assert.equal(result.fields.keeper, KEEPER);
});

test('a keeper with no gas is refused', async () => {
  const { reader } = fakeChain({ balance: 0n });
  const result = failure(await checkKeeper(env, reader));
  assert.equal(result.code, 'keeper-has-no-gas');
});

// --- success, and the thing that is true but not disqualifying -------------

test('a correct configuration reports what startup learned', async () => {
  const { reader } = fakeChain();
  const result = await checkKeeper(env, reader);

  assert.ok(result.ok);
  if (!result.ok) return;
  assert.deepEqual(result.ready, {
    chainId: TESTNET_CHAIN_ID,
    decimals: 8,
    maxStaleness: 3600n,
    minQuorum: 1n,
    updaterCount: 2n,
  });
  assert.equal(result.warnings.length, 0);
});

test('a single updater is a warning, not a refusal', async () => {
  const { reader } = fakeChain({ updaterCount: 1n });
  const result = await checkKeeper(env, reader);

  assert.ok(result.ok, 'one updater is a weak configuration, not a broken one');
  if (!result.ok) return;
  assert.equal(result.warnings.length, 1);
  assert.equal(result.warnings[0].code, 'single-updater');
  assert.match(result.warnings[0].message, /no redundancy and no median/);
});

test('the role check asks about the key that will actually sign', async () => {
  const { reader, calls } = fakeChain();
  await checkKeeper(env, reader);
  assert.ok(calls.includes('readOracle:hasRole'));
  assert.ok(calls.includes('getBalance'), 'gas is checked too');
});
