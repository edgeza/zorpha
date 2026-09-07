/**
 * The UniswapV3TwapAdapter's read surface.
 *
 * Kept out of `manager-abi.ts`, which describes what an OPERATOR needs and is
 * loaded on the terminal only. This is the price feed, and a price is the one
 * thing on that screen a depositor would also want, so it lives on its own and
 * carries the four views a chart needs and nothing else.
 *
 * `answersOverWindows` is deliberately UNGUARDED on the contract: none of the
 * five checks in `latestRoundData` runs inside it. That is why the chart keeps
 * drawing while NAV is refusing, which is exactly the moment a manager wants to
 * look at the price. Do not "fix" it by switching the chart to latestRoundData.
 */
export const twapAdapterAbi = [
  {
    type: 'function',
    name: 'decimals',
    stateMutability: 'pure',
    inputs: [],
    outputs: [{ type: 'uint8' }],
  },
  {
    type: 'function',
    name: 'latestRoundData',
    stateMutability: 'view',
    inputs: [],
    outputs: [
      { name: 'roundId', type: 'uint80' },
      { name: 'answer', type: 'int256' },
      { name: 'startedAt', type: 'uint256' },
      { name: 'updatedAt', type: 'uint256' },
      { name: 'answeredInRound', type: 'uint80' },
    ],
  },
  {
    type: 'function',
    name: 'oldestObservationSecondsAgo',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint32' }],
  },
  {
    type: 'function',
    name: 'answersOverWindows',
    stateMutability: 'view',
    inputs: [{ name: 'secondsAgos', type: 'uint32[]' }],
    outputs: [{ type: 'uint256[]' }],
  },
  {
    type: 'function',
    name: 'twapWindow',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint32' }],
  },
  {
    type: 'function',
    name: 'pool',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'address' }],
  },
] as const;
