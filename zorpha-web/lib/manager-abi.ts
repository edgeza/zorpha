/**
 * The manager surface of the three vaults, the oracle behind them, and the
 * two launcher functions a leader may call.
 *
 * Kept apart from `lib/contracts.ts` because that file describes what a
 * DEPOSITOR needs — balances, supply, NAV — and this one describes what an
 * OPERATOR needs, which is a different and much larger set. Merging them would
 * ship the whole operator surface to every visitor reading a vault page.
 *
 * Every entry below was checked against the deployed testnet bytecode rather
 * than against the Solidity source, because those two disagreed once already:
 * `vaultAbi` asked for `circuitBreakerActive` where all three vaults declare
 * `isCircuitBreakerActive`, so the read reverted on chain and wagmi reported
 * `undefined`, which renders exactly like "not halted".
 */

const view = (
  name: string,
  outputs: readonly { type: string; name?: string }[],
  inputs: readonly { type: string; name?: string }[] = [],
) => ({ type: 'function', name, stateMutability: 'view', inputs, outputs }) as const;

const write = (name: string, inputs: readonly { type: string; name?: string }[] = []) =>
  ({ type: 'function', name, stateMutability: 'nonpayable', inputs, outputs: [] }) as const;

/** Present on all three vaults. */
export const vaultCommonAbi = [
  view('asset', [{ type: 'address' }]),
  view('decimals', [{ type: 'uint8' }]),
  view('symbol', [{ type: 'string' }]),
  view('name', [{ type: 'string' }]),
  view('totalAssets', [{ type: 'uint256' }]),
  view('totalSupply', [{ type: 'uint256' }]),
  view('getNavPerShare', [{ type: 'uint256' }]),
  view('rebalanceCount', [{ type: 'uint256' }]),
  view('performanceFee', [{ type: 'uint256' }]),
  view('performanceFeeAccrued', [{ type: 'uint256' }]),
  view('highWaterMark', [{ type: 'uint256' }]),
  view('feeRecipient', [{ type: 'address' }]),
  view('isCircuitBreakerActive', [{ type: 'bool' }]),
  view('hasRole', [{ type: 'bool' }], [{ type: 'bytes32' }, { type: 'address' }]),
  write('evaluateFees'),
  write('setCircuitBreaker', [{ name: 'active', type: 'bool' }]),
] as const;

/**
 * Spot. `rebalanceTo` takes one number: the share of value held in the
 * underlying, the rest in cash. That single argument is the whole of a spot
 * manager's discretion.
 */
export const spotVaultAbi = [
  ...vaultCommonAbi,
  view('targetWeightBps', [{ type: 'uint16' }]),
  view('rebalanceThresholdBps', [{ type: 'uint16' }]),
  view('maxSlippageBps', [{ type: 'uint16' }]),
  view('maxOracleStaleness', [{ type: 'uint256' }]),
  view('grossValue', [{ type: 'uint256' }]),
  view('oracle', [{ type: 'address' }]),
  view('cashAsset', [{ type: 'address' }]),
  view('swapAdapter', [{ type: 'address' }]),
  view('assetToCash', [{ type: 'uint256' }], [{ name: 'assetAmt', type: 'uint256' }]),
  view('cashToAsset', [{ type: 'uint256' }], [{ name: 'cashAmt', type: 'uint256' }]),
  write('rebalanceTo', [{ name: 'targetBps', type: 'uint16' }]),
] as const;

/**
 * Rotation. `rebalanceTo` takes a full set of basket weights totalling 10000.
 *
 * The accessor names here are the ARRAY names, checked against the deployed
 * contract: `oracles(i)`, `tokens(i)`, `targetWeightsBps(i)`. The singular
 * forms do not exist — `oracle()` and `weightsBps(i)` both revert on chain.
 */
export const rotationVaultAbi = [
  ...vaultCommonAbi,
  view('basketLength', [{ type: 'uint256' }]),
  view('maxOracleStaleness', [{ type: 'uint256' }]),
  view('grossValue', [{ type: 'uint256' }]),
  view('netValueInBase', [{ type: 'uint256' }]),
  view('oracles', [{ type: 'address' }], [{ type: 'uint256' }]),
  view('tokens', [{ type: 'address' }], [{ type: 'uint256' }]),
  view('targetWeightsBps', [{ type: 'uint16' }], [{ type: 'uint256' }]),
  view('tokenToBase', [{ type: 'uint256' }], [{ type: 'uint256' }, { type: 'uint256' }]),
  write('rebalanceTo', [{ name: 'newWeightsBps', type: 'uint16[]' }]),
] as const;

/**
 * Yield. `rebalanceTo` takes nothing at all AND MOVES NO FUNDS -- it bumps the
 * counter, reads NAV, and emits a `Rebalanced` receipt. Assets reach the venue
 * on the way IN, because `_deposit` calls `_pushToAdapter`, so there is never
 * idle cash for a keeper to sweep.
 *
 * The venue itself is chosen through the launcher's `reallocate`, which is the
 * leader's call, not the keeper's -- the one place where the person who
 * launched a vault has real discretion over it.
 */
export const yieldVaultAbi = [
  ...vaultCommonAbi,
  view('rawAssets', [{ type: 'uint256' }]),
  view('heldAssets', [{ type: 'uint256' }]),
  view('escrowSupport', [{ type: 'uint256' }]),
  view('highWaterMarkValue', [{ type: 'uint256' }]),
  view('firstLossEscrow', [{ type: 'address' }]),
  view('adapter', [{ type: 'address' }]),
  write('rebalanceTo'),
] as const;

/** Chainlink-shaped, which is what the vaults consume. */
export const oracleAbi = [
  view('decimals', [{ type: 'uint8' }]),
  view('latestRoundData', [
    { name: 'roundId', type: 'uint80' },
    { name: 'answer', type: 'int256' },
    { name: 'startedAt', type: 'uint256' },
    { name: 'updatedAt', type: 'uint256' },
    { name: 'answeredInRound', type: 'uint80' },
  ]),
] as const;

/**
 * The leader's two functions, plus the reads that make a vault list possible.
 *
 * `reallocate` and `reclaimBond` are gated on `msg.sender == launch.leader`
 * and are the ONLY things a leader may do to their own vault — the launcher
 * hands DEFAULT_ADMIN, KEEPER_ROLE and RISK_COUNCIL_ROLE to `vaultAdmin`, an
 * immutable governance address, at launch time.
 */
export const launcherManagerAbi = [
  view('launchesOfLeader', [{ type: 'uint256[]' }], [{ name: 'leader', type: 'address' }]),
  view(
    'vaultSummary',
    [
      { name: 'vault', type: 'address' },
      { name: 'leader', type: 'address' },
      { name: 'totalAssets', type: 'uint256' },
      { name: 'escrowBalance', type: 'uint256' },
      { name: 'coverageBps', type: 'uint256' },
      { name: 'adequatelyCovered', type: 'bool' },
    ],
    [{ name: 'launchId', type: 'uint256' }],
  ),
  view('minCoverageBps', [{ type: 'uint256' }]),
  view('approvedTarget', [{ type: 'bool' }], [{ type: 'address' }]),
  view('launchIdOfVault', [{ type: 'uint256' }], [{ type: 'address' }]),
  // The public `Launch[] launches` array. Its getter flattens the struct, and
  // the array is 0-indexed while launch ids are 1-INDEXED -- `_launch` does
  // `launches[launchId - 1]`. Reading `launches(launchId)` returns the NEXT
  // leader's record, which is how a drill nearly slashed the wrong bond.
  view(
    'launches',
    [
      { name: 'vault', type: 'address' },
      { name: 'escrow', type: 'address' },
      { name: 'adapter', type: 'address' },
      { name: 'leader', type: 'address' },
      { name: 'asset', type: 'address' },
      { name: 'bond', type: 'uint256' },
      { name: 'createdAt', type: 'uint64' },
      { name: 'bondReleased', type: 'bool' },
      { name: 'bondSlashed', type: 'bool' },
    ],
    [{ type: 'uint256' }],
  ),
  write('reallocate', [
    { name: 'launchId', type: 'uint256' },
    { name: 'newTarget', type: 'address' },
  ]),
  write('reclaimBond', [{ name: 'launchId', type: 'uint256' }]),
] as const;
