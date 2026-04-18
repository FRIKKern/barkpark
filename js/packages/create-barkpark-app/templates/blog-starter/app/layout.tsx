import type { Metadata } from 'next'
import type { ReactNode } from 'react'
import Link from 'next/link'
import './globals.css'

export const metadata: Metadata = {
  title: 'Barkpark blog starter',
  description: 'A Next.js 15 blog powered by Barkpark with draft-mode preview.',
}

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body className="min-h-screen">
        <header className="border-b border-slate-200 dark:border-slate-800">
          <nav className="mx-auto flex max-w-5xl items-center justify-between px-6 py-4">
            <Link href="/" className="text-lg font-semibold">
              Barkpark Blog
            </Link>
            <ul className="flex gap-6 text-sm">
              <li>
                <Link href="/">Posts</Link>
              </li>
              <li>
                <a href="http://localhost:4000/studio" target="_blank" rel="noreferrer">
                  Studio
                </a>
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
