#!/usr/bin/env node
// Build the CROWN PAPER (charter D51) from the pd-parity corpus: one section per
// registered block type, each carrying the EXACT `input` the Elixir emitter
// produced its frozen golden from.
//
// Why derive it instead of hand-writing a showcase: D51 rejected the
// "106-block showcase" as the emulator corpus because it misses 28 of the 66
// registered keys — a green run over it would prove almost nothing. The parity
// fixtures are the only corpus with per-type coverage AND a generator as its
// sole writer, so a paper derived from them covers every type by construction
// and cannot be quietly trimmed to fit what already works.
//
// The per-type h2 is not decoration: it is what lets the oracle ATTRIBUTE an
// "Unsupported block: x" hit to a position in the document instead of just
// reporting that one exists somewhere.
//
// Spacing follows the Mechanical Spacing Doctrine (/papers/mechanical-spacing-
// doctrine): every gap is an authored empty paragraph block — one after the
// title, two before each level-2 heading — never a renderer margin.
//
// Usage: node apps/mobile/scripts/gen-crown-paper.mjs > /tmp/crown-paper.json
//        bp doc create paper --file /tmp/crown-paper.json --yes

import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO = join(HERE, '..', '..', '..')
const FIXTURES = join(REPO, 'api', 'test', 'support', 'fixtures', 'pd-parity')

const ID = process.env.CROWN_PAPER_ID ?? 'mobile-crown-floor-pd-parity'
const TITLE =
  'Mobile Crown Floor — every PortableDoc type, rendered from the pd-parity corpus'

const files = readdirSync(FIXTURES)
  .filter((f) => f.endsWith('.golden.json'))
  .sort()
if (files.length < 60) {
  throw new Error(`refusing to build the crown paper from ${files.length} fixtures (expected >= 60)`)
}

const gap = (id) => ({ id, type: 'paragraph', content: [] })
const blocks = [
  { id: 'h1', level: 1, text: TITLE, type: 'heading' },
  gap('sp-title'),
  {
    id: 'intro',
    type: 'paragraph',
    content: [
      {
        type: 'text',
        value:
          `Machine-generated from the ${files.length} generator-owned pd-parity fixtures. ` +
          'Each section below carries the exact block input the Elixir emitter froze its ' +
          'cross-surface golden from, so opening this paper in the native reader drives every ' +
          'registered renderer once. The oracle for this page is mechanical: an on-device ' +
          'uiautomator dump must contain zero hits for the degrade box the dispatcher paints ' +
          'when it does not recognise a type. This sentence deliberately does NOT quote that ' +
          'label — an earlier draft did, and the paper then matched the very grep that is ' +
          'supposed to prove it clean.',
      },
    ],
  },
]

let n = 0
for (const file of files) {
  const parsed = JSON.parse(readFileSync(join(FIXTURES, file), 'utf8'))
  const type = String(parsed.type)
  if (!parsed.input || typeof parsed.input !== 'object' || Array.isArray(parsed.input)) {
    throw new Error(`${file}: input is not a single block map — the D51 fixture shape law is broken`)
  }
  // Two authored gaps before each level-2 heading (the doctrine's rhythm).
  blocks.push(gap(`sp-${n}a`), gap(`sp-${n}b`))
  blocks.push({ id: `h2-${type}`, level: 2, text: type, type: 'heading' })
  blocks.push({ ...parsed.input, id: `b-${type}` })
  n++
}

const doc = {
  _id: ID,
  _type: 'paper',
  title: TITLE,
  description:
    'Machine-generated emulator-oracle corpus for the mobile zero-unknown-blocks crown: one ' +
    'section per registered PortableDoc block type, each carrying the exact pd-parity fixture ' +
    'input. Opening it in the native reader drives all 66 registered renderers; the proof is a ' +
    'uiautomator dump with zero hits for the unrecognised-type degrade box. (Neither this ' +
    'description nor the intro quotes that label verbatim — the paper must not match the grep ' +
    'that certifies it.)',
  style: 'article',
  main_tag: 'portabledoc',
  tags: [
    {
      tag: 'portabledoc',
      strength: 95,
      rationale: 'one section per registered PortableDoc block type, derived from the parity corpus',
    },
    {
      tag: 'mobile',
      strength: 80,
      rationale: 'the emulator oracle for the mobile crown floor reads this paper',
    },
    {
      tag: 'testing',
      strength: 70,
      rationale: 'a corpus artifact whose only purpose is to be measured on a device',
    },
  ],
  blocks,
  body: { blocks },
}

// THE SELF-GUARD, and it has already earned its keep. The first version of this
// generator explained the oracle by quoting the degrade label verbatim in the
// intro and again in the description — so the published paper CONTAINED the
// string the oracle greps for, and the very first run reported a hit in a
// document where every one of the 60 renderers had worked perfectly. A false
// positive is the milder failure; the same collision inverted (a paper worded so
// that a real hit is indistinguishable from prose) would be a false GREEN. The
// corpus must never match the grep that certifies it, so the generator refuses
// to emit a paper that does.
const SENTINEL = ['Unsupported', 'block:'].join(' ')
const serialized = JSON.stringify(doc, null, 2)
if (serialized.includes(SENTINEL) || serialized.includes('Unsupported block')) {
  throw new Error(
    'refusing to emit a crown paper containing the degrade-box label — the oracle greps for it, ' +
      'so a paper carrying it makes the proof meaningless in both directions',
  )
}

process.stdout.write(serialized)
process.stderr.write(`crown paper: ${n} type sections, ${blocks.length} blocks total\n`)
