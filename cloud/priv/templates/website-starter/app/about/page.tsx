import type { Metadata } from 'next'
import type { Block } from '@barkpark/react'
import { barkparkMetadata } from '@barkpark/nextjs'
// The canonical PortableDoc skin — ONE stylesheet for the `bp-*` classes the
// renderer emits (the same one Phoenix's `/papers` reader compiles in).
import '@barkpark/react/paper-surface.css'
import { getDoc } from '../../lib/barkpark'
import { PortableDocSurface } from '../portable-doc-surface'

interface Page {
  _id: string
  title: string
  subtitle?: string
  // The canonical, type-keyed PortableDocument block array (Barkpark's own
  // block grammar) — rendered by `@barkpark/react`'s PortableDoc, NOT Sanity
  // PortableText.
  body?: Block[]
}

export async function generateMetadata(): Promise<Metadata> {
  const page = await getDoc<Page>('page', 'about')
  if (!page) return {}
  return barkparkMetadata(page, { description: page.subtitle?.trim() || undefined })
}

export default async function AboutPage() {
  const page = await getDoc<Page>('page', 'about')
  if (!page) {
    return <p className="text-slate-500">About page not found. Run <code>pnpm seed</code>.</p>
  }
  return (
    <article>
      <h1 className="text-4xl font-bold">{page.title}</h1>
      {page.subtitle ? <p className="text-lg text-slate-600 dark:text-slate-300">{page.subtitle}</p> : null}
      {page.body ? <PortableDocSurface blocks={page.body} /> : null}
    </article>
  )
}
