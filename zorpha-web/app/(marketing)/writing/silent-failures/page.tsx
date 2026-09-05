import type { Metadata } from 'next';
import Link from 'next/link';

export const metadata: Metadata = {
  alternates: { canonical: '/writing/silent-failures' },
  title: 'Five ways to deploy to the wrong chain, four of them silent',
  description:
    'Field notes from putting a protocol on Robinhood Chain. Five ways to be pointed at the wrong chain, four of which produce an empty array and a green health check rather than an error.',
};

/**
 * A single engineering post, written as a page rather than through a CMS.
 *
 * There is no blog infrastructure here and this does not add any: a route, a
 * canonical URL and a sitemap entry are the whole mechanism. If a second post
 * ever needs to exist, that is the moment to extract a list — not before.
 */

/** Shared measure. Long-form prose wants a narrower column than the app pages. */
const PROSE = 'max-w-[46rem]';

function H2({ id, num, children }: { id: string; num?: string; children: React.ReactNode }) {
  return (
    <h2 id={id} className="scroll-mt-28 mt-14 first:mt-0">
      {num ? (
        <span className="block font-mono text-2xs uppercase tracking-[0.14em] text-zor-400">
          {num}
        </span>
      ) : null}
      <span className="mt-2 block text-xl font-semibold leading-snug text-ink-100 sm:text-2xl">
        {children}
      </span>
    </h2>
  );
}

function P({ children }: { children: React.ReactNode }) {
  return <p className="mt-5 text-[0.975rem] leading-[1.75] text-ink-300">{children}</p>;
}

function Code({ children }: { children: React.ReactNode }) {
  return (
    <code className="rounded bg-void-800 px-1.5 py-0.5 font-mono text-[0.82em] text-ink-200">
      {children}
    </code>
  );
}

function Pre({ children }: { children: string }) {
  return (
    <pre className="mt-6 overflow-x-auto rounded-lg border border-void-700 bg-void-800/60 p-4 font-mono text-2xs leading-relaxed text-ink-300">
      <code>{children}</code>
    </pre>
  );
}

function Pull({ children }: { children: React.ReactNode }) {
  return (
    <p className="my-9 border-y border-void-700 py-6 text-lg leading-snug text-ink-100 text-balance">
      {children}
    </p>
  );
}

export default function SilentFailuresPage() {
  return (
    <>
      <section className="relative overflow-hidden border-b border-void-700">
        <div className="spotlight absolute inset-0 -z-10" aria-hidden="true" />
        <div className="shell py-16 sm:py-20">
          <div className="flex flex-wrap items-center gap-3">
            <span className="badge">Field notes</span>
            <span className="badge font-mono">Arbitrum Orbit</span>
          </div>
          <h1 className={`mt-6 ${PROSE} text-3xl font-semibold leading-tight tracking-tight sm:text-5xl`}>
            Five ways to deploy to the wrong chain, four of them silent
          </h1>
          <p className={`lede mt-6 ${PROSE}`}>
            Notes from putting a protocol on Robinhood Chain, an Arbitrum Orbit rollup that reached
            mainnet on 1 July 2026.
          </p>

          {/* The two numbers are the entire story, so they open the piece. */}
          <div className="mt-10 flex max-w-md flex-wrap border-y border-void-700">
            <div className="flex-1 py-5 pr-6">
              <span className="block font-mono text-3xl font-medium tracking-tight text-ink-100 sm:text-4xl">
                46630
              </span>
              <span className="mt-1.5 block font-mono text-2xs uppercase tracking-[0.14em] text-ink-500">
                Testnet
              </span>
            </div>
            <div className="flex-1 border-l border-void-700 py-5 pl-6">
              <span className="block font-mono text-3xl font-medium tracking-tight text-ink-100 sm:text-4xl">
                4663
              </span>
              <span className="mt-1.5 block font-mono text-2xs uppercase tracking-[0.14em] text-ink-500">
                Mainnet
              </span>
            </div>
          </div>
        </div>
      </section>

      <article className="shell py-16">
        <div className={PROSE}>
          <P>
            One digit. Every Orbit chain ships a pair like this, and the pair is the whole story.
            Over the course of moving a protocol from one to the other we found five distinct ways
            to be pointed at the wrong chain. Exactly one of them announced itself. The other four
            came up green.
          </P>
          <P>
            This is a list of the four quiet ones, what each looks like from the outside, and the
            checks that catch them.
          </P>

          <H2 id="loud">The one that saved us</H2>
          <P>Our indexer had a chain-id assert from the beginning:</P>
          <Pre>{`const actual = await getPublicClient().getChainId();
if (actual !== config.chainId) {
  throw new Error(
    \`RPC chain id mismatch: expected \${config.chainId}, got \${actual}.\`
  );
}`}</Pre>
          <P>
            The comment above it said the check existed &ldquo;because a misconfigured URL would
            otherwise poison the database with another chain&rsquo;s data, which is far harder to
            detect after the fact than at startup.&rdquo;
          </P>
          <P>
            When we repointed to mainnet we set <Code>CHAIN_ID=4663</Code> and left{' '}
            <Code>RPC_URL</Code> on the testnet host. The assert fired and the service refused to
            start. It stayed down for a day and a half.
          </P>
          <Pull>
            That refusal is the only reason nothing was corrupted &mdash; and everything below is a
            failure the same config would have produced <em>without</em> making a sound.
          </Pull>

          <H2 id="start-block" num="Failure 01">
            A block height from the other chain
          </H2>
          <P>
            <Code>START_BLOCK</Code> was <Code>112,522,500</Code>, a testnet height.
            Mainnet&rsquo;s head was <Code>55,201,684</Code>.
          </P>
          <P>
            Ask any node for logs in a range that starts beyond its head and you do not get an
            error. You get <Code>[]</Code>. So the indexer would have scanned an empty window, found
            nothing, advanced its cursor, logged a successful cycle, and repeated forever. Health
            checks green. Receipts: zero.
          </P>
          <P>
            And &ldquo;zero receipts&rdquo; was, at that moment, also the <em>correct</em> answer for
            a vault that had never rebalanced &mdash; so the true state and the broken state were
            indistinguishable from the outside.
          </P>
          <Pre>{`const head = await client.getBlockNumber();
if (config.startBlock > head) {
  throw new Error(
    \`START_BLOCK=\${config.startBlock} is beyond the head of chain \` +
    \`\${config.chainId}, currently \${head}. Nothing would ever be \` +
    \`scanned and every cycle would report success.\`
  );
}`}</Pre>

          <H2 id="addresses" num="Failure 02">
            Contract addresses from the other chain
          </H2>
          <P>The config carried three vault addresses. On mainnet, none of them had code.</P>
          <P>
            <Code>eth_getLogs</Code> against an address with no bytecode is not an error either. It
            is an empty array. Three testnet vaults scanned on mainnet look exactly like three quiet
            vaults.
          </P>
          <Pre>{`const code = await client.getBytecode({ address });
if (!code || code === '0x') codeless.push(address);`}</Pre>

          <H2 id="fallback" num="Failure 03">
            A fallback that answers the right chain id and cannot serve the workload
          </H2>
          <P>This one we introduced ourselves, mid-incident, while fixing the others.</P>
          <P>
            The original fallback answers <strong className="text-ink-100">46630</strong>.
            viem&rsquo;s <Code>fallback</Code> transport fails over on <em>transport errors</em>, not
            on chain identity, so a mainnet indexer with that fallback quietly reads testnet whenever
            the primary hiccups. We removed it. We replaced it with another public endpoint, on the
            strength of one call:
          </P>
          <Pre>{`eth_chainId -> 0x1237     # 4663, correct`}</Pre>
          <P>Right chain. Wrong question. The next cycle died on this:</P>
          <Pre>{`eth_getLogs { fromBlock: 0x34a1a24, toBlock: 0x34add73 }
-> -32602 "Archive requests require a personal token"`}</Pre>
          <P>
            An indexer is nothing <em>but</em> historic <Code>eth_getLogs</Code>. The endpoint passed
            every identity check available and then refused the only workload there is. Worse, a
            fallback that fails this way is worse than no fallback: it converts a transient blip on
            the primary into a hard failure on a range the primary serves fine.
          </P>
          <Pull>
            Check the capability, not the identity. <Code>eth_chainId</Code> tells you who is
            answering. It tells you nothing about what they will answer.
          </Pull>

          <H2 id="database" num="Failure 04">
            One database, two chains, and no column saying which
          </H2>
          <P>This is the one that reached users.</P>
          <P>
            A single Postgres instance served both deployments, and not one table carried a chain
            identifier. Pointing the web app at mainnet changed the RPC and the contract addresses in
            config. It did not change the data.
          </P>
          <P>
            So the public portal advertised three vaults to mainnet visitors.{' '}
            <Code>eth_getCode</Code> against all three on 4663 returns <Code>0x</Code>. Anyone who
            picked one and deposited would have been sending funds to an empty address.
          </P>
          <P>
            The fix is unglamorous: a <Code>chain_id</Code> column on every table, every read
            filtered on the connected chain, and natural keys widened to include it &mdash;{' '}
            <Code>managers</Code> from <Code>(address)</Code> to <Code>(address, chain_id)</Code>,
            receipts from <Code>(tx_hash, log_index)</Code> to{' '}
            <Code>(chain_id, tx_hash, log_index)</Code>.
          </P>
          <P>
            <strong className="text-ink-100">
              Widening a unique constraint breaks every upsert that names the old one.
            </strong>{' '}
            Postgres raises <Code>42P10</Code>, which names neither the function nor the reason.
            These arbiters live in client-side strings and in SQL function bodies &mdash; a type
            checker cannot see a single one of them. We found five. Rather than dropping the retired
            functions, we replaced their bodies with a raise that says what happened and what to do.
            Dropping them would make the call fail as <em>&ldquo;function does not exist&rdquo;</em>,
            which reads like a <strong className="text-ink-100">missing</strong> migration &mdash;
            the opposite of the truth.
          </P>
          <P>
            <strong className="text-ink-100">Cursors deserve their own paragraph.</strong> Our
            indexer reads <Code>START_BLOCK</Code> only when a source has no stored cursor. The
            stored cursors sat at testnet heights, so repointing to mainnet without touching them
            resumes from 112,522,501 against a chain whose head is 55.2M &mdash; failure 01 again,
            arrived at from a completely different direction, and this time immune to fixing{' '}
            <Code>START_BLOCK</Code> because <Code>START_BLOCK</Code> is never read.
          </P>

          <H2 id="wrong-guard">The guard we got wrong</H2>
          <P>
            The migration that backfilled <Code>chain_id</Code> carried an assertion: no row may sit
            below the indexer&rsquo;s <Code>START_BLOCK</Code>, because such a row might not be
            testnet and mislabelling history is not reversible.
          </P>
          <P>
            Applied to production, it aborted. Two of four rows sat at <Code>112,370,875</Code>.
          </P>
          <P>
            The data was fine. The guard was wrong, and wrong in an instructive way:{' '}
            <Code>START_BLOCK</Code> had held <strong className="text-ink-100">three</strong>{' '}
            different values over the project&rsquo;s life &mdash; <Code>0</Code>, then{' '}
            <Code>111,911,103</Code> in a local env file, then <Code>112,522,500</Code> on the
            deployment host. Rows indexed under an earlier value legitimately sit below a later one.
          </P>

          <div className="mt-8 rounded-lg border border-zor-500/30 bg-zor-500/[0.06] p-5">
            <p className="font-mono text-2xs uppercase tracking-[0.14em] text-zor-400">The rule</p>
            <p className="mt-2.5 text-[0.975rem] leading-relaxed text-ink-200">
              <Code>START_BLOCK</Code> is a resume position. It says nothing about which chain a row
              came from.{' '}
              <strong className="text-ink-100">
                Guard on an invariant of the world, not on a value in your config.
              </strong>
            </p>
          </div>

          <P>
            The replacement threshold was derived from mainnet&rsquo;s head, because no mainnet row
            can exist above a height mainnet has never reached:
          </P>

          <div className="mt-6 overflow-x-auto">
            <table className="w-full text-sm">
              <tbody className="divide-y divide-void-700">
                {[
                  ['mainnet head, measured', '55,201,684'],
                  ['guard threshold', '60,000,000'],
                  ['lowest row in the table', '112,370,875'],
                  ['testnet head, measured', '113,517,929'],
                ].map(([label, value]) => (
                  <tr key={label}>
                    <td className="py-2.5 pr-6 text-ink-400">{label}</td>
                    <td className="py-2.5 text-right font-mono text-ink-200 tabular-nums">
                      {value}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <P>
            Then we stopped arguing from block heights altogether and resolved every one of the four
            transaction hashes against both RPCs. All four existed on 46630 at exactly the recorded
            height. None existed on 4663.
          </P>
          <blockquote className="mt-6 border-l-2 border-zor-500 pl-5 text-[0.975rem] italic leading-relaxed text-ink-300">
            That is evidence. The arithmetic was only ever an argument.
          </blockquote>

          <H2 id="rules">Two rules that came out of it</H2>
          <P>
            <strong className="text-ink-100">
              A misconfiguration and an outage are different failures and deserve different answers.
            </strong>{' '}
            We added the check the indexer had and the web app lacked &mdash; the app now refuses to
            render a chain it cannot confirm. But a naive version of that guard is worse than
            nothing:
          </P>

          <div className="mt-6 overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-ink-500/40 text-left">
                  <th className="pb-2 pr-6 font-mono text-2xs uppercase tracking-[0.13em] text-ink-500">
                    Signal
                  </th>
                  <th className="pb-2 pr-6 font-mono text-2xs uppercase tracking-[0.13em] text-ink-500">
                    Verdict
                  </th>
                  <th className="pb-2 font-mono text-2xs uppercase tracking-[0.13em] text-ink-500">
                    Why
                  </th>
                </tr>
              </thead>
              <tbody className="divide-y divide-void-700 align-top">
                <tr>
                  <td className="py-3 pr-6 font-mono text-2xs text-ink-300">chain id disagrees</td>
                  <td className="py-3 pr-6 font-mono text-2xs font-semibold text-amber-400">throw</td>
                  <td className="py-3 text-ink-400">
                    Every address on the page comes from a build-time chain id and every balance
                    beside it from the RPC. While they disagree the page is a confident, wrong
                    document about someone&rsquo;s money.
                  </td>
                </tr>
                <tr>
                  <td className="py-3 pr-6 font-mono text-2xs text-ink-300">
                    timeout &middot; HTTP 502 &middot; JSON-RPC error &middot; HTML page
                  </td>
                  <td className="py-3 pr-6 font-mono text-2xs font-semibold text-emerald-400">
                    render
                  </td>
                  <td className="py-3 text-ink-400">
                    The page is <em>stale</em>, not wrong. None of those responses tells you which
                    chain answered, so none is evidence the config is wrong.
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <P>
            Throwing on the second case takes the site down on every node hiccup, and a guard that
            fires on hiccups gets disabled by the third person who is paged.
          </P>
          <P>
            <strong className="text-ink-100">
              A warning that is always on is a warning nobody reads.
            </strong>{' '}
            Our portal greeted every mainnet visitor with a banner reporting seven unset contract
            addresses &mdash; while the panels below read perfectly well. Six of the seven were
            deliberate: an oracle and two priced vaults we chose not to deploy, a testnet-only
            faucet. The seventh was simply stale. It had been crying wolf since launch, and it is the
            same surface that has to be believed on the day something is genuinely broken.
          </P>

          <H2 id="short">The short version</H2>
          <P>
            Of five ways to be on the wrong chain, one was loud and four were silent. The loud one is
            the reason the other four never did damage.
          </P>
          <P>
            If you are deploying to an Orbit chain, the checks worth having before your first write
            are: the chain id matches on <em>every</em> configured endpoint, the start block is below
            the live head, every configured address has bytecode, and every RPC you list can serve
            the query you actually make.
          </P>

          <div className="mt-8 overflow-hidden rounded-lg border border-void-700 bg-void-800/60 font-mono text-2xs">
            {[
              ['PASS', 'correct mainnet config', true],
              ['HALT', 'testnet RPC, mainnet CHAIN_ID · chain-id-mismatch', false],
              ['HALT', 'testnet START_BLOCK on mainnet · start-block-beyond-head', false],
              ['HALT', 'fallback that refuses archive · rpc-cannot-serve-archive', false],
              ['HALT', 'testnet vault address on mainnet · address-has-no-code', false],
            ].map(([verdict, what, pass]) => (
              <div
                key={what as string}
                className="flex gap-4 border-b border-void-700 px-4 py-2.5 last:border-b-0"
              >
                <span
                  className={`w-11 shrink-0 font-semibold tracking-wider ${
                    pass ? 'text-emerald-400' : 'text-amber-400'
                  }`}
                >
                  {verdict}
                </span>
                <span className="text-ink-400">{what}</span>
              </div>
            ))}
          </div>
          <p className="mt-3 text-2xs text-ink-500">
            Run against Robinhood Chain mainnet, not simulated.
          </p>

          <div className="mt-14 border-t border-void-700 pt-6 text-sm text-ink-500">
            <p>
              We intend to extract the safety layer described here into a standalone package for
              Orbit deployments; today it lives inside the protocol&rsquo;s own indexer.
            </p>
            <p className="mt-3">
              <Link href="/whitepaper#deployment" className="text-zor-400 hover:text-zor-300">
                Read the deployed contracts
              </Link>
            </p>
          </div>
        </div>
      </article>
    </>
  );
}
