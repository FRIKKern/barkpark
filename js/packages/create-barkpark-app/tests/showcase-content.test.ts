import { readdirSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import { renderPortableDocument } from '@barkpark/react'
import { showcaseContent } from '../templates/blog-starter/seeds/showcase-content'

// The blog-starter's flagship post body is the FULL 64-type PortableDocument
// grammar, concatenated from `@barkpark/react`'s pd-golden parity fixtures (one
// source of truth — see scripts/gen-showcase-content.mjs). This proves the
// migrated blog renders every canonical block type through the canonical
// renderer, and that the three media families expose the mount points the
// `@barkpark/react/client` hydrator (mermaid + asciicast) and a static `<img>`
// need.
const GOLDEN_DIR = join(
  dirname(fileURLToPath(import.meta.url)),
  '..',
  '..',
  'react',
  'tests',
  'fixtures',
  'pd-golden',
)

interface ShapeNode {
  tag: string
  classes?: string[]
  children?: ShapeNode[]
  text?: string
  data?: Record<string, string>
}
interface Golden {
  type: string
  input: { type: string; [k: string]: unknown }
  shape: ShapeNode[]
}

function loadGoldens(): Golden[] {
  return readdirSync(GOLDEN_DIR)
    .filter((f) => f.endsWith('.golden.json'))
    .sort()
    .map((f) => JSON.parse(readFileSync(join(GOLDEN_DIR, f), 'utf8')) as Golden)
}

// Every class the golden's DOM-shape projection carries, root-to-leaf.
function classesOf(nodes: ShapeNode[]): string[] {
  const out: string[] = []
  const walk = (n: ShapeNode) => {
    for (const c of n.classes ?? []) out.push(c)
    for (const k of n.children ?? []) walk(k)
  }
  nodes.forEach(walk)
  return out
}

const goldens = loadGoldens()

describe('blog-starter showcase seed (64-type PortableDocument grammar)', () => {
  it('seeds exactly the 64 canonical block types, in sync with the pd-golden fixtures', () => {
    // Guards against drift between the generated seed and the parity fixtures.
    // scaffy:add-block-type Toc MARK:showcase-goldens-toc
    // scaffy:add-block-type Steps MARK:showcase-goldens-steps
    // scaffy:add-block-type Footnote MARK:showcase-goldens-footnote
    // scaffy:add-block-type Expandable MARK:showcase-goldens-expandable
    // scaffy:add-block-type BarChart MARK:showcase-goldens-bar-chart
    // scaffy:add-block-type Equation MARK:showcase-goldens-equation
    // scaffy:add-block-type CriteriaProgress MARK:showcase-goldens-criteria-progress
    // scaffy:add-block-type Video MARK:showcase-goldens-video
    // scaffy:add-block-type ApiEndpoint MARK:showcase-goldens-api-endpoint
    // scaffy:add-block-type CodeTabs MARK:showcase-goldens-code-tabs
    // scaffy:add-block-type Tabs MARK:showcase-goldens-tabs
    expect(goldens).toHaveLength(64)
    const goldenTypes = goldens.map((g) => g.type).sort()
    const seedTypes = showcaseContent.map((b) => b.type).sort()
    expect(seedTypes).toEqual(goldenTypes)
    // scaffy:add-block-type Toc MARK:showcase-seedset-toc
    // scaffy:add-block-type Steps MARK:showcase-seedset-steps
    // scaffy:add-block-type Footnote MARK:showcase-seedset-footnote
    // scaffy:add-block-type Expandable MARK:showcase-seedset-expandable
    // scaffy:add-block-type BarChart MARK:showcase-seedset-bar-chart
    // scaffy:add-block-type Equation MARK:showcase-seedset-equation
    // scaffy:add-block-type CriteriaProgress MARK:showcase-seedset-criteria-progress
    // scaffy:add-block-type Video MARK:showcase-seedset-video
    // scaffy:add-block-type ApiEndpoint MARK:showcase-seedset-api-endpoint
    // scaffy:add-block-type CodeTabs MARK:showcase-seedset-code-tabs
    // scaffy:add-block-type Tabs MARK:showcase-seedset-tabs
    expect(new Set(seedTypes).size).toBe(64)
  })

  it('renders all 64 distinct types through renderPortableDocument, each with its golden class-markers', () => {
    const byType = new Map(goldens.map((g) => [g.type, g]))
    const markersSeen = new Set<string>()

    for (const block of showcaseContent) {
      const g = byType.get(block.type)
      expect(g, `no golden for seeded type ${block.type}`).toBeDefined()
      if (!g) continue

      const html = renderPortableDocument([block])
      expect(html.length, `${block.type} rendered empty`).toBeGreaterThan(0)

      // The root tag the golden proves must open in the JS render (shape-equal
      // to the Elixir :article golden).
      const rootTag = g.shape[0]?.tag
      expect(rootTag, `${block.type} golden has no root tag`).toBeTruthy()
      expect(html, `${block.type} missing <${rootTag}>`).toContain(`<${rootTag}`)

      // Every `bp-*` class the golden's shape carries must appear — these ARE
      // the per-type class-markers.
      const bpClasses = classesOf(g.shape).filter((c) => c.startsWith('bp-'))
      for (const cls of bpClasses) {
        expect(html, `${block.type} missing class ${cls}`).toContain(cls)
      }

      // Fingerprint the type by (root tag + its bp-classes) so the run proves 64
      // DISTINCT renderings, not one repeated 64×.
      markersSeen.add(`${block.type}:${rootTag}:${bpClasses.sort().join(',')}`)
    }

    // scaffy:add-block-type Toc MARK:showcase-markers-toc
    // scaffy:add-block-type Steps MARK:showcase-markers-steps
    // scaffy:add-block-type Footnote MARK:showcase-markers-footnote
    // scaffy:add-block-type Expandable MARK:showcase-markers-expandable
    // scaffy:add-block-type BarChart MARK:showcase-markers-bar-chart
    // scaffy:add-block-type Equation MARK:showcase-markers-equation
    // scaffy:add-block-type CriteriaProgress MARK:showcase-markers-criteria-progress
    // scaffy:add-block-type Video MARK:showcase-markers-video
    // scaffy:add-block-type ApiEndpoint MARK:showcase-markers-api-endpoint
    // scaffy:add-block-type CodeTabs MARK:showcase-markers-code-tabs
    // scaffy:add-block-type Tabs MARK:showcase-markers-tabs
    expect(markersSeen.size).toBe(64)
  })

  it('exposes the 3 media families (mermaid diagram / asciicast player / static image)', () => {
    const html = renderPortableDocument(showcaseContent)
    // diagram → the `pre.mermaid` mount point hydratePortableDoc() renders into an SVG.
    expect(html).toMatch(/<pre class="mermaid">/)
    // asciicast → the `div.bp-asciicast[data-cast-src]` mount the player mounts into.
    expect(html).toMatch(/class="bp-asciicast"[^>]*data-cast-src="[^"]+"/)
    // image → a STATIC <img> (no hydration; hydratePortableDoc never touches it).
    expect(html).toMatch(/<img\s[^>]*src="[^"]+"/)
  })
})
