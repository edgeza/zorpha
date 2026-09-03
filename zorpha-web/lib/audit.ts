/**
 * Internal audit findings, token layer and vault layer.
 *
 * Kept as data so the public security page and
 * `sidequest-protocol/docs/AUDIT-TOKEN-V1.md` cannot drift apart. Publishing
 * open findings is deliberate: a security page that lists only resolved issues
 * tells a reader nothing about whether anybody looked.
 */

export type Severity = 'critical' | 'high' | 'medium' | 'low' | 'info';
export type Status = 'fixed' | 'open' | 'accepted';

export interface Finding {
  id: string;
  severity: Severity;
  status: Status;
  scope: 'token' | 'vault' | 'frontend' | 'tooling';
  title: string;
  impact: string;
  resolution: string;
}

export const AUDIT_DATE = '2026-09-01';

export const FINDINGS: Finding[] = [
  {
    id: 'C-01',
    severity: 'critical',
    status: 'fixed',
    scope: 'token',
    title: 'The buyback contract never bought anything back',
    impact:
      'execute() checked its USDC balance, transferred whatever token balance it already held to a dead address, and emitted BuybackExecuted with usdcSpent set to its entire USDC balance. No swap was ever performed. Every dashboard reading that event would have reported large, entirely fictional buyback volume, and because rescueToken explicitly refused to move USDC and no other exit existed, all fee revenue reaching the contract was permanently unrecoverable.',
    resolution:
      'Rewritten to route through a swap adapter with a caller-supplied minimum output. Both legs are measured as balance deltas across the swap rather than read from the adapter return value, so a malicious router cannot over-report a burn. Tokens are burned via the token burn function, so totalSupply actually falls. A timelocked withdrawUsdc path guarantees fee revenue can never be stranded. Six regression tests, including one driven by a router that takes the USDC and delivers nothing.',
  },
  {
    id: 'C-02',
    severity: 'critical',
    status: 'fixed',
    scope: 'token',
    title: 'Deploy script left the entire supply in the deploy key',
    impact:
      'The pipeline minted all 1,000,000,000 tokens to the deploying EOA and never moved them. It also never deployed the vesting contract or the airdrop distributor at all, despite the app expecting both. Launching from that script would have put 100% of supply in a single hot key with no distribution, no vesting, and no airdrop.',
    resolution:
      'Replaced with a token-layer script that distributes the whole supply atomically in the deploy transaction and then asserts, as launch-blocking requires, that the deployer holds exactly zero, that the buckets sum to max supply, and that every privileged role has moved to governance.',
  },
  {
    id: 'C-03',
    severity: 'high',
    status: 'fixed',
    scope: 'token',
    title: 'Treasury and buyback were owned by the deploy key, contradicting the published role matrix',
    impact:
      'Both contracts were constructed with Ownable(msg.sender) and ownership was never transferred, so the deployer EOA retained them. The security documentation stated both were held by the governance Safe. The treasury rescue function can move any token balance to an arbitrary address, so the documented and actual trust models differed on a function that can drain all protocol fees.',
    resolution:
      'Both are now owned by the Timelock from the deploy transaction, and the script refuses to run if governance is unset or equal to the deployer. Ownership handover is asserted before the script reports success.',
  },
  {
    id: 'H-01',
    severity: 'high',
    status: 'fixed',
    scope: 'token',
    title: 'A mint function that could never succeed, with tests asserting that it did',
    impact:
      'The token exposed mintForTestnet, but the constructor already minted the full cap and the ERC20Votes supply ceiling was pinned to that same cap, so any call reverted with ERC20ExceededSafeSupply. Three tests asserted the opposite. Those tests had never been executed, the suite did not compile, which meant the whole test suite was decorative. After any burn the function also became genuinely callable on the testnet chain id, letting burned supply be re-minted.',
    resolution:
      'The function is removed. The token now has no mint entrypoint whatsoever, pinned by a test that asserts both mintForTestnet and mint are absent from the ABI.',
  },
  {
    id: 'H-02',
    severity: 'high',
    status: 'fixed',
    scope: 'tooling',
    title: 'The repository did not compile',
    impact:
      'Production source was missing an IERC20Metadata import in the yield vault and a SafeERC20 using-directive in the swap adapter. Two test files used the wrong relative import depth, and a registry test read a public mapping getter as a struct. Nothing in the project had ever been built or tested, so no finding below this line could have been caught by CI.',
    resolution:
      'All five compilation errors fixed. The project now builds clean and the full suite executes.',
  },
  {
    id: 'H-03',
    severity: 'high',
    status: 'fixed',
    scope: 'token',
    title: 'Vesting treated the cliff as additive with the vesting term',
    impact:
      'Vesting accrued linearly over cliff plus vestDuration rather than over vestDuration measured from the start. A schedule described as "12 month cliff, 48 month vest" actually ran 60 months and released 20% at the cliff instead of 25%. Every contributor and backer schedule would have silently paid out on the wrong curve and finished a year late.',
    resolution:
      'Accrual is now linear over vestDuration from startTime, with the cliff gating the first release. A regression test pins the exact cliff fraction, the midpoint, and the end date.',
  },
  {
    id: 'M-01',
    severity: 'medium',
    status: 'fixed',
    scope: 'frontend',
    title: 'Every contract address silently resolved to the zero address in the browser',
    impact:
      'The address registry read environment variables through a helper as process.env[name] with a variable key. Next.js only inlines statically analysable process.env member expressions, so nothing was substituted in the client bundle and every address fell back to 0x000…000. The token and airdrop pages would have read state from the zero address in production while working correctly in development, where a real process.env exists.',
    resolution:
      'Every lookup is now a literal process.env.NEXT_PUBLIC_* reference, addresses are format-validated, and the portal renders an explicit banner naming any contract that is unconfigured rather than showing a confident zero.',
  },
  {
    id: 'M-02',
    severity: 'medium',
    status: 'fixed',
    scope: 'token',
    title: 'Documentation and marketing denied a capability the token has',
    impact:
      'The token extends ERC20Votes and carries real checkpointed voting weight, while the security document stated "V1 has no voting token" and the token page listed "not a governance token" as a feature. Shipping a public site that understates what a token can do is a disclosure problem, not a copy problem.',
    resolution:
      'Voting is kept and described accurately: weight exists and is queryable today, no Governor is deployed, and the governance page states plainly that there is currently no on-chain venue for a proposal.',
  },
  {
    id: 'M-03',
    severity: 'medium',
    status: 'fixed',
    scope: 'vault',
    title: 'The price oracle was deployed permanently unable to reach quorum',
    impact:
      'The median oracle was constructed requiring three fresh reports but only one updater key was ever added, so latestRoundData reverted with InsufficientFreshReports on every call. Any vault falling back to it was bricked from the moment it was deployed.',
    resolution:
      'Quorum is derived from the actual updater set, the script asserts it is satisfiable before finishing, and it prints an explicit instruction to seat a real multi-key updater set before accepting deposits.',
  },
  {
    id: 'M-04',
    severity: 'medium',
    status: 'fixed',
    scope: 'tooling',
    title: 'The deploy script reverted in every production configuration',
    impact:
      'The vault factory grants its deploy role only to the constructor admin. The script passed governance as that admin and then called deploySpotVault, setSwapAdapter and grantRole from the deployer key. Whenever governance was a multisig, that is, every real deployment, the run failed partway through with an access-control revert, after the token had already been deployed.',
    resolution:
      'The factory and vaults are deployed with the deployer as temporary admin, wired, then handed to governance with the deployer renouncing. The script asserts no deployer authority survives.',
  },
  {
    id: 'M-05',
    severity: 'medium',
    status: 'fixed',
    scope: 'token',
    title: 'Voting checkpoints were keyed to block numbers on a chain with no block-time guarantee',
    impact:
      'ERC20Votes defaults to a block-number clock. Robinhood Chain does not guarantee a stable block interval, so any future governance period expressed in blocks would drift in wall-clock terms, a three day vote could quietly become five.',
    resolution:
      'The token overrides clock() and CLOCK_MODE() to report timestamps, per ERC-6372.',
  },
  {
    id: 'M-06',
    severity: 'medium',
    status: 'fixed',
    scope: 'token',
    title: 'Vesting accepted schedules that were already fully vested, and used quadratic gas',
    impact:
      'The funding function did not validate the start time, so a backdated schedule could be created already claimable in full. It also detected duplicate beneficiaries inside a batch with a nested loop, making gas grow quadratically with batch size.',
    resolution:
      'Start times are bounded by a maximum backdate, cliffs are required not to exceed the vesting term, and the duplicate check is now a single storage read per entry.',
  },
  {
    id: 'M-07',
    severity: 'medium',
    status: 'fixed',
    scope: 'token',
    title: 'The buyback had no slippage protection',
    impact:
      'Separately from the buyback performing no swap at all, the execute function took no minimum-output parameter and would have accepted whatever the venue returned. A permissionless, fully predictable market buy of the contract entire balance, with no bound on the price paid, is a standing invitation to sandwich the protocol treasury.',
    resolution:
      'The caller now supplies a minimum output, enforced against the measured balance delta rather than the adapter return value. Pinned by a test that moves the price against the buyback mid-flight.',
  },
  {
    id: 'L-01',
    severity: 'low',
    status: 'fixed',
    scope: 'token',
    title: 'Revoking a vesting schedule emitted no event',
    impact:
      'Revocation moved tokens and permanently altered a beneficiary schedule with no log, so indexers and observers could not detect it. For a protocol whose entire pitch is a verifiable record, an unlogged privileged action is a gap in the record.',
    resolution:
      'A Revoked event reports the vested amount kept and the unvested amount returned. Schedule creation is now logged too.',
  },
  {
    id: 'L-02',
    severity: 'low',
    status: 'fixed',
    scope: 'frontend',
    title: 'An unconfigured backend crashed the build instead of degrading',
    impact:
      'The data module was marked client-only yet imported by server components, and it constructed a Supabase client at import time with empty credentials, which throws. A deployment without backend environment variables failed during prerender rather than rendering the marketing site.',
    resolution:
      'The client is created lazily, the module is server-safe, and every query degrades to an empty result with an explicit empty state.',
  },
  {
    id: 'L-03',
    severity: 'info',
    status: 'fixed',
    scope: 'tooling',
    title: 'via_ir silently invalidates time-based tests',
    impact:
      'foundry.toml enables via_ir, and the IR optimiser rematerialises the TIMESTAMP opcode at each use rather than caching it. A local variable holding block.timestamp therefore picks up the post-warp value, so a past-lookup assertion can pass or fail for reasons unrelated to the contract.',
    resolution:
      'Time-based tests use literal timepoints, with the reason documented inline so the pattern is not reintroduced.',
  },

  // ─── Vault layer: remediated in the launch-readiness pass. ────────────────
  {
    id: 'V-01',
    severity: 'critical',
    status: 'fixed',
    scope: 'vault',
    title: 'Yield vault valued shares against an adapter balance it never funded',
    impact:
      'The vault reported totalAssets as its yield adapter balance but never overrode the ERC-4626 deposit and withdraw hooks, so deposited funds stayed on the vault and the adapter balance stayed zero. Share price read as zero: a depositor burned every share and received nothing while their principal sat stranded in the contract. It also inflated share issuance for the next depositor, diluting the first.',
    resolution:
      'Both hooks now route capital through the adapter: deposits forward in, withdrawals recall first. Switching adapters migrates the position in the same transaction rather than stranding it, and a claimFees path was added so accrued fees are actually payable instead of permanently depressing NAV for nobody. Pinned by a fuzz test asserting a deposit-then-redeem round trip is whole to within one wei, plus an invariant that everything totalAssets counts is held where it is counted.',
  },
  {
    id: 'V-02',
    severity: 'high',
    status: 'fixed',
    scope: 'vault',
    title: 'The signed-rebalance path could not execute at all',
    impact:
      'The sliding rate-limit window computed its cutoff as block.timestamp minus one day, which underflows on any chain whose timestamp is below 86400, precisely the state a fresh Foundry or Anvil instance starts in. Every rate-limited rebalance reverted with an arithmetic panic, so the EIP-712 mechanism the entire protocol is built around was never once exercised by a test.',
    resolution:
      'The cutoff is clamped at zero. The window is now compacted in place rather than deleted and re-pushed, which halves the storage writes, and the signature is verified before any storage is touched so a forged command cannot make the protocol pay for the compaction. All nine executor tests pass.',
  },
  {
    id: 'V-03',
    severity: 'high',
    status: 'fixed',
    scope: 'vault',
    title: 'Reputation registry reported disputes as unchallenged',
    impact:
      'A challenge wrote only to the history array, while the portal reads getLatest, which returned a separate duplicated copy that challenges never touched. The two diverged the moment anything was disputed, so an overturned commitment kept displaying as unchallenged.',
    resolution:
      'The duplicated latest mapping is removed entirely and getLatest now derives from history, so the two cannot disagree. Thirteen registry tests cover publish, dispute, arbitration and window expiry.',
  },
  {
    id: 'V-04',
    severity: 'medium',
    status: 'fixed',
    scope: 'vault',
    title: 'Spot vault circuit breaker and fee accrual were never actually tested',
    impact:
      'Both tests failed with an access-control revert before reaching a single assertion, because the suite never granted the risk-council or keeper roles. The circuit breaker and the fee logic were completely unverified while appearing to be covered.',
    resolution:
      'Roles are wired correctly, and the keeper role is deliberately withheld from the test contract so the negative authorisation test still means something. Ten spot vault tests pass.',
  },
  {
    id: 'V-05',
    severity: 'medium',
    status: 'fixed',
    scope: 'vault',
    title: 'The invariant suite passed without exercising anything',
    impact:
      'The run reported both invariants holding across 128,000 calls, but all 64,010 rebalance calls reverted, because the handler pranked as an address holding no keeper role. The invariants were satisfied vacuously while reporting green, which is worse than having no invariant test because it manufactures confidence. The two assertions were also tautologies: one checked that an unsigned integer was at least zero.',
    resolution:
      'Rewritten with seven real invariants: fee solvency, full backing of outstanding shares, net never exceeding gross, receipt count matching executed rebalances, and no value created from nothing. The handler is wired so calls land, and an afterInvariant coverage floor fails the run outright if no deposit or rebalance ever succeeded. Revert rate went from 100% to under 10%.',
  },
  {
    id: 'V-06',
    severity: 'high',
    status: 'fixed',
    scope: 'vault',
    title: 'A manager could mint their own "verified" badge',
    impact:
      'A challenge was resolved by comparing the stored commitment against a hash the challenger supplied, and a match set upheld to true. So a manager could publish any figures at all, immediately self-challenge quoting that same hash, and be recorded as upheld, while the already-challenged guard then permanently blocked a genuine challenge from anyone else. The portal renders that flag as a green Upheld badge, so the worst case was a fabricated track record displaying as independently verified.',
    resolution:
      'Only a mismatch is a dispute; a matching counter-commitment now reverts and leaves the window open. Upheld can only be set by a governance arbiter through a separate resolveChallenge call, because deciding which of two off-chain computations is correct is not something a hash comparison between the disputing parties can settle. The specific self-minting attack is pinned by a test.',
  },
  {
    id: 'V-07',
    severity: 'medium',
    status: 'fixed',
    scope: 'vault',
    title: 'Rotation vault receipts did not commit to the basket',
    impact:
      'The rotation vault reused the single-asset commitment helper, passing rebalanceCount modulo 65536 as the target weight and the constant 10000 weight checksum as the cash leg. The resulting hash therefore bound neither the basket weights nor the per-token legs, exactly the fields a rotation receipt exists to attest. Two rebalances into completely different baskets could hash identically.',
    resolution:
      'A dedicated basketCommitment binds the full weight array and every token leg, using abi.encode rather than encodePacked so two dynamic arrays cannot collide. Tests assert that reordering either the weights or the legs changes the hash.',
  },
  {
    id: 'V-08',
    severity: 'medium',
    status: 'fixed',
    scope: 'vault',
    title: 'The rotation vault charged none of its advertised performance fee',
    impact:
      'The vault stored a performance fee, a high-water mark and an accrual slot, and the deploy script configured 20%, but there was no evaluateFees and no claimFees anywhere in the contract. The accrual slot was never written, so the protocol earned nothing from this vault while the site advertised a 20% performance fee. Slither surfaced it by flagging the accrual as assignable-to-constant, which is what a never-written storage slot looks like from the outside.',
    resolution:
      'Both functions implemented, mirroring the spot vault: charged only on gains above the high-water mark, clamped so the accrual can never exceed what the vault holds, and payable in the base asset. Five tests cover no-accrual below the high-water mark, accrual on a new high, no double-billing at the same high, keeper gating, and the empty-claim revert.',
  },
];

export const SEVERITY_ORDER: Severity[] = ['critical', 'high', 'medium', 'low', 'info'];

export function countBy(status: Status): number {
  return FINDINGS.filter((f) => f.status === status).length;
}

export function openFindings(): Finding[] {
  return FINDINGS.filter((f) => f.status === 'open').sort(
    (a, b) => SEVERITY_ORDER.indexOf(a.severity) - SEVERITY_ORDER.indexOf(b.severity),
  );
}

export function fixedFindings(): Finding[] {
  return FINDINGS.filter((f) => f.status === 'fixed').sort(
    (a, b) => SEVERITY_ORDER.indexOf(a.severity) - SEVERITY_ORDER.indexOf(b.severity),
  );
}

/**
 * Counts from the contract suite, refreshed by hand.
 *
 * `suiteTests` said 97 for long enough that it drifted to roughly a third of
 * the truth -- the suite is 283 -- and the copy hardcoded "seven stateful
 * invariants" against an actual 13. Understating is not a harmless direction to
 * be wrong in: every other number on the marketing pages is load-bearing, and a
 * reader who checks one and finds it wrong has no reason to trust the rest.
 *
 * Refresh with, from sidequest-protocol/contracts:
 *
 *     forge test --list --json | node -e '...'   # 23 files, 283 tests, 13 invariants
 *
 * The durable fix is to generate this at build time rather than type it. Until
 * then, treat it as a number that must be re-read whenever tests are added.
 */
export const TEST_STATUS = {
  tokenLayerTests: 40,
  tokenLayerPassing: 40,
  /** Everything `forge test` runs: 270 unit and fuzz tests plus 13 invariants. */
  suiteTests: 283,
  suiteFailing: 0,
  /** Stateful invariant runs, counted separately because the copy calls them out. */
  suiteInvariants: 13,
} as const;
