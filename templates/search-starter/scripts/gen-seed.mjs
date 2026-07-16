#!/usr/bin/env node
// gen-seed.mjs — author the search-starter seed corpus.
//
// Emits templates/search-starter/seed.json: a single-type (`entry`) mutations
// payload the bootstrap chain (internal/bootstrap/bootstrap.go) can consume
// directly — createOrReplace per doc, then an explicit publish pass driven by
// the manifest's seed.publish/publishType. ONE type per seed is a HARD
// constraint (bootstrap publishes exactly one type and rolls the whole batch
// back on a type mismatch), so every mutation here is `_type: "entry"`.
//
// The corpus is a densely cross-linked constellation so /v1/graph renders a
// real force graph at minute one: every `entry` carries a scalar `related`
// reference AND an `links` arrayOf-of-reference, both edge-extracted by
// api/lib/barkpark/content/edges.ex. All reference values are BARE sibling
// doc ids present in this same file — a dangling ref would surface as a
// phantom node, so seed-lint.mjs fails the build on one.
//
// This generator is the authoring convenience; seed.json is the committed
// source of truth and seed-lint.mjs validates it independently. Run:
//   node templates/search-starter/scripts/gen-seed.mjs
import { writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const SEED_PATH = resolve(HERE, '..', 'seed.json')

// ── PortableDocument block helpers (Barkpark's type-keyed block grammar) ──
// Shapes mirror what @barkpark/react's PortableDoc renderer and the Phoenix
// /papers reader consume (heading/paragraph/list/callout/code/… at style=article).
let _seq = 0
const bid = (t) => `${t}-${(++_seq).toString(36)}`
const eyebrow = (text) => ({ id: bid('eb'), type: 'eyebrow', text })
const h = (level, text) => ({ id: bid('h'), type: 'heading', level, text })
const ingress = (text) => ({ id: bid('in'), type: 'ingress', text })
const p = (text) => ({ id: bid('p'), type: 'paragraph', content: [{ type: 'text', value: text }] })
const prich = (nodes) => ({ id: bid('p'), type: 'paragraph', content: nodes })
const t = (value) => ({ type: 'text', value })
const strong = (value) => ({ type: 'strong', children: [{ type: 'text', value }] })
const em = (value) => ({ type: 'em', children: [{ type: 'text', value }] })
const link = (href, value) => ({ type: 'link', href, children: [{ type: 'text', value }] })
const list = (ordered, items) => ({ id: bid('ls'), type: 'list', ordered, items })
const callout = (tone, title, text) => ({ id: bid('co'), type: 'callout', tone, title, content: [{ type: 'text', value: text }] })
const pull = (text) => ({ id: bid('pq'), type: 'pullquote', content: [{ type: 'text', value: text }] })
const code = (value) => ({ id: bid('cd'), type: 'code', value })
const divider = () => ({ id: bid('dv'), type: 'divider' })
const table = (head, rows) => ({ id: bid('tb'), type: 'table', head, rows })

// ── The corpus ────────────────────────────────────────────────────────────
// Each entry: { id, title, kind, summary, related, links, body }.
// `related` = one scalar sibling id; `links` = an array of sibling ids.
// Hubs (barkpark / portabledoc / search / graph / premium) are referenced by
// many nodes so the graph shows a few high-degree stars among the field.
const entries = [
  {
    id: 'entry-barkpark',
    title: 'Barkpark',
    kind: 'concept',
    summary: 'A headless CMS with one content model and many surfaces — the root of this field guide.',
    related: 'entry-headless-cms',
    links: ['entry-portabledoc', 'entry-search', 'entry-schema', 'entry-graph'],
    body: [
      eyebrow('Field guide'),
      h(1, 'Barkpark'),
      ingress('One content model, many surfaces. Author once; render everywhere — a Next.js site, an Astro site, a Go TUI, and the /papers reader all read the same documents.'),
      p('Barkpark is a headless CMS. Content lives as typed documents; every surface is a projection of the same graph. This starter seeds that graph so your search page has something worth searching on the first load.'),
      callout('info', 'Start here', 'Every node in the graph you are looking at is an entry document. Follow the links and you are walking the reference edges Barkpark extracts from your schema.'),
      h(2, 'How the pieces fit'),
      list(false, ['Documents are typed by a schema.', 'Reference fields become graph edges.', 'PortableDocument bodies render identically across surfaces.']),
      pull('The fastest way to ship something premium is to start from a graph, not a blank page.'),
    ],
  },
  {
    id: 'entry-headless-cms',
    title: 'Headless CMS',
    kind: 'concept',
    summary: 'A content backend with no baked-in front end — you own the rendering.',
    related: 'entry-barkpark',
    links: ['entry-schema', 'entry-api', 'entry-static-generation'],
    body: [
      h(1, 'Headless CMS'),
      p('A headless CMS stores structured content and serves it over an API. There is no theme layer — you decide how it renders, on whatever framework you like.'),
      table(['Coupled CMS', 'Headless CMS'], [
        ['One templating engine', 'Any framework'],
        ['Content and view entangled', 'Content is portable'],
        ['Hard to reuse content', 'One model, many surfaces'],
      ]),
      p('Barkpark leans all the way into the model: the same document renders in Next, Astro, and a terminal.'),
    ],
  },
  {
    id: 'entry-portabledoc',
    title: 'PortableDoc',
    kind: 'feature',
    summary: 'Barkpark’s type-keyed block document format — render-identical across every surface.',
    related: 'entry-barkpark',
    links: ['entry-blocks', 'entry-render-parity', 'entry-react-renderer', 'entry-astro'],
    body: [
      eyebrow('Feature'),
      h(1, 'PortableDoc'),
      ingress('A PortableDocument is an ordered array of type-keyed blocks. One grammar, one renderer per surface, byte-identical output.'),
      p('Instead of storing HTML or Markdown, a PortableDoc stores intent: a heading is a heading, a callout is a callout. Each surface owns the rendering, so the same body looks native on Next, Astro, and the Phoenix reader.'),
      h(2, 'A block is just data'),
      code('{ "type": "callout", "tone": "success", "title": "Nice", "content": [{ "type": "text", "value": "Rendered everywhere the same way." }] }'),
      callout('success', 'Render parity', 'The React, Astro, Elixir, and Go renderers all emit the same bp-* class vocabulary, so one stylesheet skins them all.'),
      list(true, ['Author a block once.', 'Store it as data.', 'Render it faithfully on any surface.']),
      prich([t('The renderer degrades unknown blocks to a visible placeholder rather than throwing — see '), link('#', 'render parity'), t(' for the contract.')]),
    ],
  },
  {
    id: 'entry-blocks',
    title: 'Blocks',
    kind: 'concept',
    summary: 'The type-keyed units a PortableDocument is built from: heading, paragraph, callout, code, and more.',
    related: 'entry-portabledoc',
    links: ['entry-render-parity', 'entry-schema'],
    body: [
      h(1, 'Blocks'),
      p('A block is a small map with a "type" key and the fields that type needs. The renderer routes each block to its emitter.'),
      list(false, ['heading — a title at level 1, 2, or 3', 'paragraph — inline prose', 'callout — a toned aside', 'code — a monospace slab', 'list — ordered or unordered', 'table — rows and an optional header band']),
      p('New block types are additive: an older renderer degrades an unknown block instead of breaking the page.'),
    ],
  },
  {
    id: 'entry-render-parity',
    title: 'Render parity',
    kind: 'pattern',
    summary: 'The same block array produces the same HTML on every surface — the parity contract.',
    related: 'entry-portabledoc',
    links: ['entry-react-renderer', 'entry-astro', 'entry-blocks'],
    body: [
      h(1, 'Render parity'),
      ingress('One stylesheet, many surfaces. Every renderer emits the same bp-* classes.'),
      p('Parity is enforced by a cross-surface harness that compares each renderer against a golden output. If Astro drifts from Elixir, the harness fails.'),
      callout('warning', 'Why it matters', 'Without parity, your premium design only looks right on one framework. With it, the same paper-surface.css skins them all.'),
    ],
  },
  {
    id: 'entry-react-renderer',
    title: 'React renderer',
    kind: 'feature',
    summary: 'The @barkpark/react PortableDoc component — a context-free, RSC-safe block renderer.',
    related: 'entry-render-parity',
    links: ['entry-portabledoc', 'entry-nextjs'],
    body: [
      h(1, 'React renderer'),
      p('@barkpark/react ships a PortableDoc component that takes a block array and returns Phoenix-faithful HTML. No hooks, no context — it drops straight into a Server Component.'),
      code('import { PortableDoc } from "@barkpark/react"\n\n<PortableDoc value={entry.body} />'),
    ],
  },
  {
    id: 'entry-astro',
    title: 'Astro renderer',
    kind: 'framework',
    summary: 'Render PortableDocuments in Astro with a framework-free string emitter.',
    related: 'entry-render-parity',
    links: ['entry-portabledoc', 'entry-static-generation'],
    body: [
      eyebrow('Framework'),
      h(1, 'Astro renderer'),
      p('Astro consumes the same PortableDocument grammar. The renderPortableDocument helper returns a plain HTML string, so an Astro component drops it in with set:html.'),
      code('---\nimport { renderPortableDocument } from "@barkpark/react"\nconst html = renderPortableDocument(entry.body)\n---\n<article class="bp-paper-surface" set:html={html} />'),
      callout('info', 'Same stylesheet', 'Ship paper-surface.css and the Astro output looks identical to the Next and Phoenix output.'),
    ],
  },
  {
    id: 'entry-nextjs',
    title: 'Next.js',
    kind: 'framework',
    summary: 'The default deployable surface — App Router, Server Components, ISR.',
    related: 'entry-react-renderer',
    links: ['entry-static-generation', 'entry-webhooks', 'entry-barkpark'],
    body: [
      h(1, 'Next.js'),
      p('The starter deploys as a Next.js app. Server Components fetch published documents at build time; a webhook revalidates the cache when content changes.'),
      list(true, ['Fetch published entries server-side.', 'Render bodies with PortableDoc.', 'Revalidate on the content webhook.']),
    ],
  },
  {
    id: 'entry-static-generation',
    title: 'Static generation',
    kind: 'pattern',
    summary: 'Pre-render pages at build time for instant loads and cheap hosting.',
    related: 'entry-nextjs',
    links: ['entry-edge-cache', 'entry-webhooks', 'entry-premium'],
    body: [
      h(1, 'Static generation'),
      ingress('Do the work once, at build time. Serve HTML that was ready before the request arrived.'),
      p('Static pages are the fastest thing you can serve and the cheapest to host. Combined with a content webhook, they stay fresh without going dynamic.'),
      callout('success', 'Fast by default', 'A pre-rendered page needs no database round-trip at request time — it is already HTML on a CDN.'),
    ],
  },
  {
    id: 'entry-edge-cache',
    title: 'Edge cache',
    kind: 'pattern',
    summary: 'Serve pre-rendered content from the network edge, close to every visitor.',
    related: 'entry-static-generation',
    links: ['entry-webhooks', 'entry-premium'],
    body: [
      h(1, 'Edge cache'),
      p('An edge cache puts your rendered pages in dozens of locations worldwide. The first byte arrives from a server near the visitor, not from a single origin.'),
      table(['Origin only', 'Edge cache'], [['One location', 'Everywhere'], ['Cold on every miss', 'Warm near the user']]),
    ],
  },
  {
    id: 'entry-webhooks',
    title: 'Webhooks',
    kind: 'feature',
    summary: 'Signed cache-revalidation callbacks fired when content changes.',
    related: 'entry-static-generation',
    links: ['entry-nextjs', 'entry-api'],
    body: [
      h(1, 'Webhooks'),
      p('When a document is published, Barkpark POSTs a signed webhook to your site. The site verifies the HMAC signature and revalidates only what changed.'),
      callout('warning', 'Verify the signature', 'The webhook carries a shared secret minted at bootstrap. Reject any payload whose signature does not match.'),
    ],
  },
  {
    id: 'entry-search',
    title: 'Search',
    kind: 'feature',
    summary: 'Full-text search over your documents — the beating heart of this template.',
    related: 'entry-barkpark',
    links: ['entry-graph', 'entry-facets', 'entry-relevance', 'entry-fts'],
    body: [
      eyebrow('Feature'),
      h(1, 'Search'),
      ingress('Type a word; get ranked documents. This starter puts search — and the graph behind it — front and centre.'),
      p('Search is what makes a content site feel alive. Barkpark indexes your documents so a query returns ranked matches instantly, with facets to narrow and a graph to explore.'),
      h(2, 'What powers it'),
      list(false, ['Postgres full-text search for ranking.', 'Facets from your schema fields.', 'A force graph from your reference edges.']),
      callout('info', 'The graph is the demo', 'Search results are useful; the constellation of linked results is what makes visitors say "how did you build this so fast?"'),
    ],
  },
  {
    id: 'entry-graph',
    title: 'Force graph',
    kind: 'feature',
    summary: 'A physics-driven map of your documents and the references between them.',
    related: 'entry-search',
    links: ['entry-references', 'entry-edges', 'entry-graph-endpoint', 'entry-portabledoc'],
    body: [
      eyebrow('Feature'),
      h(1, 'Force graph'),
      ingress('Nodes are documents; edges are references. A physics simulation lays them out so structure becomes visible.'),
      p('The force graph reads /v1/graph and draws every document as a node and every reference as an edge. Hubs float to the centre; leaves drift to the rim. It is the single most striking thing on the page — and it comes for free the moment your content has references.'),
      callout('success', 'Zero extra work', 'You do not build the graph. You author references in your schema and the graph draws itself.'),
      pull('Give people a map and they explore. Give them a list and they bounce.'),
    ],
  },
  {
    id: 'entry-references',
    title: 'Reference fields',
    kind: 'concept',
    summary: 'Schema fields that point at other documents — scalar and arrayOf.',
    related: 'entry-graph',
    links: ['entry-schema', 'entry-edges', 'entry-arrayof'],
    body: [
      h(1, 'Reference fields'),
      p('A reference field holds the id of another document. Barkpark supports a scalar reference (one target) and an arrayOf-of-reference (many targets). Both become edges in the graph.'),
      code('{ "name": "related", "type": "reference", "refType": "entry" }\n{ "name": "links", "type": "arrayOf", "of": { "type": "reference", "refType": "entry" } }'),
      callout('info', 'Both are edges', 'The edge extractor walks scalar and array reference fields alike — the kind of the edge is the field name.'),
    ],
  },
  {
    id: 'entry-arrayof',
    title: 'arrayOf reference',
    kind: 'concept',
    summary: 'A field holding many references — every element becomes its own edge.',
    related: 'entry-references',
    links: ['entry-edges', 'entry-schema'],
    body: [
      h(1, 'arrayOf reference'),
      p('An arrayOf-of-reference field stores a list of document ids. The edge extractor emits one edge per non-empty element, so a single field can wire a node to a dozen others.'),
      list(true, ['Store bare sibling ids in the array.', 'Each element is one outbound edge.', 'A missing target would render as a phantom node.']),
    ],
  },
  {
    id: 'entry-edges',
    title: 'Edges',
    kind: 'concept',
    summary: 'The directed links the graph draws, extracted from your reference fields.',
    related: 'entry-references',
    links: ['entry-graph', 'entry-graph-endpoint'],
    body: [
      h(1, 'Edges'),
      p('An edge is a directed link from one document to another. Barkpark extracts edges at read time from every reference field; the edge kind is the field name, so distinct fields colour distinctly in the graph.'),
      callout('warning', 'Dangling edges', 'If a reference points at an id that does not exist, the graph shows a phantom node. This starter’s seed-lint refuses to ship a dangling reference.'),
    ],
  },
  {
    id: 'entry-graph-endpoint',
    title: '/v1/graph',
    kind: 'feature',
    summary: 'The endpoint the force graph reads — nodes and edges for the Default workspace.',
    related: 'entry-edges',
    links: ['entry-api', 'entry-graph'],
    body: [
      h(1, '/v1/graph'),
      p('The flat /v1/graph endpoint returns the nodes and edges of the Default workspace. The force graph fetches it once and simulates from there.'),
      code('GET /v1/graph  →  { nodes: [...], edges: [...] }'),
    ],
  },
  {
    id: 'entry-facets',
    title: 'Facets',
    kind: 'pattern',
    summary: 'Narrow search results by schema fields like kind or tag.',
    related: 'entry-search',
    links: ['entry-relevance', 'entry-schema'],
    body: [
      h(1, 'Facets'),
      p('Facets turn a schema field into a filter. Group entries by kind, click a value, and the result set narrows without a new query.'),
      list(false, ['concept', 'feature', 'pattern', 'framework', 'guide']),
    ],
  },
  {
    id: 'entry-relevance',
    title: 'Relevance ranking',
    kind: 'pattern',
    summary: 'Order search results by how well they match — not just whether they match.',
    related: 'entry-search',
    links: ['entry-fts', 'entry-facets'],
    body: [
      h(1, 'Relevance ranking'),
      p('A good search ranks a title match above a body match and a phrase match above a scattered one. Barkpark leans on Postgres full-text ranking so the best answer floats to the top.'),
    ],
  },
  {
    id: 'entry-fts',
    title: 'Full-text search',
    kind: 'feature',
    summary: 'Postgres FTS over your documents — fast, ranked, and built in.',
    related: 'entry-relevance',
    links: ['entry-search', 'entry-api'],
    body: [
      h(1, 'Full-text search'),
      p('Barkpark indexes your document text with Postgres full-text search. Queries return ranked matches in milliseconds, with no external search service to run.'),
      callout('success', 'No extra infrastructure', 'The search index lives in the same database as your content — one fewer moving part to operate.'),
    ],
  },
  {
    id: 'entry-schema',
    title: 'Schema',
    kind: 'concept',
    summary: 'The typed shape of a document — fields, references, and surfaces.',
    related: 'entry-barkpark',
    links: ['entry-references', 'entry-fields', 'entry-visibility'],
    body: [
      h(1, 'Schema'),
      ingress('A schema declares what a document is: its fields, their types, and where they live.'),
      p('The entry schema in this starter declares a title, a PortableDocument body, a summary, a kind, a scalar reference, and an arrayOf reference. That is all the graph needs to come alive.'),
      table(['Field', 'Type'], [['title', 'string'], ['body', 'portableDocument'], ['related', 'reference'], ['links', 'arrayOf reference']]),
    ],
  },
  {
    id: 'entry-fields',
    title: 'Fields',
    kind: 'concept',
    summary: 'The named, typed slots of a schema.',
    related: 'entry-schema',
    links: ['entry-references', 'entry-visibility'],
    body: [
      h(1, 'Fields'),
      p('A field has a name, a type, and an optional surface that tells Studio whether it belongs in the article body or the sidebar rail.'),
      list(false, ['body — reads as part of the article', 'sidebar — slugs, taxonomies, relations, dates']),
    ],
  },
  {
    id: 'entry-visibility',
    title: 'Visibility',
    kind: 'concept',
    summary: 'Public documents answer anonymous reads; private ones need a token.',
    related: 'entry-schema',
    links: ['entry-api', 'entry-tokens'],
    body: [
      h(1, 'Visibility'),
      p('A public schema answers anonymous reads; a private one returns 404 unless the caller carries a token. The entry type here is public, so your search page can read it without a secret.'),
    ],
  },
  {
    id: 'entry-api',
    title: 'HTTP API',
    kind: 'feature',
    summary: 'The scoped REST surface your site reads content from.',
    related: 'entry-barkpark',
    links: ['entry-tokens', 'entry-graph-endpoint', 'entry-sdk'],
    body: [
      h(1, 'HTTP API'),
      p('Every surface reads the same HTTP API. Queries, the graph, media, and webhooks are all plain scoped REST calls.'),
      code('GET /w/<ws>/p/default/v1/data/query/production/entry'),
    ],
  },
  {
    id: 'entry-tokens',
    title: 'Tokens',
    kind: 'concept',
    summary: 'Scoped bearer credentials — read-only public-read for the site.',
    related: 'entry-api',
    links: ['entry-visibility', 'entry-sdk'],
    body: [
      h(1, 'Tokens'),
      p('The bootstrap mints a workspace-bound public-read token for your site. It is read-only and scoped, so shipping it server-side is safe.'),
      callout('warning', 'Server-only', 'Keep the read token on the server. It never needs to reach the browser.'),
    ],
  },
  {
    id: 'entry-sdk',
    title: 'JS SDK',
    kind: 'feature',
    summary: 'Typed client for reading Barkpark content from JavaScript.',
    related: 'entry-api',
    links: ['entry-react-renderer', 'entry-nextjs'],
    body: [
      h(1, 'JS SDK'),
      p('The JS SDK wraps the HTTP API in a typed client. Fetch documents, follow references, and hand bodies straight to the PortableDoc renderer.'),
    ],
  },
  {
    id: 'entry-studio',
    title: 'Studio',
    kind: 'feature',
    summary: 'The LiveView editing surface — where authors shape content.',
    related: 'entry-barkpark',
    links: ['entry-schema', 'entry-portabledoc', 'entry-tui'],
    body: [
      h(1, 'Studio'),
      p('Studio is the browser editing surface. Authors edit documents against the schema, arrange PortableDocument blocks, and publish — the site updates live.'),
    ],
  },
  {
    id: 'entry-tui',
    title: 'Go TUI',
    kind: 'feature',
    summary: 'A terminal surface that renders the same documents and papers.',
    related: 'entry-studio',
    links: ['entry-portabledoc', 'entry-barkpark'],
    body: [
      h(1, 'Go TUI'),
      p('The Go TUI renders the same PortableDocuments in a terminal. Proof that the content model is truly surface-independent — a paper looks right even in a shell.'),
    ],
  },
  {
    id: 'entry-premium',
    title: 'Premium by default',
    kind: 'guide',
    summary: 'Why this stack ships high-quality sites fast, without worries.',
    related: 'entry-barkpark',
    links: ['entry-static-generation', 'entry-render-parity', 'entry-search', 'entry-deploy'],
    body: [
      eyebrow('Guide'),
      h(1, 'Premium by default'),
      ingress('High quality is not a phase you add at the end. It is what falls out of the right defaults.'),
      p('This template hands you a fast, searchable, beautifully-typeset site on the first deploy. Static generation makes it quick; render parity makes it consistent; the graph makes it memorable.'),
      list(true, ['Deploy the template.', 'The seed fills the graph.', 'Search and the constellation work immediately.']),
      callout('success', 'No worries', 'You do not tune a search cluster or hand-build a graph. You author content and the premium experience is already there.'),
      pull('The fastest way to look expensive is to start from a template that already is.'),
    ],
  },
  {
    id: 'entry-deploy',
    title: 'Deploy',
    kind: 'guide',
    summary: 'One button from the dashboard to a live, seeded, searchable site.',
    related: 'entry-premium',
    links: ['entry-nextjs', 'entry-webhooks', 'entry-barkpark'],
    body: [
      h(1, 'Deploy'),
      ingress('Pick the template in the dashboard, click deploy, and land on a working site — not an empty box.'),
      p('The deploy flow creates a workspace, installs the entry schema, seeds this corpus, publishes it, mints a read token, and wires a revalidation webhook. By the time the site is live, the graph is already glowing.'),
      callout('info', 'Available in the dashboard', 'This template shows up when you create a site — no ad-hoc install script to run.'),
      divider(),
      p('That is the whole point: the fastest way to set up something genuinely high quality, without worries.'),
    ],
  },
  {
    id: 'entry-content-model',
    title: 'Content model',
    kind: 'concept',
    summary: 'The single shape all your surfaces agree on.',
    related: 'entry-schema',
    links: ['entry-barkpark', 'entry-portabledoc'],
    body: [
      h(1, 'Content model'),
      p('The content model is the contract between authors and surfaces. Define it once and every renderer honours it — that is what "one model, many surfaces" means in practice.'),
    ],
  },
  {
    id: 'entry-publishing',
    title: 'Publishing',
    kind: 'concept',
    summary: 'Drafts become public when you publish — the graph reads published only.',
    related: 'entry-studio',
    links: ['entry-visibility', 'entry-webhooks'],
    body: [
      h(1, 'Publishing'),
      p('Edits land as drafts. Publishing promotes a draft to the public record. Anonymous reads — and the force graph — see only published documents, so work-in-progress never leaks.'),
      callout('info', 'Graph reads published', 'Only published entries appear in /v1/graph, so the constellation always reflects what your visitors can actually see.'),
    ],
  },
  {
    id: 'entry-media',
    title: 'Media',
    kind: 'feature',
    summary: 'Images and assets that ride alongside your documents.',
    related: 'entry-barkpark',
    links: ['entry-portabledoc', 'entry-studio'],
    body: [
      h(1, 'Media'),
      p('Media assets live in their own library and drop into PortableDocument bodies as image blocks. The renderer skips an asset-less image on read, so scaffolding never leaks to visitors.'),
    ],
  },
  {
    id: 'entry-workspace',
    title: 'Workspace',
    kind: 'concept',
    summary: 'The tenant boundary — this starter seeds into Default.',
    related: 'entry-barkpark',
    links: ['entry-api', 'entry-graph-endpoint'],
    body: [
      h(1, 'Workspace'),
      p('A workspace is a tenant boundary around a set of documents. The flat /v1/graph reads the Default workspace, which is exactly where this starter seeds — so the graph lights up with no extra scoping.'),
    ],
  },
  {
    id: 'entry-quality',
    title: 'Quality bar',
    kind: 'guide',
    summary: 'Honest states, safe actions, immediate feedback — the craft baseline.',
    related: 'entry-premium',
    links: ['entry-render-parity', 'entry-static-generation'],
    body: [
      eyebrow('Guide'),
      h(1, 'Quality bar'),
      p('Premium is loading states that are honest, empty states that guide, and actions that feel instant. This template holds that bar so you start above it, not below.'),
      list(false, ['Honest loading, empty, and error states.', 'Safe, reversible actions.', 'Immediate visual feedback.']),
    ],
  },
]

// ── Emit ────────────────────────────────────────────────────────────────────
const mutations = entries.map((e) => ({
  createOrReplace: {
    _id: e.id,
    _type: 'entry',
    title: e.title,
    status: 'published',
    slug: e.id.replace(/^entry-/, ''),
    kind: e.kind,
    summary: e.summary,
    related: e.related,
    links: e.links,
    body: e.body,
  },
}))

const out = JSON.stringify({ mutations }, null, 2) + '\n'
writeFileSync(SEED_PATH, out)
console.log(`wrote ${entries.length} entries → ${SEED_PATH}`)
