import Link from "next/link";
import { ContactEmail, Owner, PublicPage, Section } from "@/components/launch/PublicPage";
import { siteConfig } from "@/site.config";

export const metadata = {
  title: "About | vortexvids",
  description: "What vortexvids is, who runs this copy and how to get in touch.",
  alternates: { canonical: "/about" },
};

/** /about: what the site is and who runs it. */
export default function AboutPage() {
  return (
    <PublicPage
      page="about"
      title="About vortexvids"
      intro={<p>A video platform, built in the open one feature at a time.</p>}
    >
      <Section title="What this is">
        <p>
          vortexvids is a video site with the feel of 2019 and 2020: channels, uploads, a watch page, a home feed,
          subscriptions, search, likes, comments, Snips, a creator studio, analytics and moderation.
        </p>
      </Section>
      <Section title="Who runs this copy">
        <p>
          This copy of vortexvids is run by <Owner value={siteConfig.ownerName} />. They decide what is allowed here,
          following the <Link href="/guidelines">Community Guidelines</Link> and the <Link href="/terms">Terms</Link>.
        </p>
      </Section>
      <Section title="Get in touch">
        <p>
          Write to <ContactEmail /> or use the <Link href="/contact">contact form</Link>. Journalists will find the logo
          and screenshots on the <Link href="/press">press page</Link>.
        </p>
      </Section>
    </PublicPage>
  );
}
