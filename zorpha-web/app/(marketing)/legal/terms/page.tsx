import Link from 'next/link';
import type { Metadata } from 'next';
import { LegalPage, LegalSection } from '@/components/marketing/LegalPage';
import { TOKEN } from '@/lib/tokenomics';

export const metadata: Metadata = {
  title: 'Terms of use',
  description: 'Terms governing use of the Zorpha website and portal interface.',
};

export default function TermsPage() {
  return (
    <LegalPage title="Terms of use" updated="1 September 2026">
      <LegalSection heading="1. What this covers">
        <p>
          These terms govern your use of the {TOKEN.domain} website and the portal interface hosted
          on it. They do not and cannot govern the smart contracts themselves: those are deployed
          on a public blockchain, they execute for anyone who calls them, and nobody, including us,
          can stop, reverse or modify them on your behalf.
        </p>
      </LegalSection>

      <LegalSection heading="2. The interface is not the protocol">
        <p>
          This website is one convenience layer over public contracts. It holds no funds, takes no
          custody, and never has access to your private keys. If it goes offline, the contracts
          continue to operate and remain callable directly. Records displayed here are read from the
          chain and from an indexer that follows it; the chain is authoritative.
        </p>
      </LegalSection>

      <LegalSection heading="3. No advice, no fiduciary relationship">
        <p>
          Nothing provided through this interface is investment, legal, tax or financial advice. We
          are not your broker, adviser or fiduciary, and no communication from us creates such a
          relationship. See the{' '}
          <Link href="/legal/disclaimer" className="link-quiet">
            risk disclaimer
          </Link>{' '}
          for the specific risks involved.
        </p>
      </LegalSection>

      <LegalSection heading="4. Eligibility">
        <p>
          You may not use this interface if doing so would breach the law where you are, if you are
          subject to applicable sanctions, or if you are below the age of majority in your
          jurisdiction. Determining your own eligibility is your responsibility. We may restrict
          access from particular jurisdictions without notice.
        </p>
      </LegalSection>

      <LegalSection heading="5. Your responsibilities">
        <ul className="ml-4 list-disc space-y-2">
          <li>Securing your own wallet, seed phrase and private keys. We cannot recover them.</li>
          <li>Verifying every contract address you interact with before signing anything.</li>
          <li>Reviewing what you are signing. A transaction, once broadcast, is final.</li>
          <li>Your own tax reporting and compliance obligations.</li>
        </ul>
      </LegalSection>

      <LegalSection heading="6. No warranty">
        <p>
          This interface and the underlying software are provided &ldquo;as is&rdquo; and &ldquo;as
          available&rdquo;, without warranty of any kind, express or implied, including
          merchantability, fitness for a particular purpose, and non-infringement. We do not warrant
          that the interface will be uninterrupted, accurate, or free of defects. Known defects are
          published on the{' '}
          <Link href="/security" className="link-quiet">
            security page
          </Link>
          .
        </p>
      </LegalSection>

      <LegalSection heading="7. Limitation of liability">
        <p>
          To the maximum extent permitted by law, no contributor to Zorpha is liable for any
          indirect, incidental, special, consequential or exemplary damages, or for any loss of
          funds, profits, tokens or data, arising from your use of this interface or of the
          protocol contracts, including losses caused by smart contract defects, oracle failure,
          manager conduct, network conditions, or your own error.
        </p>
      </LegalSection>

      <LegalSection heading="8. Third-party content">
        <p>
          Vault names, manager labels, and any other user-supplied content are not endorsements. A
          manager appearing in this interface has not been vetted, licensed or approved by us in any
          regulatory sense, and their presence implies no view about their competence.
        </p>
      </LegalSection>

      <LegalSection heading="9. Intellectual property">
        <p>
          The protocol contracts are released under the MIT licence and you may use, fork and
          deploy them accordingly. The Zorpha name, wordmark and visual identity are not covered by
          that licence. Do not use them to present a fork as though it were this project.
        </p>
      </LegalSection>

      <LegalSection heading="10. Changes">
        <p>
          These terms may be updated, and the date at the top of this page will change when they
          are. Continuing to use the interface after an update constitutes acceptance. Material
          changes will be noted in the release notes for the site.
        </p>
      </LegalSection>
    </LegalPage>
  );
}
