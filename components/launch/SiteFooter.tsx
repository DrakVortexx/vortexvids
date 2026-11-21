"use client";

import Link from "next/link";
import { LogoMark } from "@/components/icons";
import { PUBLIC_LINKS } from "@/lib/launch/links";
import { useFlag } from "@/lib/store/session";
import { siteConfig } from "@/site.config";

/**
 * The links at the bottom of every page (feature 15), in the small grey
 * 2019 style of the guide's footer. Behind the launch flag.
 */
export function SiteFooter() {
  const on = useFlag("launch");
  if (!on) return null;
  return (
    <footer className="mt-8 border-t border-divider px-4 py-8 sm:px-6" data-site-footer>
      <div className="mx-auto flex max-w-[1400px] flex-col gap-6 sm:flex-row sm:items-start sm:justify-between">
        <div className="flex items-center gap-2 text-text">
          <LogoMark className="h-7 w-7 shrink-0" />
          <span className="text-[15px] font-semibold tracking-tight">{siteConfig.siteName}</span>
          <span className="hidden text-[13px] text-text-3 sm:inline">· {siteConfig.description}</span>
        </div>
        <nav aria-label="Footer" className="min-w-0">
          <ul className="flex flex-wrap gap-x-3 gap-y-2 text-[13px] font-medium leading-5 text-text-2">
            {PUBLIC_LINKS.map((l) => (
              <li key={l.href}>
                <Link href={l.href} prefetch={false} className="hover:text-link hover:underline">
                  {l.label}
                </Link>
              </li>
            ))}
            <li>
              <a href={siteConfig.sourceUrl} target="_blank" rel="noreferrer" className="hover:text-link hover:underline">
                Source
              </a>
            </li>
          </ul>
        </nav>
      </div>
    </footer>
  );
}

/** The same links in the guide's footer, as in the 2019 left menu. */
export function GuideFooterLinks() {
  const on = useFlag("launch");
  if (!on) return null;
  return (
    <ul className="flex flex-wrap gap-x-2 gap-y-1 px-6 pt-4 text-[13px] font-medium leading-[18px] text-text-2" data-guide-footer>
      {PUBLIC_LINKS.map((l) => (
        <li key={l.href}>
          <Link href={l.href} prefetch={false} className="hover:text-text">
            {l.label}
          </Link>
        </li>
      ))}
    </ul>
  );
}
