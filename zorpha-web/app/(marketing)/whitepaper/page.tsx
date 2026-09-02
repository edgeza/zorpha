import Link from 'next/link';
import type { Metadata } from 'next';
import {
  ALLOCATIONS,
  TOKEN,
  FLOAT_AT_LAUNCH_PCT,
  INSIDER_PCT,
  tokensFor,
  pctFor,
} from '@/lib/tokenomics';
import { formatCompact, formatMonths } from '@/lib/format';
import { TEST_STATUS } from '@/lib/audit';

export const metadata: Metadata = {
  alternates: { canonical: '/whitepaper' },
  title: 'Whitepaper',
  description:
    'Zorpha technical whitepaper: the receipt and commitment scheme, vault architecture, signed-rebalance mechanism, $ZOR supply and value accrual, governance, and risk.',
};

const SECTIONS = [
  ['1', 'The problem', 'problem'],
  ['2', 'Design principles', 'principles'],
  ['3', 'Architecture', 'architecture'],
  ['4', 'The receipt scheme', 'receipts'],
  ['5', 'Pricing and failure', 'pricing'],
  ['6', 'The token', 'token'],
  ['7', 'Value accrual', 'value'],
  ['8', 'Governance', 'governance'],
  ['9', 'Risk', 'risk'],
  ['10', 'What is not built', 'deferred'],
];

function H2({ n, id, children }: { n: string; id: string; children: React.ReactNode }) {
  return (
    <h2 id={id} className="scroll-mt-28 text-2xl sm:text-3xl">
      <span className="mr-3 font-mono text-base text-zor-400">{n}</span>
      {children}
    </h2>
  );
}

function H3({ children }: { children: React.ReactNode }) {
  return <h3 className="mt-8 text-base font-semibold text-ink-100">{children}</h3>;
}

function P({
  children,
  className = 'text-ink-300',
}: {
  children: React.ReactNode;
  className?: string;
}) {
  return <p className={`mt-4 text-[0.95rem] leading-[1.75] ${className}`}>{children}</p>;
}

function Code({ children }: { children: React.ReactNode }) {
  return (
    <code className="rounded border border-void-700 bg-void-900 px-1.5 py-0.5 font-mono text-[0.85em] text-ink-200">
      {children}
    </code>
  );
}

function Eq({ children, note }: { children: React.ReactNode; note?: string }) {
  return (
    <figure className="mt-5 overflow-x-auto rounded-card border border-void-700 bg-void-900 px-5 py-4">
      <pre className="font-mono text-[0.82rem] leading-relaxed text-ink-200">{children}</pre>
      {note ? <figcaption className="mt-3 text-xs text-ink-500">{note}</figcaption> : null}
    </figure>
  );
}

export default function WhitepaperPage() {
  return (
    <>
      {/* ─── Title block ──────────────────────────────────────────────────── */}
      <section className="relative overflow-hidden border-b border-void-700">
        <div className="spotlight absolute inset-0 -z-10" aria-hidden="true" />
        <div className="shell py-16 sm:py-20">
          <div className="flex flex-wrap items-center gap-2">
            <span className="badge">Whitepaper</span>
            <span className="badge font-mono">v1.0</span>
            <span className="badge font-mono">1 September 2026</span>
          </div>
          <h1 className="mt-6 max-w-4xl text-3xl leading-tight sm:text-5xl">
            Zorpha: verifiable active asset management
          </h1>
          <p className="lede mt-6 max-w-3xl">
            A protocol for running curated investment vaults where the manager&rsquo;s decisions
            are cryptographically committed and publicly reconstructible, so a track record can be
            audited by anyone rather than asserted by its owner.
          </p>
          <div className="mt-8 flex flex-wrap gap-3">
            <Link href="/portal" className="btn-primary">
              Open the portal
            </Link>
            <a
              href="https://github.com/edgeza/zorpha"
              target="_blank"
              rel="noreferrer noopener"
              className="btn"
            >
              Read the contracts
            </a>
          </div>
        </div>
      </section>

      <div className="shell py-14">
        <div className="grid gap-12 lg:grid-cols-[minmax(0,15rem)_minmax(0,1fr)] lg:gap-16">
          {/* ─── Contents ───────────────────────────────────────────────── */}
          <aside className="lg:sticky lg:top-28 lg:self-start">
            <p className="eyebrow">Contents</p>
            <nav className="mt-4 flex flex-col gap-1">
              {SECTIONS.map(([n, label, id]) => (
                <a
                  key={id}
                  href={`#${id}`}
                  className="flex gap-3 rounded-md px-2 py-1.5 text-sm text-ink-400 transition-colors hover:bg-void-800 hover:text-ink-100"
                >
                  <span className="font-mono text-2xs text-ink-600">{n}</span>
                  {label}
                </a>
              ))}
            </nav>
            <div className="mt-6 border-t border-void-700 pt-5">
              <p className="text-xs leading-relaxed text-ink-500">
                This document describes the protocol as implemented. Where something is planned
                rather than built, section 10 says so.
              </p>
            </div>
          </aside>

          {/* ─── Body ───────────────────────────────────────────────────── */}
          <article className="max-w-[68ch]">
            {/* Abstract */}
            <div className="rounded-card border border-void-700 bg-void-900/60 p-6">
              <p className="eyebrow">Abstract</p>
              <P>
                Public claims about investment performance are not falsifiable. Screenshots crop,
                threads get deleted, and a manager who publishes only their wins is
                indistinguishable from one who only has wins. The information a depositor most
                needs is precisely the information a manager is least motivated to publish.
              </P>
              <P>
                Zorpha removes the manager&rsquo;s editorial control over their own record. Vaults
                are ERC-4626 contracts with fixed mandates. A manager cannot move funds; they can
                only produce an EIP-712 signature authorising a rebalance within limits the vault
                enforces independently. Executing that signature emits a receipt containing the
                requested exposure, both legs of the resulting trade, the vault&rsquo;s net asset
                value at execution, a strictly increasing nonce, and a hash binding all of it. The
                record is append-only, timestamped, and reconstructible from chain data without
                trusting any Zorpha service.
              </P>
              <P>
                {TOKEN.ticker} is a fixed-supply token of {formatCompact(TOKEN.maxSupply)} units
                with no mint function and no administrative role. It carries checkpointed
                governance weight, and half of all protocol fee revenue is used to buy it on the
                open market and burn it. It confers no claim on revenue and is never required to
                deposit.
              </P>
            </div>

            {/* 1 */}
            <div className="mt-14">
              <H2 n="1" id="problem">
                The problem
              </H2>
              <P>
                Delegated asset management requires the depositor to solve two problems at once:
                whether a manager is skilled, and whether they are honest about being skilled. The
                second problem is usually harder, and in public crypto markets it is almost
                entirely unsolved.
              </P>
              <P>
                The failure is structural rather than moral. A manager publishing their own history
                controls what enters it. Selective disclosure requires no lying: publishing the
                winners and staying quiet about the rest produces a record that is completely true
                and completely misleading. Survivorship does the rest, because managers who
                performed badly stop publishing entirely, so the visible population is filtered
                before anyone reads it.
              </P>
              <P>
                Existing mitigations do not close the gap. Audited returns are retrospective,
                expensive, and available only to institutions. Copy-trading platforms show real
                positions but own the database, so the record is only as durable as the company
                keeping it. On-chain vaults publish balances, which reveals the outcome but not the
                decision: a NAV series shows that a vault fell 12%, not whether the manager
                intended the exposure that caused it.
              </P>
              <P>
                What is missing is a record of <em>intent</em>, committed before its outcome is
                known, that the author cannot subsequently edit or omit.
              </P>
            </div>

            {/* 2 */}
            <div className="mt-14">
              <H2 n="2" id="principles">
                Design principles
              </H2>
              <P>
                Four constraints follow from that goal. Each of them costs something, and the cost
                is the reason the design is worth stating explicitly.
              </P>

              <H3>Custody is separated from discretion</H3>
              <P>
                A manager who can move funds can always exit with them, and no amount of recording
                changes that. In Zorpha the vault holds assets and no privileged address has a
                function that transfers them out. The manager&rsquo;s entire capability is producing
                a signature. The cost is expressiveness: strategies that need arbitrary calldata
                cannot be run.
              </P>

              <H3>Intent is recorded before outcome</H3>
              <P>
                The receipt records the exposure the manager asked for, not a reconstruction after
                the fact. A rebalance that produced a bad fill still records the target that was
                requested, so execution quality and decision quality remain separable.
              </P>

              <H3>The record does not depend on us</H3>
              <P>
                Receipts are events emitted by the vault contracts. The indexer and this website
                are conveniences over them. If both disappear the record is unaffected, and anyone
                can rebuild it from an archive node. The cost is that receipts must stay small
                enough to be economical as events.
              </P>

              <H3>Failure is closed, not silent</H3>
              <P>
                Where a component cannot do its job correctly it reverts rather than proceeding on
                a guess. A stale oracle stops rebalancing; it does not price the trade at the last
                known value. The cost is availability: the protocol chooses to be temporarily
                unusable over being quietly wrong.
              </P>
            </div>

            {/* 3 */}
            <div className="mt-14">
              <H2 n="3" id="architecture">
                Architecture
              </H2>
              <P>
                Five contract families, each with one responsibility. Nothing in the trust path is
                proprietary.
              </P>

              <H3>Vaults</H3>
              <P>
                Every vault is an ERC-4626 share token over a single underlying asset, with a fixed
                mandate set at deployment. Three types exist: a long/flat vault rotating one
                Stock Token against cash, a rotation vault reweighting a basket of Stock Tokens
                against a base asset, and a yield vault routing idle stablecoin through a pluggable
                adapter. Vaults are deployed through a gated factory rather than permissionlessly,
                which is a deliberate limitation discussed in section 10.
              </P>

              <H3>Strategy executor</H3>
              <P>
                A verifier holding no funds. It checks that a rebalance signature came from the
                vault&rsquo;s authorised signer, that its nonce is unused, that it has not expired,
                and that the manager is within a per-vault daily rate limit. It then calls the
                vault. Submission is permissionless: anyone holding a valid signature can land it,
                so the protocol does not depend on the manager also operating reliable
                infrastructure.
              </P>

              <H3>Oracles</H3>
              <P>
                Vaults price assets through a Chainlink-compatible <Code>AggregatorV3</Code>
                {' '}interface, with a per-vault staleness bound and absolute price bounds. Where a
                production feed exists the vault points at it directly. Where none does, a median
                oracle aggregates reports from an independent updater set and reverts unless a
                quorum of them is fresh.
              </P>

              <H3>Fee routing</H3>
              <P>
                Vaults charge a performance fee above a high-water mark and nothing else. Fees
                accrue to a treasury contract that splits them on a fixed ratio with no
                discretion: half to operations, half to a buyback contract. Section 7 covers what
                the buyback does with it.
              </P>

              <H3>Reputation registry</H3>
              <P>
                An optional layer where a manager commits a hash of off-chain computed statistics
                over a stated window. Anyone may dispute a commitment within a challenge period by
                submitting a differing independently computed hash. A dispute is recorded; it is
                resolved by a governance arbiter rather than by the hash comparison itself, because
                deciding which of two off-chain computations is correct is not something the chain
                can determine.
              </P>
            </div>

            {/* 4 */}
            <div className="mt-14">
              <H2 n="4" id="receipts">
                The receipt scheme
              </H2>
              <P>
                The receipt is the protocol&rsquo;s core artefact. Everything else exists to make it
                trustworthy.
              </P>
              <P>
                When a rebalance executes, the vault emits an event containing the target exposure,
                the post-trade balance of each leg, net asset value per share at that moment, the
                nonce, and a commitment hash. For a single-asset vault the commitment is:
              </P>
              <Eq note="Every field the receipt reports is inside the hash. Recompute it from the event; if it does not match, the record has been altered.">
{`commitment = keccak256(
    manager,        // the signing key, not a display name
    vault,          // which vault
    targetBps,      // exposure requested, in basis points
    navPerShare,    // NAV at execution
    assetLeg,       // underlying held after the trade
    cashLeg,        // cash held after the trade
    nonce,          // strictly increasing per vault
    blockTimestamp,
    txHash
)`}
              </Eq>
              <P>
                A basket vault cannot be expressed in that shape, since it has a weight and a
                balance per constituent. It uses a separate commitment over the full weight array
                and every token leg, encoded with <Code>abi.encode</Code> rather than{' '}
                <Code>abi.encodePacked</Code> so that two adjacent dynamic arrays cannot be
                re-partitioned into a colliding input.
              </P>

              <H3>What the scheme guarantees</H3>
              <P>
                <strong className="text-ink-100">Completeness.</strong> Nonces are strictly
                increasing per vault. A missing nonce is a visible gap, so receipts cannot be
                selectively omitted without the omission itself being evident.
              </P>
              <P>
                <strong className="text-ink-100">Integrity.</strong> Changing any reported field
                invalidates the commitment. The hash is computed by the vault at execution, not
                supplied by the manager.
              </P>
              <P>
                <strong className="text-ink-100">Attribution.</strong> The signing key is bound into
                the hash. Because submission is permissionless, the transaction sender is often not
                the manager, so the two are recorded separately and never conflated.
              </P>

              <H3>What it does not guarantee</H3>
              <P>
                It says nothing about whether a decision was good. A manager can produce a
                flawless, fully verifiable record of consistently losing money. Verifiability
                removes the ability to misrepresent a track record; it does not manufacture skill,
                and the protocol makes no attempt to score managers on returns.
              </P>
            </div>

            {/* 5 */}
            <div className="mt-14">
              <H2 n="5" id="pricing">
                Pricing and failure modes
              </H2>
              <P>
                Net asset value is computed from oracle prices, so oracle behaviour determines
                whether share pricing is honest. Three guards apply on every read.
              </P>
              <P>
                A <strong className="text-ink-100">staleness bound</strong> rejects any answer older
                than the vault&rsquo;s configured window. <strong className="text-ink-100">Absolute
                bounds</strong> reject answers outside a plausible range, which catches a feed
                returning zero or a corrupted magnitude. A{' '}
                <strong className="text-ink-100">quorum requirement</strong>, where a median oracle
                is used, reverts unless enough independent updaters have reported recently.
              </P>
              <P>
                All three revert rather than substituting a fallback. The consequence is that an
                oracle outage makes a vault temporarily unable to rebalance. Redemptions remain
                available, and an emergency redemption path covers the case where NAV genuinely
                cannot be established: it pays a pro-rata share of every asset the vault holds,
                in kind, reading neither the oracle nor the swap venue. A depositor receives two
                tokens rather than one and has to convert the second themselves, which is the
                cost of an exit that cannot be blocked by a dead price feed or an empty market.
              </P>
              <P>
                Execution is bounded separately. Each rebalance computes a minimum acceptable
                output from the oracle price and the vault&rsquo;s slippage cap, and reverts if the
                venue returns less. A rebalance that would move exposure by less than the
                vault&rsquo;s threshold does not trade at all, which removes the incentive to churn
                a position for fee-generating activity.
              </P>
              <P>
                A per-manager daily rate limit caps the damage from a compromised signing key.
                Worst case is roughly one day of misdirected exposure within the vault&rsquo;s
                existing bounds, not loss of principal, because the key cannot withdraw.
              </P>
            </div>

            {/* 6 */}
            <div className="mt-14">
              <H2 n="6" id="token">
                The token
              </H2>
              <P>
                {TOKEN.name} ({TOKEN.ticker}) is an ERC-20 with a total supply of{' '}
                {TOKEN.maxSupply.toLocaleString('en-US')} units, minted once in the constructor.
              </P>
              <P>
                The contract has no mint function of any kind, no owner, no administrative role, no
                pause, no blocklist, no transfer fee, and no upgrade path. Beyond standard transfer
                and approval, the only state-changing entry points are <Code>burn</Code>,{' '}
                <Code>burnFrom</Code>, <Code>permit</Code> and <Code>delegate</Code>. Supply is
                therefore monotonically non-increasing.
              </P>
              <P>
                Governance weight uses ERC-5805 checkpoints on an ERC-6372 timestamp clock rather
                than block numbers. Robinhood Chain produces blocks roughly every 0.17 seconds and
                does not guarantee a stable interval, so a voting period denominated in blocks
                would drift against wall-clock time.
              </P>

              <H3>Distribution</H3>
              <P>
                Six allocations, summing to the full supply. The same basis points are hardcoded in
                the deployment script, which refuses to complete unless the distribution consumes
                exactly the total supply and the deploying key finishes holding nothing.
              </P>

              <div className="mt-5 overflow-x-auto rounded-card border border-void-700">
                <table className="w-full min-w-[34rem] text-sm">
                  <thead>
                    <tr className="border-b border-void-700 bg-void-850 text-left">
                      {['Allocation', 'Share', 'Tokens', 'At launch', 'Cliff', 'Term'].map((h) => (
                        <th
                          key={h}
                          className="px-4 py-3 text-2xs font-medium uppercase tracking-[0.12em] text-ink-500"
                        >
                          {h}
                        </th>
                      ))}
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-void-700">
                    {ALLOCATIONS.map((a) => (
                      <tr key={a.key}>
                        <td className="px-4 py-3 text-ink-200">{a.label}</td>
                        <td className="px-4 py-3 font-mono text-ink-100">{pctFor(a.bps)}%</td>
                        <td className="px-4 py-3 font-mono text-2xs text-ink-400">
                          {formatCompact(tokensFor(a.bps))}
                        </td>
                        <td className="px-4 py-3 font-mono text-2xs text-ink-400">
                          {a.tgeBps > 0 ? `${pctFor(a.tgeBps)}%` : 'nil'}
                        </td>
                        <td className="px-4 py-3 font-mono text-2xs text-ink-400">
                          {formatMonths(a.cliffMonths)}
                        </td>
                        <td className="px-4 py-3 font-mono text-2xs text-ink-400">
                          {a.shape === 'locked'
                            ? 'locked'
                            : a.shape === 'tge'
                              ? 'unlocked'
                              : formatMonths(a.vestMonths)}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>

              <P>
                Circulating supply at launch is {FLOAT_AT_LAUNCH_PCT}%, being the Season 1 airdrop
                plus protocol-owned liquidity. Contributors and backers together hold{' '}
                {INSIDER_PCT}%, receive nothing at launch, and unlock nothing for twelve months.
              </P>
              <P>
                The float is deliberately higher than is fashionable. A small float paired with a
                large fully-diluted valuation produces a price discovered against very little
                liquidity, and every subsequent unlock then arrives into a market that cannot
                absorb it. Deep protocol-owned liquidity and a real launch float are the structural
                answer to that, and they are priced as insurance rather than as cost.
              </P>
              <P>
                Ecosystem emissions, the largest single allocation, are released season by season
                against published criteria and require a governance decision each time. They are a
                budget with an approver, not an automatic schedule.
              </P>
            </div>

            {/* 7 */}
            <div className="mt-14">
              <H2 n="7" id="value">
                Value accrual
              </H2>
              <P>
                Vault performance fees flow to the treasury, which splits every asset it receives
                on a fixed ratio: half to operations, half to a buyback contract. The split is not
                a governance parameter.
              </P>
              <P>
                The buyback holds fee revenue and, once its balance clears a threshold, may be
                triggered by anyone. It swaps the full balance for {TOKEN.ticker} on the open market
                and burns what it receives, reducing total supply.
              </P>
              <P>
                Two properties matter more than the mechanism. First, the caller supplies the
                minimum output they will accept, so a predictable market buy of a known balance
                cannot be forced into an arbitrarily bad fill. Second, both reported quantities are
                measured as balance deltas across the swap rather than read from the swap
                venue&rsquo;s return value, so a malicious or malfunctioning router cannot cause the
                protocol to report a purchase or a burn that did not occur.
              </P>
              <Eq note="Both figures come from measured balances. The contract cannot report a burn larger than the supply reduction it actually caused.">
{`usdcSpent  = balanceBefore(USDC) - balanceAfter(USDC)
zorBurned  = balanceAfter(ZOR)   - balanceBefore(ZOR)

require(zorBurned >= callerMinimumOut)
ZOR.burn(zorBurned)          // reduces totalSupply`}
              </Eq>
              <P>
                Burning reduces supply. It is not a distribution, it creates no claim on revenue,
                and it is not a statement about price. If the vaults earn no fees, no buyback
                occurs, which is the intended behaviour: the mechanism is a function of protocol
                revenue rather than a subsidy independent of it.
              </P>
            </div>

            {/* 8 */}
            <div className="mt-14">
              <H2 n="8" id="governance">
                Governance
              </H2>
              <P>
                Every privileged action in the protocol is queued in a 48-hour timelock owned by a
                multisig. There is no path that takes effect immediately, so any change is visible
                on-chain for two days before it can execute.
              </P>
              <P>
                The token contract itself has no privileged function, so there is nothing to queue
                against it. Supply, transferability and the absence of a mint are properties of the
                bytecode, not policy decisions that governance could revisit.
              </P>
              <P>
                Deployment ends with the deploying key holding no tokens and no roles. The
                deployment script asserts this and reverts otherwise, so a launch cannot silently
                complete with authority still resting on the key that performed it.
              </P>
              <P>
                {TOKEN.ticker} voting weight is real and historically queryable from launch, but no
                Governor contract is deployed, so there is currently no on-chain venue to submit or
                execute a proposal. Delegation is still worthwhile, because it establishes weight
                from the moment it happens, which is what any future Governor would measure
                against. Stating this plainly matters more than the feature: a token described as
                governance-enabled without a venue to govern in is a claim worth qualifying.
              </P>
              <P>
                Unvested contributor and backer tokens carry zero voting weight. The vesting
                contract never delegates and has no function permitting it to, so nobody votes with
                tokens they have not yet earned.
              </P>
            </div>

            {/* 9 */}
            <div className="mt-14">
              <H2 n="9" id="risk">
                Risk
              </H2>
              <P>
                Depositing into a smart contract exposes principal to total, permanent,
                unrecoverable loss. Nothing in this design changes that, and the following are the
                specific ways it can happen.
              </P>
              <P>
                <strong className="text-ink-100">Contract defects.</strong> An internal review
                found 24 issues in this codebase, two of which would have caused unrecoverable loss
                of funds. All are fixed and covered by regression tests, and the suite stands at{' '}
                {TEST_STATUS.suiteTests - TEST_STATUS.suiteFailing} of {TEST_STATUS.suiteTests}.
                Scrutiny is not proof. An external audit is a gate before mainnet, and software
                of this size can hold defects that no review has surfaced. Every finding from that
                review is written up in the protocol repository.
              </P>
              <P>
                <strong className="text-ink-100">Oracle failure.</strong> Vaults fail closed on
                stale or out-of-bounds prices, which converts a pricing failure into an
                availability failure. This is better, not safe: a feed reporting a wrong but
                plausible price within its bounds would be acted upon.
              </P>
              <P>
                <strong className="text-ink-100">Manager conduct.</strong> A manager can lose money
                competently and visibly. A compromised signing key can push exposure to a harmful
                target within the vault&rsquo;s limits until it is rotated.
              </P>
              <P>
                <strong className="text-ink-100">Underlying assets.</strong> The equity vaults hold
                Robinhood Stock Tokens, which Robinhood documents as tokenised debt securities
                issued by Robinhood Assets (Jersey) Limited. They give economic exposure to a share
                and confer no legal or beneficial ownership of it, no shareholder rights and no
                votes. They can fall, be halted, be delisted, or diverge from the price of the
                share they reference, and they carry their issuer&rsquo;s credit risk on top of
                that. Deployment on Robinhood Chain implies no relationship with Robinhood.
              </P>
              <P>
                <strong className="text-ink-100">Governance.</strong> Privileged roles exist. A
                timelock and a multisig delay and publicise their use; they do not prevent it.
              </P>
              <P>
                <strong className="text-ink-100">Liquidity and regulation.</strong> There may be no
                market in which to sell {TOKEN.ticker} or a vault share at any given price.
                Regulatory treatment of tokens and tokenised securities differs by jurisdiction and
                can change, including retroactively.
              </P>
              <P className="text-ink-400">
                Nothing in this document is investment advice, an offer to sell, or a solicitation
                to buy. {TOKEN.ticker} pays no yield and confers no claim on revenue, profit or
                treasury assets. See the{' '}
                <Link href="/legal/disclaimer" className="link-quiet">
                  risk disclaimer
                </Link>
                .
              </P>
            </div>

            {/* 10 */}
            <div className="mt-14">
              <H2 n="10" id="deferred">
                What is not built
              </H2>
              <P>
                Stating the gaps is part of describing the system. Each of these is a real
                limitation of the protocol as deployed.
              </P>
              <P>
                <strong className="text-ink-100">No Governor.</strong> Voting weight exists; the
                venue to use it does not. Changes move through a multisig behind the timelock.
              </P>
              <P>
                <strong className="text-ink-100">Curated, not permissionless, vaults.</strong> A
                gated factory means Zorpha decides which mandates exist. That is a centralisation
                the protocol accepts in exchange for not producing a long tail of unreviewable
                strategies, which would undermine the one property the protocol is for. Opening it
                requires a manager bond and a review period, neither of which is built.
              </P>
              <P>
                <strong className="text-ink-100">No manager bonding.</strong> Managers have
                reputation at stake but no capital. A slashing design that cannot be gamed by
                self-dealing is a prerequisite, and it is not designed yet.
              </P>
              <P>
                <strong className="text-ink-100">Synchronous deposits only.</strong> ERC-4626
                settles immediately, which excludes strategies that cannot price a redemption on
                demand. ERC-7540 asynchronous flows would address it.
              </P>
              <P>
                <strong className="text-ink-100">Reputation statistics are off-chain.</strong> The
                registry stores commitments, not numbers. Verifying a claim means recomputing it
                from the public receipt history, and disputes are settled by a governance arbiter
                rather than by the protocol.
              </P>
              <P>
                <strong className="text-ink-100">No third-party audit.</strong> The gating item
                before mainnet.
              </P>
            </div>

            {/* Footer */}
            <div className="mt-16 border-t border-void-700 pt-8">
              <p className="text-xs leading-relaxed text-ink-500">
                Version 1.0, 1 September 2026. This document describes the protocol as implemented
                at the time of writing and will be revised as the protocol changes. The contracts
                are the authoritative specification; where this document and the code disagree, the
                code is correct and this document is a bug.
              </p>
              <div className="mt-5 flex flex-wrap gap-3">
                <Link href="/protocol" className="btn btn-sm">
                  Protocol overview
                </Link>
                <Link href="/token" className="btn btn-sm">
                  Tokenomics
                </Link>
                <Link href="/faq" className="btn btn-sm">
                  FAQ
                </Link>
              </div>
            </div>
          </article>
        </div>
      </div>
    </>
  );
}
