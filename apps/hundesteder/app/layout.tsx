import type { Metadata } from "next";
import { Fraunces, Inter_Tight, JetBrains_Mono } from "next/font/google";
import { SiteHeader } from "@/components/site-header";
import { SiteFooter } from "@/components/site-footer";
import "./globals.css";

/* The Pawtrails tokens reference these three CSS variables on <html>:
 *   --font-fraunces · --font-inter-tight · --font-jetbrains-mono */

const fraunces = Fraunces({
  subsets: ["latin"],
  display: "swap",
  variable: "--font-fraunces",
  axes: ["opsz", "SOFT"],
});

const interTight = Inter_Tight({
  subsets: ["latin"],
  display: "swap",
  variable: "--font-inter-tight",
});

const jetbrainsMono = JetBrains_Mono({
  subsets: ["latin"],
  display: "swap",
  variable: "--font-jetbrains-mono",
});

const SITE_URL = "https://hundesteder.vercel.app";

export const metadata: Metadata = {
  metadataBase: new URL(SITE_URL),
  title: {
    default: "Hundesteder — hundevennlige steder i Norge",
    template: "%s · Hundesteder",
  },
  description:
    "En redaksjonell guide til hundevennlige steder i Norge — kafeer, parker, strender og severdigheter der hunden er velkommen.",
  openGraph: {
    title: "Hundesteder — hundevennlige steder i Norge",
    description:
      "En redaksjonell guide til hundevennlige steder i Norge — kafeer, parker, strender og severdigheter der hunden er velkommen.",
    type: "website",
    locale: "nb_NO",
    url: SITE_URL,
  },
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html
      lang="nb"
      className={`${fraunces.variable} ${interTight.variable} ${jetbrainsMono.variable}`}
    >
      <body>
        <SiteHeader />
        <main className="site-main">{children}</main>
        <SiteFooter />
      </body>
    </html>
  );
}
