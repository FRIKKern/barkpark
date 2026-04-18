import { PortableText } from '@barkpark/react'
import { getDoc } from '../../lib/barkpark'

interface Page {
  _id: string
  title: string
  subtitle?: string
  body?: Parameters<typeof PortableText>[0]['value']
}

export default async function PricingPage() {
  const page = await getDoc<Page>('page', 'pricing')
  if (!page) {
    return <p className="text-slate-500">Pricing page not found. Run <code>pnpm seed</code>.</p>
  }
  return (
    <article className="prose max-w-none dark:prose-invert">
      <h1 className="text-4xl font-bold">{page.title}</h1>
      {page.subtitle ? <p className="text-lg text-slate-600 dark:text-slate-300">{page.subtitle}</p> : null}
      {page.body ? <PortableText value={page.body} /> : null}
    </article>
  )
}
