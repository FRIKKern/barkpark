// Malformed-input crash-class audit (task-550252fab1482265), mirroring the
// Elixir walk.ex children:null fix (#12425): the registry's contract is
// "degrade, never throw" — an unknown block becomes a visible placeholder, so
// a KNOWN type carrying hostile field shapes (null children, scalar rows, a
// map where a list belongs, arrays of null) must ALSO degrade, never throw.
// This harness drives every registered type through every hostile shape; any
// throw is a real crash a single malformed persisted block would cause in a
// consumer's page render.
import { describe, it, expect } from 'vitest'
import { REGISTERED_TYPES, renderBlock } from '../src/blocks/registry'
import type { Block } from '../src/inline'
import { toPlainText } from '../src/toPlainText'

// The field vocabulary the emitters read, swept from src/blocks/*.ts. Each key
// is set to a hostile value ALL AT ONCE per variant — an emitter only reads its
// own keys, so this covers every (type, key, value) pair in |types|×|values|
// renders instead of the full cube.
const COMMON_KEYS = [
  'content', 'children', 'text', 'value', 'items', 'rows', 'cells', 'columns',
  'tabs', 'blocks', 'steps', 'headers', 'data', 'series', 'points', 'fields',
  'options', 'messages', 'lines', 'tasks', 'cards', 'entries', 'sources',
  'panels', 'level', 'src', 'url', 'alt', 'label', 'title', 'lang', 'code',
  'caption', 'style', 'marks', 'align', 'legend', 'role', 'kind', 'name',
  'checked', 'ordered', 'start', 'meta', 'attrs', 'body', 'footer', 'summary',
] as const

const HOSTILE_VALUES: ReadonlyArray<[string, unknown]> = [
  ['null', null],
  ['undefined', undefined],
  ['number', 42],
  ['string', 'x'],
  ['boolean', true],
  ['empty map', {}],
  ['empty list', []],
  ['list of null', [null]],
  ['list of scalars', [42, 'x', true]],
  ['list of empty maps', [{}, {}]],
  ['nested list', [[null], [[42]]]],
  ['map where list belongs', { 0: 'a', length: 1 }],
]

function blockWithAllKeys(type: string, v: unknown): Block {
  const b: Record<string, unknown> = { type }
  for (const k of COMMON_KEYS) b[k] = v
  return b as Block
}

describe('every registered block type degrades on hostile field shapes — never throws', () => {
  for (const type of REGISTERED_TYPES) {
    it(`${type} survives all hostile shapes`, () => {
      // Bare block: nothing but the type.
      expect(typeof renderBlock({ type } as Block)).toBe('string')
      for (const [labelOfV, v] of HOSTILE_VALUES) {
        let out: string
        try {
          out = renderBlock(blockWithAllKeys(type, v))
        } catch (err) {
          throw new Error(
            `renderBlock threw for type=${type} with every common field = ${labelOfV}: ${String(err)}`,
          )
        }
        expect(typeof out).toBe('string')
      }
    })
  }

  it('deep-nested hostile children degrade too', () => {
    const nasty: Block[] = REGISTERED_TYPES.map(
      (type) =>
        ({
          type,
          content: [null, 42, { type: 'text', value: null }, { children: null }],
          children: [null, { type: 'bold', children: [null, 7] }],
          items: [null, { content: null, children: 'x' }],
          rows: [null, { cells: null }, { cells: [null, 3] }],
          tabs: [null, { label: null, blocks: [null, { type: 'paragraph', content: 9 }] }],
          blocks: [null, { type: 'section', blocks: null }],
        }) as unknown as Block,
    )
    for (const b of nasty) {
      expect(typeof renderBlock(b)).toBe('string')
    }
  })

  it('toPlainText is fail-soft over the same hostile corpus', () => {
    for (const [, v] of HOSTILE_VALUES) {
      const blocks = REGISTERED_TYPES.map((type) => blockWithAllKeys(type, v))
      expect(typeof toPlainText(blocks as never)).toBe('string')
    }
  })
})
