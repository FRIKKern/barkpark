import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import { renderPortableDocument } from '@barkpark/react'

/**
 * WEBSITE-STARTER PORTABLEDOC ARM (row rpu-backlog-website-starter-migrate).
 *
 * website-starter is the DEFAULT `create-barkpark-app` template. Its three
 * `richText` pages — about, posts/[slug], pricing — were migrated off the
 * legacy Sanity PortableText render path onto the canonical PortableDoc
 * renderer (`@barkpark/react`'s `renderPortableDocument`, mounted through the
 * one shared `app/portable-doc-surface.tsx` island, which drives
 * `@barkpark/react/client`'s `hydratePortableDoc`). blog-starter's equivalent
 * proof is `showcase-content.test.ts` + the `@barkpark/blog-hydration-parity`
 * browser package; website-starter shipped with NO arm at all, so a revert to
 * PortableText was machine-invisible. This file is that arm.
 *
 * It is OFFLINE and dependency-free (node env, no new devDeps, no lockfile
 * touch). It has three kinds of assertion, deliberately:
 *
 *   1. SOURCE SHAPE — each page routes its body through `PortableDocSurface`
 *      and carries no PortableText import/element. Reds the moment a page is
 *      reverted.
 *   2. RENDER, FIXTURE-SOURCED — the expected HTML is READ FROM
 *      `@barkpark/react`'s pd-golden parity fixture (the frozen output of the
 *      real Elixir emitter), never hand-copied from the implementation, so the
 *      expectation cannot drift into a tautology.
 *   3. DISCRIMINATION CONTROL — the same renderer fed a LEGACY PortableText
 *      block emits none of that block's text. That is what makes (2)
 *      protective: if the seed or a page regressed to the Sanity grammar, the
 *      canonical renderer would render nothing, and (2) would red.
 */

const HERE = dirname(fileURLToPath(import.meta.url))
const TEMPLATE = join(HERE, '..', 'templates', 'website-starter')
const GOLDEN = join(
  HERE,
  '..',
  '..',
  'react',
  'tests',
  'fixtures',
  'pd-golden',
  'paragraph.golden.json',
)

/** The three migrated `richText` pages, keyed by the field each renders. */
const PAGES: { label: string; file: string; field: string }[] = [
  { label: 'about', file: join('app', 'about', 'page.tsx'), field: 'body' },
  { label: 'pricing', file: join('app', 'pricing', 'page.tsx'), field: 'body' },
  {
    label: 'posts/[slug]',
    file: join('app', 'posts', '[slug]', 'page.tsx'),
    field: 'content',
  },
]

function read(rel: string): string {
  return readFileSync(join(TEMPLATE, rel), 'utf8')
}

/**
 * Strip `//` and block comments. The migrated pages each carry a prose comment
 * containing the word "PortableText" (". . . NOT Sanity PortableText."), so a
 * naive grep for the word would fire on the CORRECT state. The detector below
 * looks at code only — and `discriminates against its own comment` asserts
 * exactly that.
 */
function stripComments(src: string): string {
  return src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '')
}

/** A live PortableText usage: an import from the package, or a `<PortableText` element. */
function usesPortableText(src: string): boolean {
  const code = stripComments(src)
  return (
    /from\s+['"]@portabletext\/[^'"]+['"]/.test(code) ||
    /<PortableText[\s/>]/.test(code)
  )
}

interface Golden {
  type: string
  input: { type: string; content?: { type: string; value?: string }[] }
  expectedHtml: string
}
const golden = JSON.parse(readFileSync(GOLDEN, 'utf8')) as Golden

describe('website-starter: the three richText pages render via canonical PortableDoc', () => {
  it.each(PAGES)(
    '$label routes its $field through the shared PortableDocSurface island',
    ({ file, field }) => {
      const src = read(file)
      const code = stripComments(src)
      // The island, imported from the ONE shared surface (not a per-page fork).
      expect(code).toMatch(
        /import\s*\{\s*PortableDocSurface\s*\}\s*from\s*['"][^'"]*portable-doc-surface['"]/,
      )
      // It is actually MOUNTED with that page's richText field — present-in-file
      // is not rendered-on-the-page.
      expect(code).toMatch(
        new RegExp(`<PortableDocSurface\\s+blocks=\\{[A-Za-z]+\\.${field}\\}`),
      )
      // The field is typed as the canonical block array, not PortableText spans.
      expect(code).toMatch(new RegExp(`${field}\\?:\\s*Block\\[\\]`))
      expect(code).toMatch(/import\s+type\s*\{\s*Block\s*\}\s*from\s*['"]@barkpark\/react['"]/)
      // And the canonical skin ships with it.
      expect(code).toContain("@barkpark/react/paper-surface.css")
    },
  )

  it.each(PAGES)('$label imports no PortableText renderer', ({ file }) => {
    expect(usesPortableText(read(file))).toBe(false)
  })

  it('the shared island server-renders via renderPortableDocument and hydrates via /client', () => {
    const code = stripComments(read(join('app', 'portable-doc-surface.tsx')))
    expect(code).toMatch(
      /import\s*\{[^}]*renderPortableDocument[^}]*\}\s*from\s*['"]@barkpark\/react['"]/,
    )
    expect(code).toMatch(
      /import\s*\{\s*hydratePortableDoc\s*\}\s*from\s*['"]@barkpark\/react\/client['"]/,
    )
    expect(code).toContain('hydratePortableDoc(ref.current)')
  })

  it.each([
    { label: 'page', file: join('schemas', 'page.ts'), field: 'body' },
    { label: 'post', file: join('schemas', 'post.ts'), field: 'content' },
  ])('$label schema keeps $field as a canonical richText body surface', ({ file, field }) => {
    const code = stripComments(read(file))
    expect(code).toMatch(
      new RegExp(`name:\\s*'${field}',\\s*type:\\s*'richText',\\s*surface:\\s*'body'`),
    )
  })
})

describe('website-starter: the renderer the pages import emits the canonical shape', () => {
  it('reproduces the pd-golden paragraph fixture byte-for-byte (expectation READ, never hand-copied)', () => {
    // `golden.expectedHtml` is the frozen output of the real Elixir emitter,
    // generated by `mix barkpark.portable_doc.gen_pd_parity`. Nothing here is
    // transcribed from the JS implementation.
    expect(renderPortableDocument([golden.input as never])).toBe(golden.expectedHtml)
  })

  it('the seed authors the same type-keyed grammar the fixture uses', () => {
    const seed = stripComments(read(join('seeds', 'seed.ts')))
    const blockType = golden.input.type // 'paragraph', from the fixture
    const leafType = golden.input.content?.[0]?.type // 'text', from the fixture
    expect(blockType).toBeTruthy()
    expect(leafType).toBeTruthy()
    expect(seed).toMatch(new RegExp(`type:\\s*'${blockType}'`))
    expect(seed).toMatch(new RegExp(`type:\\s*'${leafType}'`))
    // The Sanity grammar the migration removed must not come back with it.
    expect(seed).not.toMatch(/_type:\s*'block'/)
    expect(seed).not.toMatch(/_type:\s*'span'/)
  })
})

describe('controls — the assertions above discriminate', () => {
  it('the canonical renderer renders NOTHING from a legacy PortableText block', () => {
    // This is why the fixture assertion is protective rather than decorative:
    // had the pages/seed stayed on the Sanity grammar, this is what the
    // canonical renderer would have produced for their bodies.
    const legacy = {
      _type: 'block',
      style: 'normal',
      children: [{ _type: 'span', text: 'legacy portable text body' }],
    }
    const html = renderPortableDocument([legacy as never])
    expect(html).not.toContain('legacy portable text body')
  })

  it('the PortableText detector discriminates: it ignores the prose comment but catches a real import', () => {
    // The migrated pages DO contain the word in a comment. A detector that
    // fired on the word would be red on the correct state (and so useless);
    // one that never fires would be quiet on the reverted state (and so
    // vacuous). Both directions, on real page source.
    const about = PAGES.find((p) => p.label === 'about')
    expect(about).toBeDefined()
    const correct = read(about!.file)
    expect(correct).toContain('PortableText') // the comment is genuinely there
    expect(usesPortableText(correct)).toBe(false) // and is correctly ignored

    const reverted = correct
      .replace(
        /import \{ PortableDocSurface \}.*\n/,
        "import { PortableText } from '@portabletext/react'\n",
      )
      .replace(/<PortableDocSurface blocks=\{page\.body\} \/>/, '<PortableText value={page.body} />')
    expect(usesPortableText(reverted)).toBe(true)
  })
})
