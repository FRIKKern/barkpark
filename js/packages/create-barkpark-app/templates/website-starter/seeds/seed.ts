/**
 * Seed the local Barkpark API with sample content.
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

function portableTextParagraph(text: string): Record<string, unknown> {
  return {
    _type: 'block',
    _key: Math.random().toString(36).slice(2, 10),
    style: 'normal',
    children: [{ _type: 'span', _key: 'c1', text, marks: [] }],
  }
}

async function main(): Promise<void> {
  console.log(`Seeding ${API} (dataset: ${DATASET})...`)

  await mutate([
    {
      createOrReplace: {
        _id: 'author-ada',
        _type: 'author',
        name: 'Ada Lovelace',
        slug: { current: 'ada-lovelace' },
        bio: 'Pioneer of computing and enthusiastic dog-park visitor.',
      },
    },
    {
      createOrReplace: {
        _id: 'author-grace',
        _type: 'author',
        name: 'Grace Hopper',
        slug: { current: 'grace-hopper' },
        bio: 'Compiler inventor with a weakness for golden retrievers.',
      },
    },
  ])

  await mutate([
    {
      createOrReplace: {
        _id: 'page-home',
        _type: 'page',
        title: 'Welcome to Barkpark',
        slug: { current: 'home' },
        subtitle: 'A headless CMS that fits in your backpack.',
        body: [
          portableTextParagraph(
            'Barkpark gives you a real-time content backend with a Studio UI, built on Phoenix and PostgreSQL.',
          ),
        ],
      },
    },
    {
      createOrReplace: {
        _id: 'page-about',
        _type: 'page',
        title: 'About',
        slug: { current: 'about' },
        subtitle: 'Why we built Barkpark.',
        body: [
          portableTextParagraph(
            'We missed the ergonomics of Sanity but wanted an open-source, self-hostable alternative.',
          ),
        ],
      },
    },
    {
      createOrReplace: {
        _id: 'page-pricing',
        _type: 'page',
        title: 'Pricing',
        slug: { current: 'pricing' },
        subtitle: 'Free forever on your own infrastructure.',
        body: [
          portableTextParagraph(
            'Self-host Barkpark for free. Hosted plans coming soon with SLAs and automated backups.',
          ),
        ],
      },
    },
  ])

  await mutate([
    {
      createOrReplace: {
        _id: 'post-welcome',
        _type: 'post',
        title: 'Welcome to the blog',
        slug: { current: 'welcome' },
        excerpt: 'First post on a shiny new Barkpark site.',
        publishedAt: new Date().toISOString(),
        author: { _ref: 'author-ada', _type: 'reference' },
        tags: ['meta', 'launch'],
        content: [
          portableTextParagraph('Hello world. This post was seeded via the mutate API.'),
        ],
      },
    },
    {
      createOrReplace: {
        _id: 'post-rsc',
        _type: 'post',
        title: 'RSC and headless CMS',
        slug: { current: 'rsc-and-headless-cms' },
        excerpt: 'Server Components + Barkpark = happy cache.',
        publishedAt: new Date().toISOString(),
        author: { _ref: 'author-grace', _type: 'reference' },
        tags: ['nextjs', 'architecture'],
        content: [
          portableTextParagraph(
            'React Server Components let you fetch from Barkpark without shipping the client to the browser.',
          ),
        ],
      },
    },
    {
      createOrReplace: {
        _id: 'post-ga',
        _type: 'post',
        title: 'Going to GA',
        slug: { current: 'going-to-ga' },
        excerpt: 'What changes when Barkpark hits 1.0.',
        publishedAt: new Date().toISOString(),
        author: { _ref: 'author-ada', _type: 'reference' },
        tags: ['roadmap'],
        content: [
          portableTextParagraph('API stability, migration tools, and a documented upgrade path.'),
        ],
      },
    },
  ])

  await mutate([
    { publish: { id: 'author-ada', type: 'author' } },
    { publish: { id: 'author-grace', type: 'author' } },
    { publish: { id: 'page-home', type: 'page' } },
    { publish: { id: 'page-about', type: 'page' } },
    { publish: { id: 'page-pricing', type: 'page' } },
    { publish: { id: 'post-welcome', type: 'post' } },
    { publish: { id: 'post-rsc', type: 'post' } },
    { publish: { id: 'post-ga', type: 'post' } },
  ])

  console.log('Seeded 2 authors, 3 pages, 3 posts. All published.')
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
