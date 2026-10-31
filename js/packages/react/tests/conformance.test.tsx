import { describe, expect, it } from 'vitest'
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { Window } from 'happy-dom'
import {
  MISSING,
  cli,
  conform,
  counts,
  diffShapes,
  diffWords,
  goldenWords,
  htmlText,
  loadPack,
  modeFromEnv,
  settle,
  shapeOf,
  type Report,
} from '../../../../api/priv/portable_doc/conformance/conformance.mjs'
import { PortableDoc } from '../src/index'
import { REGISTERED_TYPES } from '../src/blocks/registry'
import { fieldBlocks } from '../src/field-blocks'
import { embedBlocks } from '../src/embed'

const OPT_IN = { ...fieldBlocks, ...embedBlocks() }
const KNOWN = new Set([...REGISTERED_TYPES, ...Object.keys(OPT_IN)])

function nodesOf(html: string): NodeList {
  const doc = new Window().document
  doc.body.innerHTML = html
  const only = doc.body.children.length === 1 ? doc.body.children[0] : null
  return (only?.classList.contains('bp-paper-surface')
    ? only.childNodes
    : doc.body.childNodes) as unknown as NodeList
}

function judge(golden: { type: string; input: unknown; expectedHtml: string }) {
  if (!KNOWN.has(golden.type)) return MISSING
  const actual = renderToStaticMarkup(
    createElement(PortableDoc, { value: [golden.input], blocks: OPT_IN } as never),
  )
  return diffShapes(shapeOf(nodesOf(actual)), shapeOf(nodesOf(golden.expectedHtml)))
}

describe('@barkpark/react conformance against the golden pack', () => {
  it('matches the committed conformance/react.json', async () => {
    const report = await conform({ renderer: 'react', compare: 'dom', judge })
    const problems = settle(report, modeFromEnv())
    console.log('react', counts(report))
    expect(problems).toEqual([])
  })

  it('refuses an absent pack', async () => {
    await expect(
      conform({ renderer: 'react', compare: 'dom', judge, pack: '/nonexistent-pack' }),
    ).rejects.toThrow(/no golden pack/)
  })
})

describe('the shared conformance normaliser', () => {
  const shape = (html: string) => shapeOf(nodesOf(html))

  it('ignores class order, attribute order, whitespace runs and comments', () => {
    expect(
      diffShapes(
        shape('<div class="b a" data-x="1" role="note">  hi \n there <!-- c --></div>'),
        shape('<div role="note" data-x="1" class="a b">hi there</div>'),
      ),
    ).toEqual([])
  })

  it('skips href, src, srcset, poster and id, and width/height on media only', () => {
    expect(
      diffShapes(
        shape('<a href="/a" id="x" poster="p" srcset="s">t</a>'),
        shape('<a href="/b" id="y">t</a>'),
      ),
    ).toEqual([])
    expect(
      diffShapes(
        shape('<img width="1" height="2" alt="a">'),
        shape('<img width="3" height="4" alt="a">'),
      ),
    ).toEqual([])
    expect(
      diffShapes(
        shape('<svg width="1" height="1"></svg>'),
        shape('<svg width="2" height="1"></svg>'),
      ),
    ).toEqual(['root > svg[0]: attr width "1" != "2"'])
    expect(diffShapes(shape('<svg height="1"></svg>'), shape('<svg height="2"></svg>'))).toEqual([
      'root > svg[0]: attr height "1" != "2"',
    ])
  })

  it('merges text split by a comment into one leaf', () => {
    expect(shape('<p>a<!-- -->b</p>')).toEqual(shape('<p>ab</p>'))
  })

  it('reds a wrong tag, class, attribute, style, text and child count', () => {
    const golden = shape('<p class="a" data-k="1" style="color: red">x<b>y</b></p>')
    const cases: [string, RegExp][] = [
      ['<div class="a" data-k="1" style="color: red">x<b>y</b></div>', /<div> != <p>/],
      ['<p class="b" data-k="1" style="color: red">x<b>y</b></p>', /class \{b\} != \{a\}/],
      ['<p class="a" data-k="2" style="color: red">x<b>y</b></p>', /attr data-k "2" != "1"/],
      ['<p class="a" data-k="1" style="color: blue">x<b>y</b></p>', /style color "blue" != "red"/],
      ['<p class="a" data-k="1" style="color: red">z<b>y</b></p>', /"z" != "x"/],
      ['<p class="a" data-k="1" style="color: red">x</p>', /1 children \[#text\] != 2/],
    ]
    for (const [actual, expected] of cases)
      expect(diffShapes(shape(actual), golden).join('\n')).toMatch(expected)
  })

  it('compares words in order, ignoring case and edge punctuation', () => {
    const words = goldenWords([
      { tag: 'p', children: [{ text: 'Heads up' }, { text: '.' }, { text: 'Body, here' }] },
    ])
    expect(words).toEqual(['heads', 'up', 'body', 'here'])
    expect(diffWords('│ HEADS up. body here │', words)).toEqual([])
    expect(diffWords('body here heads up', words)).toEqual([
      'word 3/4 "body" not found in order',
      'word 4/4 "here" not found in order',
    ])
  })

  it('reads the text of an HTML string, decoding the three entities pdrender escapes', () => {
    expect(htmlText('<pre class="x">a &amp;lt; <b>b</b> &lt;c&gt; &amp; d</pre>')).toBe(
      'a &lt; b <c> & d',
    )
  })

  it('refuses a pack with zero cases', () => {
    const dir = mkdtempSync(join(tmpdir(), 'bp-conformance-'))
    mkdirSync(join(dir, 'blocks'))
    writeFileSync(join(dir, 'stamp.json'), '{}')
    expect(() => loadPack(dir)).toThrow(/zero block cases/)
  })

  it('reads only blocks/*.golden.json from the pack', () => {
    const dir = mkdtempSync(join(tmpdir(), 'bp-conformance-'))
    mkdirSync(join(dir, 'blocks'))
    writeFileSync(join(dir, 'stamp.json'), '{}')
    writeFileSync(join(dir, 'blocks', 'p.golden.json'), '{"type":"p"}')
    writeFileSync(join(dir, 'blocks', 'notes.golden.json.bak'), '{"type":"bak"}')
    expect(loadPack(dir).cases.map((c) => c.type)).toEqual(['p'])
  })

  it('refuses a runner that cannot report missing', async () => {
    await expect(conform({ renderer: 'x', compare: 'dom', judge: () => [] })).rejects.toThrow(
      /cannot see a missing type/,
    )
  })

  it('cli exits 1 on no pack or a report that is not committed, 0 on a clean check', async () => {
    const before = process.exitCode
    const env = { ...process.env }
    delete process.env.CONFORMANCE_WRITE
    delete process.env.CONFORMANCE_STRICT
    try {
      await cli({ renderer: 'react', compare: 'dom', judge, pack: '/nonexistent-pack' })
      expect(process.exitCode).toBe(1)
      await cli({ renderer: 'conformance-uncommitted', compare: 'dom', judge })
      expect(process.exitCode).toBe(1)
      await cli({ renderer: 'react', compare: 'dom', judge })
      expect(process.exitCode).toBe(0)
    } finally {
      process.exitCode = before
      Object.assign(process.env, env)
    }
  })

  it('settle reports a stale stamp, a drifted row, a missing report and strict reds', () => {
    const dir = mkdtempSync(join(tmpdir(), 'bp-conformance-'))
    const path = join(dir, 'x.json')
    const report: Report = {
      renderer: 'x',
      compare: 'dom',
      pack_stamp: 'a',
      ran_at_sha: 's',
      rows: [{ type: 't', status: 'fail', diff: ['d'] }],
    }
    expect(settle(report, { path })).toEqual([
      `${path} is not committed; run with CONFORMANCE_WRITE=1`,
    ])
    expect(settle(report, { path, write: true })).toEqual([])
    expect(settle({ ...report, ran_at_sha: 'other' }, { path })).toEqual([])
    expect(settle({ ...report, pack_stamp: 'b' }, { path }).join()).toMatch(
      /pack_stamp: committed a != now b/,
    )
    expect(settle({ ...report, rows: [{ type: 't', status: 'pass' }] }, { path }).join()).toMatch(
      /row t drifted/,
    )
    expect(settle(report, { path, strict: true })).toEqual(['strict: t is fail'])
  })
})
