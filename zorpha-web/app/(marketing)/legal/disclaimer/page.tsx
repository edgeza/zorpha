import Link from 'next/link';
import type { Metadata } from 'next';
import { LegalPage, LegalSection } from '@/components/marketing/LegalPage';
import { TOKEN } from '@/lib/tokenomics';
import { countBy } from '@/lib/audit';

export const metadata: Metadata = {
  title: 'Risk disclaimer',
  description:
    'The specific risks of using Zorpha vaults and holding $ZOR, including unresolved audit findings and the possibility of total loss.',
};

export default function DisclaimerPage() {
  return (
    <LegalPage title="Risk disclaimer" updated="1 September 2026">
      <LegalSection heading="You can lose everything">
        <p>
          Depositing into a smart contract exposes you to total, permanent, unrecoverable loss of
          your funds. There is no deposit insurance, no chargeback, no support desk that can reverse
          a transaction, and no legal recourse against a contract. Do not deposit money you cannot
          afford to lose entirely.
        </p>
      </LegalSection>

      <LegalSection heading="Bugs were found in this code, and more may remain">
        <p>
          Our internal review found {countBy('fixed')} issues, including a critical defect in the
          USDC yield vault which valued shares against a yield-adapter balance it never funded — a
          depositor could have burned their entire share position and received nothing while their
          principal remained stranded in the contract. Two further high-severity findings affected
          the signed rebalance path and the reputation registry.
        </p>
        <p>
          All {countBy('fixed')} are fixed and covered by regression tests. That is not the same as
          the code being free of defects: it means the defects we were capable of finding are
          closed. Software that has had {countBy('fixed')} issues found in it has, historically, had
          more.{' '}
          <Link href="/security" className="link-quiet">
            Every finding is published here
          </Link>
          .
        </p>
      </LegalSection>

      <LegalSection heading="No third-party audit has been performed">
        <p>
          The contracts have been reviewed internally by the people who wrote them. That is useful
          and it is not an audit. No external security firm has examined this code. An internal
          review reliably finds the bugs its authors are capable of imagining.
        </p>
      </LegalSection>

      <LegalSection heading="Nothing here is investment advice">
        <p>
          Nothing on this website is investment, financial, legal or tax advice, an offer to sell,
          a solicitation to buy, or a recommendation regarding any asset. Nobody involved in Zorpha
          is acting as your adviser, broker or fiduciary. Historical receipts describe what happened
          and imply nothing whatsoever about what will happen.
        </p>
      </LegalSection>

      <LegalSection heading={`What ${TOKEN.ticker} is not`}>
        <p>
          {TOKEN.ticker} does not entitle you to dividends, interest, profit share, revenue share,
          or any claim on the assets of the protocol, the treasury or any entity. The buyback
          mechanism reduces token supply; it is not a distribution to holders and it is not a
          commitment about price. No statement on this site should be read as forecasting a price,
          a market capitalisation, a return, or a listing.
        </p>
      </LegalSection>

      <LegalSection heading="Specific risks">
        <ul className="ml-4 list-disc space-y-2">
          <li>
            <strong className="text-ink-200">Smart contract risk.</strong> Code may contain defects,
            including ones nobody has found yet. Some are already known and published.
          </li>
          <li>
            <strong className="text-ink-200">Oracle risk.</strong> Price feeds can be stale, wrong,
            manipulated, or unavailable. Vaults fail closed where possible, which converts a pricing
            failure into an availability failure rather than a loss — but not in every case.
          </li>
          <li>
            <strong className="text-ink-200">Manager risk.</strong> Managers can be wrong,
            repeatedly, in ways that are entirely visible and still lose you money. Verifiability
            is not skill.
          </li>
          <li>
            <strong className="text-ink-200">Key compromise.</strong> A stolen manager key can push
            vault exposure to a harmful target within the vault&rsquo;s limits until it is rotated.
          </li>
          <li>
            <strong className="text-ink-200">Underlying asset risk.</strong> Tokenised equities can
            fall in value, be halted, be delisted, or diverge in price from the asset they
            reference.
          </li>
          <li>
            <strong className="text-ink-200">Liquidity risk.</strong> There may be no market in
            which to sell {TOKEN.ticker} or a vault share at any particular price, or at all.
          </li>
          <li>
            <strong className="text-ink-200">Governance risk.</strong> Privileged roles exist. They
            are behind a 48-hour timelock and a multisig, which delays and publicises their use
            rather than preventing it.
          </li>
          <li>
            <strong className="text-ink-200">Regulatory risk.</strong> The treatment of tokens and
            tokenised securities varies by jurisdiction and can change, including retroactively.
          </li>
          <li>
            <strong className="text-ink-200">Testnet status.</strong> Everything is currently
            deployed to testnet. Testnet assets have no value, and testnet state can be reset or
            discarded without notice.
          </li>
        </ul>
      </LegalSection>

      <LegalSection heading="Impersonation">
        <p>
          {TOKEN.name} is not deployed to any mainnet. Any token presented as {TOKEN.ticker} on a
          mainnet today is not ours. Always verify contract addresses against{' '}
          <span className="font-mono">{TOKEN.domain}</span> before interacting with anything.
        </p>
      </LegalSection>

      <LegalSection heading="Your responsibility">
        <p>
          You are responsible for determining whether you are permitted to use this software where
          you live, for your own tax position, and for the security of your own keys. If any part of
          this document is unclear, the correct response is to take professional advice, not to
          proceed and hope.
        </p>
      </LegalSection>
    </LegalPage>
  );
}
