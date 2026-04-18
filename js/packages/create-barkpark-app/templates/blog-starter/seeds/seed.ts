/**
 * Seed the local Barkpark API with sample blog content.
 *
 * Usage: `pnpm seed` (requires `docker compose up -d` to be running).
 */

const API = process.env.BARKPARK_API_URL ?? 'http://localhost:4000'
const DATASET = process.env.BARKPARK_DATASET ?? 'production'
const TOKEN = process.env.BARKPARK_TOKEN ?? 'barkpark-dev-token'

interface Mutation {
  create?: Record<string, unknown>
  createOrReplace?: Record<string, unknown>
  publish?: { id: string; type: string }
}

async function mutate(mutations: Mutation[]): Promise<void> {
  const res = await fetch(`${API}/v1/data/mutate/${DATASET}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${TOKEN}`,
    },
    body: JSON.stringify({ mutations }),
  })
  if (!res.ok) {
    const body = await res.text()
    throw new Error(`mutate failed: ${res.status} ${body}`)
  }
}

let blockCounter = 0
function block(text: string): Record<string, unknown> {
  blockCounter += 1
  return {
    _type: 'block',
    _key: `b${blockCounter}`,
    style: 'normal',
    children: [{ _type: 'span', _key: `s${blockCounter}`, text, marks: [] }],
  }
}

function ref(id: string): Record<string, unknown> {
  return { _type: 'reference', _ref: id }
}

async function main(): Promise<void> {
  console.log(`Seeding ${API} (dataset: ${DATASET})...`)

  // 2 authors
  await mutate([
    {
      createOrReplace: {
        _id: 'author-alice',
        _type: 'author',
        name: 'Alice Chen',
        slug: { current: 'alice-chen' },
        bio: 'Writes about TypeScript, React, and backend systems.',
      },
    },
    {
      createOrReplace: {
        _id: 'author-bob',
        _type: 'author',
        name: 'Bob Sato',
        slug: { current: 'bob-sato' },
        bio: 'Headless CMS enthusiast and PostgreSQL sympathizer.',
      },
    },
  ])

  // 3 tags
  await mutate([
    {
      createOrReplace: {
        _id: 'tag-typescript',
        _type: 'tag',
        title: 'TypeScript',
        slug: { current: 'typescript' },
        description: 'Type-safe JavaScript at scale.',
      },
    },
    {
      createOrReplace: {
        _id: 'tag-nextjs',
        _type: 'tag',
        title: 'Next.js',
        slug: { current: 'nextjs' },
        description: 'App Router, RSC, and the modern React framework.',
      },
    },
    {
      createOrReplace: {
        _id: 'tag-barkpark',
        _type: 'tag',
        title: 'Barkpark',
        slug: { current: 'barkpark' },
        description: 'Headless CMS with Phoenix API and Studio UI.',
      },
    },
  ])

  // 6 published posts + 1 draft
  const now = () => new Date().toISOString()

  await mutate([
    {
      createOrReplace: {
        _id: 'post-welcome',
        _type: 'post',
        title: 'Welcome to the Barkpark blog',
        slug: { current: 'welcome' },
        excerpt: 'First post on the starter blog.',
        publishedAt: now(),
        author: ref('author-alice'),
        tags: [ref('tag-barkpark')],
        content: [block('Hello world. This post was seeded via the mutate API.')],
      },
    },
    {
      createOrReplace: {
        _id: 'post-rsc-and-cms',
        _type: 'post',
        title: 'RSC + headless CMS',
        slug: { current: 'rsc-and-headless-cms' },
        excerpt: 'Why React Server Components pair well with Barkpark.',
        publishedAt: now(),
        author: ref('author-bob'),
        tags: [ref('tag-nextjs'), ref('tag-barkpark')],
        content: [
          block('RSC lets you fetch from Barkpark on the server, keeping the client bundle tiny.'),
          block('Cache tags fan out via revalidateTag when you mutate.'),
        ],
      },
    },
    {
      createOrReplace: {
        _id: 'post-typing-queries',
        _type: 'post',
        title: 'Typing your Barkpark queries',
        slug: { current: 'typing-your-queries' },
        excerpt: 'Codegen + zod schemas for end-to-end type safety.',
        publishedAt: now(),
        author: ref('author-alice'),
        tags: [ref('tag-typescript'), ref('tag-barkpark')],
        content: [block('Run `barkpark codegen` to emit zod schemas and typed fetchers.')],
      },
    },
    {
      createOrReplace: {
        _id: 'post-server-actions',
        _type: 'post',
        title: 'Server Actions with defineActions',
        slug: { current: 'server-actions-with-defineactions' },
        excerpt: 'A typed wrapper around createDoc, patchDoc, publish.',
        publishedAt: now(),
        author: ref('author-bob'),
        tags: [ref('tag-nextjs'), ref('tag-typescript')],
        content: [block('defineActions returns a set of safe server-side mutations for your schemas.')],
      },
    },
    {
      createOrReplace: {
        _id: 'post-draft-preview',
        _type: 'post',
        title: 'Draft-mode preview with useOptimisticDocument',
        slug: { current: 'draft-mode-preview' },
        excerpt: 'Wire Next.js draft mode to the drafts perspective.',
        publishedAt: now(),
        author: ref('author-alice'),
        tags: [ref('tag-nextjs'), ref('tag-barkpark')],
        content: [
          block('Visit /api/preview to flip draftMode().enable(). The page re-fetches with perspective=drafts.'),
          block('useOptimisticDocument shows edits immediately while a server action commits them.'),
        ],
      },
    },
    {
      createOrReplace: {
        _id: 'post-deploy',
        _type: 'post',
        title: 'Deploying Barkpark + Next.js',
        slug: { current: 'deploying-barkpark-and-nextjs' },
        excerpt: 'docker-compose up -d, point the Next app at the API, ship.',
        publishedAt: now(),
        author: ref('author-bob'),
        tags: [ref('tag-barkpark')],
        content: [block('Run Phoenix behind Caddy or Traefik, point BARKPARK_API_URL at it.')],
      },
    },
    {
      // Deliberately left as draft (no publish mutation below) — open in draft preview.
      createOrReplace: {
        _id: 'post-upcoming',
        _type: 'post',
        title: 'Upcoming: richer Portable Text renderers',
        slug: { current: 'upcoming-portable-text' },
        excerpt: 'Custom marks, embed blocks, and inline author cards.',
        publishedAt: now(),
        author: ref('author-alice'),
        tags: [ref('tag-nextjs')],
        content: [block('This post is still a draft. Enter /api/preview to see it.')],
      },
    },
  ])

  // Publish everything except the draft post.
  await mutate([
    { publish: { id: 'author-alice', type: 'author' } },
    { publish: { id: 'author-bob', type: 'author' } },
    { publish: { id: 'tag-typescript', type: 'tag' } },
    { publish: { id: 'tag-nextjs', type: 'tag' } },
    { publish: { id: 'tag-barkpark', type: 'tag' } },
    { publish: { id: 'post-welcome', type: 'post' } },
    { publish: { id: 'post-rsc-and-cms', type: 'post' } },
    { publish: { id: 'post-typing-queries', type: 'post' } },
    { publish: { id: 'post-server-actions', type: 'post' } },
    { publish: { id: 'post-draft-preview', type: 'post' } },
    { publish: { id: 'post-deploy', type: 'post' } },
  ])

  console.log('Seeded 2 authors, 3 tags, 7 posts (6 published, 1 draft).')
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
