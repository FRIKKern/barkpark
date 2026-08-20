import { resolveEnv, fetchFlagshipDoc } from '../lib/barkpark'

/**
 * Force per-request SSR. This is the LOAD-BEARING line of the container adapter:
 * with `force-dynamic` the deploy markers below are read from `process.env` at
 * REQUEST time, so they reflect the NODE-SLOT boot env the deploy engine injects
 * at `node server.js` launch (BUILD_ID / CONTENT_REV). A default static render
 * would bake the BUILD-time values, and the deploy engine's HTTP HEALTH probe
 * (which curls the running process for these markers) would read a stale build
 * id and fail the switch. It also makes the featured-doc fetch a request-time
 * SSR round trip, which is the whole point of the node-slot runtime target.
 */
export const dynamic = 'force-dynamic'

export default async function Page() {
  const env = resolveEnv()
  const { doc } = await fetchFlagshipDoc(env)

  const pageTitle = doc
    ? `${doc.title} · Barkpark Next.js starter`
    : 'Barkpark Next.js starter'

  return (
    <>
      {/*
        The five deploy markers. React 19 (Next 16) hoists these <meta> tags
        into <head> during SSR, where the deploy engine's HEALTH stage greps
        them out of the served HTML to assert content-truth before flipping the
        Caddy upstream to this slot:
          bp-build-id     — which build this node slot is serving (boot env)
          bp-content-rev  — the content revision it was cut against (boot env)
          bp-doc-id       — the featured document id      (content-truth, per request)
          bp-doc-title    — the featured document title    (content-truth, per request)
          bp-site-base    — the /sites/<slug>/ path Caddy serves this site under
      */}
      <meta name="bp-build-id" content={env.buildId} />
      <meta name="bp-content-rev" content={env.contentRev} />
      <meta name="bp-doc-id" content={doc?._id ?? ''} />
      <meta name="bp-doc-title" content={doc?.title ?? ''} />
      <meta name="bp-site-base" content={env.siteBase} />
      <title>{pageTitle}</title>

      <header>
        <p
          style={{
            margin: '0 0 .25rem',
            color: 'var(--muted)',
            fontSize: '.85rem',
            letterSpacing: '.04em',
            textTransform: 'uppercase',
          }}
        >
          Barkpark Cloud · Next.js
        </p>
        <h1 style={{ margin: '0 0 1.5rem', fontSize: '2rem', lineHeight: 1.2 }}>
          Content, served live next to Phoenix.
        </h1>
      </header>

      {doc ? (
        <article
          style={{
            border: '1px solid var(--border)',
            background: 'var(--card)',
            borderRadius: '12px',
            padding: '1.5rem',
          }}
        >
          <p style={{ margin: '0 0 .5rem', color: 'var(--muted)', fontSize: '.8rem' }}>
            Fetched at request time · newest <code>{env.docType}</code>
          </p>
          <h2 style={{ margin: '0 0 .5rem', fontSize: '1.35rem' }}>{doc.title}</h2>
          <p style={{ margin: 0, color: 'var(--muted)', fontSize: '.9rem' }}>
            <code>{doc._id}</code>
          </p>
        </article>
      ) : (
        <article
          style={{
            border: '1px dashed var(--border)',
            borderRadius: '12px',
            padding: '1.5rem',
            color: 'var(--muted)',
          }}
        >
          <h2 style={{ margin: '0 0 .5rem', fontSize: '1.15rem', color: 'var(--fg)' }}>
            No <code>{env.docType}</code> documents yet
          </h2>
          <p style={{ margin: 0 }}>
            The content link is live, but this dataset has no readable{' '}
            <code>{env.docType}</code> documents (missing or private schema, or an
            empty type). Publish one in Barkpark and reload — this page SSRs fresh
            content on every request.
          </p>
        </article>
      )}

      <footer style={{ marginTop: '2.5rem', color: 'var(--muted)', fontSize: '.8rem' }}>
        <p style={{ margin: 0 }} data-testid="build-line">
          build <code>{env.buildId}</code> · content rev <code>{env.contentRev}</code>
        </p>
      </footer>
    </>
  )
}
