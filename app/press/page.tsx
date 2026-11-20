import Image from "next/image";
import Link from "next/link";
import { ContactEmail, Owner, PublicPage, Section } from "@/components/launch/PublicPage";
import { PRESS_SHOTS } from "@/lib/launch/press";
import { siteConfig } from "@/site.config";

export const metadata = {
  title: "Press | vortexvids",
  description: "The vortexvids logo, a short description and screenshots to use in articles and videos.",
  alternates: { canonical: "/press" },
};

/** /press: the logo, a short description and screenshots (public/press, made by scripts/press-kit.mjs). */
export default function PressPage() {
  return (
    <PublicPage page="press" title="Press" wide intro={<p>Writing about vortexvids? Everything on this page is free to use.</p>}>
      <Section title="In one paragraph">
        <p>
          vortexvids is a video platform in the style of 2019 and 2020 video sites. It has channels, uploads with HLS playback, a home feed, subscriptions,
          search, likes, comments, Snips, a creator studio with analytics, and moderation. This copy is run by <Owner value={siteConfig.ownerName} />.
        </p>
      </Section>
      <Section title="Logo">
        <div className="mt-3 flex flex-wrap items-center gap-6">
          <a href="/press/vortexvids-logo.svg" download className="grid h-[120px] w-[280px] place-items-center rounded-[2px] bg-white ring-1 ring-divider">
            <Image src="/press/vortexvids-logo.svg" alt="The vortexvids logo: a purple vortex spiral and the word vortexvids" width={224} height={48} unoptimized />
          </a>
          <a href="/press/vortexvids-mark.svg" download className="grid h-[120px] w-[160px] place-items-center rounded-[2px] bg-[#202020]">
            <Image src="/press/vortexvids-mark.svg" alt="The vortexvids mark on its own" width={72} height={72} unoptimized />
          </a>
        </div>
        <p className="mt-3">
          Click a logo to download the SVG. Keep the purple as it is (#7c3aed for the mark, #6d28d9 for the word vortex) and leave some space around it.
          vortexvids is not affiliated with YouTube or Google.
        </p>
      </Section>
      <Section title="Screenshots">
        <ul className="!list-none !pl-0 mt-3 grid grid-cols-1 gap-6 sm:grid-cols-2" data-press-shots={PRESS_SHOTS.length}>
          {PRESS_SHOTS.map((shot) => (
            <li key={shot.name} className="!mt-0">
              <a href={`/press/${shot.name}.webp`} className="block overflow-hidden rounded-[2px] ring-1 ring-divider">
                <Image
                  src={`/press/${shot.name}.webp`}
                  alt={shot.alt}
                  width={shot.width}
                  height={shot.height}
                  sizes="(min-width: 1100px) 510px, (min-width: 640px) 45vw, 100vw"
                  className="h-auto w-full bg-skeleton"
                />
              </a>
              <p className="mt-2 text-[13px] text-text-2">{shot.alt}</p>
            </li>
          ))}
        </ul>
      </Section>
      <Section title="Contact">
        <p>
          For interviews and questions write to <ContactEmail /> or use the <Link href="/contact">contact form</Link> and
          pick &quot;Press&quot;.
        </p>
      </Section>
    </PublicPage>
  );
}
