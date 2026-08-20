import type { Metadata } from "next";
import { headers } from "next/headers";
import { Inter, Geist_Mono } from "next/font/google";
import { SpeedInsights } from "@vercel/speed-insights/next";
import "./globals.css";
import { LiveBridge } from "@/components/live-bridge";
import { QuickSwitcher } from "@/components/quick-switcher";
import { SITE_URL } from "@/lib/site-url";

// Chrome sans = Inter, self-hosted by next/font (fonts are downloaded at build
// and served from our own origin — no runtime Google CDN fetch). Geist sans is
// retired from the chrome UI; Geist Mono stays for code spans (no mono token).
const inter = Inter({
  variable: "--font-inter",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
  // Mono is only used by small inline code spans + the error/404 pages — never
  // LCP or above-the-fold. Declaring it in the root layout otherwise makes
  // next/font auto-preload its woff2 on EVERY route, competing with the real
  // LCP (sans) font site-wide. Opt out of the preload: it still loads on demand
  // (with `swap`) the moment a code span mounts.
  preload: false,
});

export const metadata: Metadata = {
  // Set ONCE here so every page's OpenGraph/canonical/twitter URL resolves to
  // an absolute address (scrapers can't follow relative URLs, and Next warns
  // when metadataBase is unset). Same origin the sitemap/robots/feed derive.
  metadataBase: new URL(SITE_URL),
  title: "Barkpark",
  description:
    "Headless CMS demo — published posts from the Barkpark production dataset.",
};

export default async function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  // The CSP proxy (proxy.ts) mints a per-request nonce and forwards it on the
  // `x-nonce` request header. Read it here to nonce the inline theme-boot
  // script below — an enforcing `script-src` without `'unsafe-inline'` would
  // otherwise block it. `undefined` on the (proxy-excluded) paths that carry no
  // header, which renders the attribute absent (nil-safe).
  const nonce = (await headers()).get("x-nonce") ?? undefined;

  return (
    <html
      lang="en"
      className={`${inter.variable} ${geistMono.variable} h-full antialiased`}
      suppressHydrationWarning
    >
      <head>
        {/* Seed BOTH orthogonal theme switches BEFORE first paint (no FOUC, no
            next-themes dep):
              • data-theme (mode): localStorage.theme wins, else OS
                prefers-color-scheme — the emitted [data-theme="dark"] block flips
                every --color-* var.
              • data-bp-theme (identity): localStorage.bp_theme, default
                "evergreen" — the emitted [data-bp-theme=…] block swaps the
                palette. Identity and mode are independent (theme-system D23).
            The ThemeToggle island (styleguide) flips + persists these at runtime. */}
        <script
          nonce={nonce}
          dangerouslySetInnerHTML={{
            __html:
              "(function(){try{var t=localStorage.getItem('theme');if(t!=='light'&&t!=='dark'){t=window.matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light';}document.documentElement.dataset.theme=t;document.documentElement.dataset.bpTheme=localStorage.getItem('bp_theme')||'evergreen';}catch(e){}})();",
          }}
        />
      </head>
      <body className="min-h-full flex flex-col">
        {children}
        {/* Obsidian-style quick-switcher (Cmd-O / Ctrl-O). Client island,
            renders null until opened — no layout shift, no SSR cost. */}
        <QuickSwitcher />
        <LiveBridge />
        {/* Real-user Core Web Vitals (LCP/CLS/INP/TTFB) → Vercel Speed Insights.
            Lab data was all-green; this surfaces what real devices actually see. */}
        <SpeedInsights />
      </body>
    </html>
  );
}
