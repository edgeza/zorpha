'use client';

import { useMemo, useState } from 'react';
import { keccak256, encodeAbiParameters, parseAbiParameters, type Hex } from 'viem';

/**
 * The receipt, checked in the reader's own browser.
 *
 * WHY THIS REPLACED THE DIAGRAM
 *
 * ReceiptAnatomy taught the shape of a receipt using invented values, and said
 * so. That was the honest call at the time -- there was no real receipt to
 * show. Its own comment made the case: fabricated evidence under the heading
 * "do not trust a manager's summary, read the chain" does more damage than a
 * blank space.
 *
 * There is now a real one. The rotation vault emitted it on testnet 46630 at
 * block 112,417,756, and every field below is that event's actual payload.
 *
 * More to the point, the page has always claimed "change one number and it
 * stops matching" and never once demonstrated it. That sentence is the whole
 * product, and it is checkable in about fifty lines. So the reader edits a
 * field and watches the commitment diverge from the one the chain recorded.
 *
 * NOTHING HERE TALKS TO A SERVER
 *
 * The hash is computed locally, from constants compiled into the page. That is
 * deliberate: a verifier that phones home asks you to trust the same people
 * whose claim you are checking. Open devtools, read the arithmetic, or paste
 * the fields into your own keccak -- the answer does not depend on us being
 * honest, which is the only kind of proof this protocol is selling.
 *
 * THE PREIMAGE HAS TO BE EXACT
 *
 * `ReceiptRenderer.basketCommitment` uses `abi.encode`, NOT `encodePacked` --
 * two dynamic arrays packed together are ambiguous and admit collisions, and
 * the library says so at the definition. The parameter order below is that
 * function's signature, in order. Verified against the live chain before
 * shipping: this code reproduces 0x28765283… byte for byte.
 *
 * `manager` is the EXECUTOR, not the EOA that paid for the transaction. The
 * vault records `msg.sender`, and a signed rebalance reaches the vault through
 * StrategyExecutor. Using the submitter's address here produces a hash that
 * looks plausible and matches nothing -- worth stating, because it is the one
 * field a re-implementation gets wrong.
 */

/** The event payload, exactly as `Rebalanced` carried it. Do not "tidy" these. */
const ONCHAIN = {
  manager: '0xb432d76083ee4985cf34bfb12efdebc298e66a07' as Hex,
  vault: '0x15257073a761021d37852453d4bde2fba8fcc9e6' as Hex,
  weights: [7000, 3000] as const,
  nav: 1_000_000n,
  tokenLegs: [0n, 0n] as const,
  baseLeg: 0n,
  nonce: 1n,
  timestamp: 1_788_458_573n,
  /** Filled by the indexer off-chain; zero in the emitted event. */
  txHash: `0x${'00'.repeat(32)}` as Hex,
  commitment:
    '0x28765283b075662fa21af1566ed5d0b7730f9ac9f94f753789e95ed780d5d82c' as Hex,
  tx: '0x6d2ab9adc9c004ace161e0f2bf4904317c17b84e72a5ef417b823bfbd60a3869',
  block: 112_417_756,
  /**
   * The TESTNET explorer, hardcoded, because this receipt is a testnet artifact
   * and permanently will be.
   *
   * This link used to be built from NEXT_PUBLIC_EXPLORER_URL, so when the site
   * moved to mainnet it started pointing a testnet transaction hash at the
   * mainnet explorer. That does not 404: Blockscout is a single-page app that
   * answers 200 for any /tx/ path and resolves client-side, so the reader got a
   * details page with the block, the sender and the recipient all permanently
   * blank, a nonsense "5y ago" timestamp, and no error saying why. A dead end
   * with no explanation, on the one link the home page offers as proof.
   *
   * Deriving it from config would reintroduce exactly that: the environment
   * says which chain the SITE is on, and this receipt is not on that chain.
   */
  explorerBase: 'https://explorer.testnet.chain.robinhood.com',
};

const COMMITMENT_TYPES = parseAbiParameters(
  'address, address, uint16[], uint256, uint256[], uint256, uint256, uint256, bytes32',
);

function shorten(hex: string, lead = 10, tail = 8) {
  return `${hex.slice(0, lead)}…${hex.slice(-tail)}`;
}

export function ReceiptVerifier() {
  const [weightA, setWeightA] = useState(String(ONCHAIN.weights[0]));
  const [weightB, setWeightB] = useState(String(ONCHAIN.weights[1]));
  const [nav, setNav] = useState(ONCHAIN.nav.toString());
  const [nonce, setNonce] = useState(ONCHAIN.nonce.toString());

  const computed = useMemo(() => {
    // A half-typed field is a normal state, not an error state. Return null and
    // let the UI say "incomplete" rather than throwing on every keystroke.
    const toBig = (s: string) => {
      const t = s.trim();
      if (t === '' || !/^\d+$/.test(t)) return null;
      return BigInt(t);
    };
    const a = toBig(weightA);
    const b = toBig(weightB);
    const n = toBig(nav);
    const c = toBig(nonce);
    if (a === null || b === null || n === null || c === null) return null;
    if (a > 65535n || b > 65535n) return null; // uint16[] would revert on encode

    try {
      return keccak256(
        encodeAbiParameters(COMMITMENT_TYPES, [
          ONCHAIN.manager,
          ONCHAIN.vault,
          [Number(a), Number(b)],
          n,
          [...ONCHAIN.tokenLegs],
          ONCHAIN.baseLeg,
          c,
          ONCHAIN.timestamp,
          ONCHAIN.txHash,
        ]),
      );
    } catch {
      return null;
    }
  }, [weightA, weightB, nav, nonce]);

  const matches = computed !== null && computed === ONCHAIN.commitment;
  const untouched =
    weightA === String(ONCHAIN.weights[0]) &&
    weightB === String(ONCHAIN.weights[1]) &&
    nav === ONCHAIN.nav.toString() &&
    nonce === ONCHAIN.nonce.toString();

  function restore() {
    setWeightA(String(ONCHAIN.weights[0]));
    setWeightB(String(ONCHAIN.weights[1]));
    setNav(ONCHAIN.nav.toString());
    setNonce(ONCHAIN.nonce.toString());
  }

  function tamper() {
    setWeightA(String(Number(ONCHAIN.weights[0]) + 1));
  }

  return (
    <div className="card overflow-hidden">
      <div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-2 border-b border-void-700 bg-void-850 px-5 py-3.5">
        <div className="flex items-center gap-2">
          <span className="h-1.5 w-1.5 rounded-full bg-verified-400" />
          <span className="font-mono text-xs text-ink-300">Rebalanced</span>
        </div>
        <a
          href={`${ONCHAIN.explorerBase}/tx/${ONCHAIN.tx}`}
          target="_blank"
          rel="noreferrer"
          className="font-mono text-2xs text-ink-500 underline-offset-2 hover:text-ink-300 hover:underline"
        >
          block {ONCHAIN.block.toLocaleString('en-US')} ↗
        </a>
      </div>

      <dl className="divide-hair px-5">
        <Row label="manager" note="StrategyExecutor. The vault records msg.sender, not whoever paid the gas.">
          <span className="font-mono text-sm text-ink-100">{shorten(ONCHAIN.manager)}</span>
        </Row>

        <Row label="targetBps" note="The basket weights requested. Intent, recorded before the fill.">
          <div className="flex items-center gap-2">
            <NumField value={weightA} onChange={setWeightA} label="weight 0, basis points" />
            <span className="text-ink-500">/</span>
            <NumField value={weightB} onChange={setWeightB} label="weight 1, basis points" />
          </div>
        </Row>

        <Row label="navInBase" note="NAV per share at execution, in base-asset units.">
          <NumField value={nav} onChange={setNav} label="nav in base units" wide />
        </Row>

        <Row label="nonce" note="Strictly increasing. A skipped nonce is a visible gap in the record.">
          <NumField value={nonce} onChange={setNonce} label="nonce" />
        </Row>

        <Row
          label="commitment"
          note="keccak256 over every field above. Computed here, in your browser, from the contract's own encoding."
        >
          <span
            className={`break-all font-mono text-sm ${matches ? 'text-verified-400' : 'text-danger-400'}`}
          >
            {computed ? shorten(computed, 12, 10) : 'incomplete'}
          </span>
        </Row>
      </dl>

      <div
        className={`border-t px-5 py-4 ${
          matches ? 'border-void-700 bg-void-850' : 'border-danger-500/40 bg-danger-500/10'
        }`}
      >
        {matches ? (
          <>
            <p className="text-xs font-semibold leading-relaxed text-verified-400">
              Matches the commitment the chain recorded.
            </p>
            <p className="mt-1.5 text-xs leading-relaxed text-ink-400">
              Change any number above and this stops matching. That is the whole guarantee; not
              that we are honest, but that the record cannot be edited after the fact.{' '}
              <button
                type="button"
                onClick={tamper}
                className="text-zor-300 underline underline-offset-2 hover:text-zor-200"
              >
                Try it
              </button>
              .
            </p>
          </>
        ) : (
          <>
            <p className="text-xs font-semibold leading-relaxed text-danger-400">
              {computed ? 'Does not match. This receipt has been altered.' : 'Enter a whole number in every field.'}
            </p>
            <p className="mt-1.5 text-xs leading-relaxed text-ink-400">
              On chain: <span className="font-mono">{shorten(ONCHAIN.commitment, 12, 10)}</span>.{' '}
              <button
                type="button"
                onClick={restore}
                className="text-zor-300 underline underline-offset-2 hover:text-zor-200"
              >
                Restore the real values
              </button>
              .
            </p>
          </>
        )}
      </div>

      <div className="border-t border-void-700 bg-void-900 px-5 py-3.5">
        <p className="text-xs leading-relaxed text-ink-400">
          A real receipt from the rotation vault on Robinhood Chain testnet. Its token legs are zero
          because the vault held nothing when the rebalance ran; it proves the mechanism, not a
          position. Emitted by the vault contract itself, so it exists whether or not this website
          does.
        </p>
        {!untouched && (
          <button type="button" onClick={restore} className="btn btn-quiet btn-sm mt-3">
            Reset to the on-chain receipt
          </button>
        )}
      </div>
    </div>
  );
}

function Row({
  label,
  note,
  children,
}: {
  label: string;
  note: string;
  children: React.ReactNode;
}) {
  return (
    <div className="py-4">
      <div className="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-2">
        <dt className="font-mono text-xs text-zor-300">{label}</dt>
        <dd className="font-mono text-sm text-ink-100">{children}</dd>
      </div>
      <p className="mt-1.5 text-xs leading-relaxed text-ink-500">{note}</p>
    </div>
  );
}

function NumField({
  value,
  onChange,
  label,
  wide = false,
}: {
  value: string;
  onChange: (v: string) => void;
  label: string;
  wide?: boolean;
}) {
  return (
    <input
      type="text"
      inputMode="numeric"
      aria-label={label}
      value={value}
      onChange={(e) => onChange(e.target.value)}
      className={`input px-2 py-1 text-right tabular-nums ${wide ? 'w-32' : 'w-20'}`}
    />
  );
}
