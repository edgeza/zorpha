import type { Metadata } from 'next';
import { LegalPage, LegalSection } from '@/components/marketing/LegalPage';
import { TOKEN } from '@/lib/tokenomics';

export const metadata: Metadata = {
  title: 'Privacy',
  description:
    'What Zorpha does and does not collect. No accounts, no tracking cookies, no analytics on wallet activity.',
};

export default function PrivacyPage() {
  return (
    <LegalPage title="Privacy" updated="1 September 2026">
      <LegalSection heading="The short version">
        <p>
          There are no accounts, no sign-ups, no tracking cookies and no advertising pixels. We do
          not ask for your name, email address or any identity document. Your wallet address is
          already public on a blockchain; we do not attempt to link it to a person.
        </p>
      </LegalSection>

      <LegalSection heading="What the site stores in your browser">
        <ul className="ml-4 list-disc space-y-2">
          <li>
            <strong className="text-ink-200">Wallet connection state.</strong> A cookie recording
            which wallet connector you chose, so the interface does not lose your connection between
            page loads. It contains no private key and no personal data, and clearing it simply
            disconnects you.
          </li>
          <li>
            <strong className="text-ink-200">Nothing else.</strong> No analytics identifiers, no
            session recording, no cross-site trackers, no fingerprinting.
          </li>
        </ul>
      </LegalSection>

      <LegalSection heading="What the site sends elsewhere">
        <ul className="ml-4 list-disc space-y-2">
          <li>
            <strong className="text-ink-200">Blockchain RPC requests.</strong> Reading contract
            state requires querying an RPC endpoint, which necessarily sees your IP address and the
            addresses you are asking about. This is inherent to reading a blockchain from a browser.
            Point the interface at your own node if that matters to you.
          </li>
          <li>
            <strong className="text-ink-200">Indexer queries.</strong> Receipts and manager records
            are served from our indexer database. Those queries are for public on-chain data.
          </li>
          <li>
            <strong className="text-ink-200">Airdrop eligibility lookups.</strong> When you connect
            a wallet on the airdrop page, the interface asks our server whether that address has an
            allocation. The address is sent to check the snapshot; it is not stored against a
            profile.
          </li>
          <li>
            <strong className="text-ink-200">Fonts.</strong> Typefaces are served from this site,
            not from a third-party font CDN, so no font provider sees your visit.
          </li>
        </ul>
      </LegalSection>

      <LegalSection heading="Server logs">
        <p>
          Our hosting provider keeps standard access logs (IP address, timestamp, requested path,
          user agent) for operational and abuse-prevention purposes. These are retained for a
          limited period and are not used to build profiles or combined with on-chain activity.
        </p>
      </LegalSection>

      <LegalSection heading="What we cannot delete">
        <p>
          Anything written to the blockchain is permanent and outside anyone&rsquo;s control,
          including ours. A deposit, a claim, a delegation or a rebalance is a public record for as
          long as the chain exists. No privacy policy can undo that, and you should treat every
          on-chain action as permanently public before you take it.
        </p>
      </LegalSection>

      <LegalSection heading="Children">
        <p>
          This interface is not directed at anyone under the age of majority in their jurisdiction,
          and we do not knowingly collect information from them.
        </p>
      </LegalSection>

      <LegalSection heading="Contact">
        <p>
          Privacy questions and security reports can be raised through the protocol repository. See{' '}
          <span className="font-mono">docs/SECURITY.md</span> for disclosure details, or the contact
          published at <span className="font-mono">{TOKEN.domain}</span>.
        </p>
      </LegalSection>
    </LegalPage>
  );
}
