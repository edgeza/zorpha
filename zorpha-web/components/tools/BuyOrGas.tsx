'use client';

import { useState } from 'react';
import { BridgePanel } from '@/components/tools/BridgePanel';

/**
 * The buy widget, plus the escape hatch for the trap sitting behind it.
 *
 * Robinhood Chain charges gas in ETH. A visitor who bridges in and buys ZOR
 * arrives holding a token and nothing to pay gas with, because the bridge's
 * own relayer covers the delivery and asks the buyer for nothing. Nothing
 * fails, nothing warns, and the purchase completes exactly as promised. The
 * bill lands later, the first time they try to move or sell, and by then they
 * cannot even approve the spend without going back to another chain for gas.
 *
 * LI.FI cannot fold this into the purchase. Its gas-on-destination feature
 * answers `{"available":false,"message":"Chain 4663 is not supported at the
 * moment"}`, so a single route that delivers both ZOR and gas does not exist.
 * What does work is bridging to the native token directly, which is the same
 * destination reached in a second transaction, so that is what this offers.
 *
 * Two dollars is the suggestion because it is genuinely enough rather than a
 * round number: measured on 7 September 2026 the chain wanted 0.31 gwei, which
 * puts an approve plus a swap at about eighteen cents.
 */

/** ZOR, the thing people came for. */
const ZOR = '0x9684AFe2422a0B03719201c78959b6B70e8d4ae8';

/** The zero address is native ETH, which on chain 4663 is the gas token. */
const NATIVE_ETH = '0x0000000000000000000000000000000000000000';

type Mode = 'zor' | 'gas';

const MODES: { id: Mode; label: string; token: string }[] = [
  { id: 'zor', label: 'Buy ZOR', token: ZOR },
  { id: 'gas', label: 'Get gas', token: NATIVE_ETH },
];

export function BuyOrGas() {
  const [mode, setMode] = useState<Mode>('zor');
  const active = MODES.find((m) => m.id === mode) ?? MODES[0];

  return (
    /*
      The page gives this a negative margin so the widget runs edge to edge on
      a phone. The text and the control around it still want the shell's
      gutter, so the padding comes back here and is dropped again from `sm`,
      where the negative margin no longer applies.
    */
    <div>
      {/*
        Deliberately not spending the accent here. The violet marks the widget
        frame and the one figure that matters; a highlighted mode switch would
        make a third thing shout on a page built around a single focal point.
        The raised surface carries the state on its own.
      */}
      <div
        role="group"
        aria-label="What to bridge for"
        className="mb-4 ml-5 inline-flex rounded-full border border-void-700 bg-void-900/80 p-1 sm:ml-0"
      >
        {MODES.map((m) => {
          const selected = m.id === mode;
          return (
            <button
              key={m.id}
              type="button"
              onClick={() => setMode(m.id)}
              aria-pressed={selected}
              className={`rounded-full px-4 py-2 text-sm transition-colors duration-150 ${
                selected
                  ? 'bg-void-700 font-medium text-ink-100'
                  : 'text-ink-400 hover:text-ink-100'
              }`}
            >
              {m.label}
            </button>
          );
        })}
      </div>

      {mode === 'gas' ? (
        <p className="mb-4 ml-5 mr-5 max-w-[420px] text-sm leading-relaxed text-ink-400 sm:mx-0">
          Robinhood Chain charges gas in ETH, and buying ZOR does not leave you any. Send about two
          dollars of anything here and you will have enough for roughly a dozen transactions, which
          is what it takes to move or sell later.
        </p>
      ) : null}

      {/*
        Remounted on switch rather than reconfigured in place. The widget holds
        a route, an amount and a quote for the destination it was built with,
        and none of that survives a change of purpose intact. Throwing it away
        is the honest outcome and costs a visitor nothing they wanted to keep.
      */}
      <div className="sm:rounded-card sm:shadow-glow">
        <BridgePanel key={active.id} toToken={active.token} />
      </div>
    </div>
  );
}
