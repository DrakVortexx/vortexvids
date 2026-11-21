import type { Metadata, Viewport } from "next";
import { Suspense } from "react";
import { Roboto } from "next/font/google";
import { Guide } from "@/components/Guide";
import { FlagPanelGate } from "@/components/flags/FlagPanelGate";
import { SiteFooter } from "@/components/launch/SiteFooter";
import { PathTracker } from "@/components/PathTracker";
import { TopBar } from "@/components/TopBar";
import { themeScript } from "@/lib/theme";
import { siteConfig } from "@/site.config";
import "./globals.css";

const roboto = Roboto({
  subsets: ["latin"],
  weight: ["400", "500", "700"],
  variable: "--font-roboto",
});

const siteUrl = (() => {
  try {
    return new URL(process.env["SITE_URL"] ?? "http://localhost:3000");
  } catch {
    return new URL("http://localhost:3000");
  }
})();

export const metadata: Metadata = {
  metadataBase: siteUrl,
  title: {
    default: siteConfig.siteName,
    template: `%s | ${siteConfig.siteName}`,
  },
  description: siteConfig.description,
  applicationName: siteConfig.siteName,
  alternates: { canonical: "/" },
  openGraph: {
    type: "website",
    siteName: siteConfig.siteName,
    title: siteConfig.siteName,
    description: siteConfig.description,
    url: "/",
  },
  twitter: {
    card: "summary_large_image",
    title: siteConfig.siteName,
    description: siteConfig.description,
  },
};

export const viewport: Viewport = {
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#ffffff" },
    { media: "(prefers-color-scheme: dark)", color: "#1a0b2e" },
  ],
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    // suppressHydrationWarning: the inline script may add the "dark" class before React hydrates.
    <html lang="en" className={`${roboto.variable} h-full antialiased`} suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: themeScript }} />
      </head>
      <body className="min-h-full pt-14">
        <a href="#content" className="skip-link">
          Skip to content
        </a>
        <TopBar />
        <Suspense fallback={null}>
          <PathTracker />
        </Suspense>
        <Suspense fallback={null}>
          <FlagPanelGate />
        </Suspense>
        <div className="flex">
          <Guide />
          <div className="flex min-w-0 flex-1 flex-col">
            <main id="content" tabIndex={-1} className="min-w-0 flex-1 outline-none">
              {children}
            </main>
            <SiteFooter />
          </div>
        </div>
      </body>
    </html>
  );
}
