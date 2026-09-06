import type { Metadata } from 'next';
import { ManagerTerminal } from '@/components/portal/terminal/ManagerTerminal';

export const metadata: Metadata = {
  title: 'Terminal',
  description:
    'Operate a Zorpha vault: position, guard rails, and every action your address is permitted to take.',
};

export default function ManagePage() {
  return (
    <div className="flex flex-col gap-8">
      <header>
        <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Terminal</h1>
        <p className="mt-3 max-w-2xl text-sm leading-relaxed text-ink-400">
          Everything you are permitted to do to a vault, in one place, with the state you need to
          choose between those things. Actions enable only when the chain says your address holds
          the role the contract requires.
        </p>
        <p className="mt-2 max-w-2xl text-sm leading-relaxed text-ink-400">
          There is deliberately no free-form trading here. A manager&rsquo;s whole discretion is
          one rebalance instruction inside a slippage bound the contract enforces; which is the
          reason a Zorpha track record means something, and the reason a manager cannot take your
          deposit anywhere you did not agree to.
        </p>
      </header>

      <ManagerTerminal />
    </div>
  );
}
