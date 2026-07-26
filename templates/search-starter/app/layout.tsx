import type { Metadata } from "next";
import "./globals.css";
import { siteMarkers } from "@/lib/markers";
import { SITE_TAGLINE } from "@/lib/config";

// The description is the SAME string the hero renders (`lib/config`), not a
// second hand-written pitch — a search result and the page it opens must not
// promise different things.
export const metadata: Metadata = {
  title: "Search — Barkpark",
  description: SITE_TAGLINE,
};

/**
 * Root layout for the standalone search-starter.
 *
 * Deliberately lean vs the `web/` demo's root layout: no Google-font network
 * fetch (a self-hosted system stack keeps the build offline-safe and fast), no
 * QuickSwitcher / LiveBridge / SpeedInsights islands — just the theme seed and
 * the two boot-env HEALTH markers every route inherits.
 *
 * The `bp-build-id` / `bp-content-rev` markers live HERE (in `<head>`, on every
 * route) so the deploy gate reads them wherever it probes; the per-document
 * `bp-doc-id` marker is emitted by the landing + detail pages (which know a real
 * content-document id). See `lib/markers.ts` + `deploy/site-deploy-node.sh`.
 */
export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  const markers = siteMarkers();
  return (
    <html lang="en" className="h-full antialiased" suppressHydrationWarning>
      <head>
        {/* Content-truth HEALTH markers (build + content revision) — read at
            request time from the slot boot env; present on every route. */}
        <meta name="bp-build-id" content={markers.buildId} />
        <meta name="bp-content-rev" content={markers.contentRev} />
        <meta name="bp-site-base" content={markers.siteBase} />
        {/* Seed BOTH theme switches BEFORE first paint (no FOUC, no next-themes
            dep). `data-theme` (mode): localStorage.theme, else OS preference —
            the emitted [data-theme="dark"] block flips every --color-* var, and
            the graph reads this exact attribute (born correct, charter D11).
            `data-bp-theme` (identity): localStorage.bp_theme, default the
            DEPLOY-pinned palette (BARKPARK_THEME baked at build via
            next.config env — the per-deploy theme dimension, W2) falling back
            to evergreen. A visitor's own picker choice still wins. */}
        <script
          dangerouslySetInnerHTML={{
            __html:
              "(function(){try{var t=localStorage.getItem('theme');if(t!=='light'&&t!=='dark'){t=window.matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light';}document.documentElement.dataset.theme=t;document.documentElement.dataset.bpTheme=localStorage.getItem('bp_theme')||" +
              JSON.stringify(process.env.NEXT_PUBLIC_BARKPARK_THEME || "evergreen") +
              ";}catch(e){}})();",
          }}
        />
      </head>
      <body className="min-h-full flex flex-col">{children}</body>
    </html>
  );
}
