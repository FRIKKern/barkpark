import type { Metadata } from 'next'
import type { ReactNode } from 'react'
import Link from 'next/link'
import './globals.css'
import { HostedDemoBanner } from './hosted-demo-banner'

export const metadata: Metadata = {
  title: 'Barkpark starter',
  description: 'A Next.js 15 marketing site powered by Barkpark.',
}

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body className="min-h-screen">
        <HostedDemoBanner />
        <header className="border-b border-slate-200 dark:border-slate-800">
          <nav className="mx-auto flex max-w-5xl items-center justify-between px-6 py-4">
            <Link href="/" className="text-lg font-semibold">
              Barkpark
            </Link>
            <ul className="flex gap-6 text-sm">
              <li>
                <Link href="/about">About</Link>
              </li>
              <li>
                <Link href="/pricing">Pricing</Link>
              </li>
              <li>
                <Link href="/contact">Contact</Link>
              </li>
            </ul>
          </nav>
        </header>
        <main className="mx-auto max-w-5xl px-6 py-12">{children}</main>
        <footer className="border-t border-slate-200 py-8 text-center text-sm text-slate-500 dark:border-slate-800">
          Built with Barkpark &middot; Next.js 15
        </footer>
      </body>
    </html>
  )
}
