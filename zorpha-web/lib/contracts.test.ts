import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  isExpectedAbsence,
  MAINNET_CHAIN_ID,
  type ContractKey,
} from './contracts';

/**
 * The environment banner is the surface that has to be believed on the day
 * something is actually broken. It spent this deployment's whole life saying
 * "7 contract addresses are unset, so the panels below have nothing to read"
 * to every mainnet visitor, while the panels below read fine.
 *
 * Six of those seven were deliberate and the seventh was wrong. These tests pin
 * which is which, because the failure mode is silent in both directions: a key
 * wrongly excused disappears from a warning someone needed, and a key wrongly
 * reported puts the banner back to crying wolf.
 */

const TESTNET_CHAIN_ID = 46630;

/** Absent on 4663 by decision — lib/deployment.ts NOT_ON_MAINNET. */
const BY_DESIGN: ContractKey[] = [
  'oracle',
  'strategyExecutor',
  'spotVault',
  'rotationVault',
  'reputationRegistry',
];

test('the five systems that were never deployed to mainnet are not faults', () => {
  for (const key of BY_DESIGN) {
    assert.equal(
      isExpectedAbsence(key, MAINNET_CHAIN_ID),
      true,
      `${key} is in NOT_ON_MAINNET, so its absence is a decision, not a misconfiguration`,
    );
  }
});

test('the bond faucet is testnet-only, so its absence on mainnet is the point', () => {
  // lib/chains.ts exports `isMainnet` specifically to keep this off 4663.
  // Reporting its absence there as a fault inverts the intent.
  assert.equal(isExpectedAbsence('leaderFaucet', MAINNET_CHAIN_ID), true);
});

test('the yield vault is deployed, it just is not an env singleton any more', () => {
  // zsUSDG is live at 0x3829bC78... The portal reads vaults from the database
  // filtered by chain_id, which is what lets a second one exist; a singleton
  // env var could only ever name one. This was the one genuinely wrong entry.
  assert.equal(isExpectedAbsence('yieldVault', MAINNET_CHAIN_ID), true);
});

test('a contract that IS meant to be configured still counts as missing', () => {
  // The guard must not become a blanket excuse. If the token address were unset
  // on mainnet the portal really would be broken, and the banner must say so.
  for (const key of ['zor', 'vesting', 'treasury', 'timelock', 'vaultLauncher'] as ContractKey[]) {
    assert.equal(
      isExpectedAbsence(key, MAINNET_CHAIN_ID),
      false,
      `${key} is deployed on mainnet, so an unset address is a real fault`,
    );
  }
});

test('nothing is excused on testnet, where the full stack was deployed', () => {
  // 46630 ran the oracle, the executor and all three vault types. An unset
  // address there is a genuine configuration gap and must still be reported.
  for (const key of [...BY_DESIGN, 'leaderFaucet', 'yieldVault'] as ContractKey[]) {
    assert.equal(
      isExpectedAbsence(key, TESTNET_CHAIN_ID),
      false,
      `${key} was deployed on testnet, so its absence there is a real fault`,
    );
  }
});
