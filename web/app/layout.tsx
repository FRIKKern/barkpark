import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import { SpeedInsights } from "@vercel/speed-insights/next";
import "./globals.css";
import { LiveBridge } from "@/components/live-bridge";
import { QuickSwitcher } from "@/components/quick-switcher";
import { SITE_URL } from "@/lib/site-url";

const geistSans = Geist({
  variable: "--font-geist-sans",
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

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="en"
      className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}
    >
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
