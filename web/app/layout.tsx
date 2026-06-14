import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import { SpeedInsights } from "@vercel/speed-insights/next";
import "./globals.css";
import { LiveBridge } from "@/components/live-bridge";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
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
        <LiveBridge />
        {/* Real-user Core Web Vitals (LCP/CLS/INP/TTFB) → Vercel Speed Insights.
            Lab data was all-green; this surfaces what real devices actually see. */}
        <SpeedInsights />
      </body>
    </html>
  );
}
