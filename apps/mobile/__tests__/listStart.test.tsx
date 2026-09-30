// An ordered list's first number (`start`), the native twin of walk.ex
// list_start_attr/1: absent or 1 numbers from 1; any other integer numbers from
// it; bullets and a string "5" ignore it; a nested list keeps its own start.
import type { ReactElement, ReactNode } from 'react'

import { renderBlockNative, type BlockCtx } from '../src/papers/portabledoc/blocks'
import { light } from '../src/ui/theme'

// The webview TurboModule trap: MermaidIsland reaches react-native-webview
// through the registry barrel, which jest cannot resolve natively.
jest.mock('react-native-webview', () => ({ WebView: () => null }))

const paper: BlockCtx = { theme: light }

function isElement(node: unknown): node is ReactElement {
  return !!node && typeof node === 'object' && 'props' in (node as object) && '$$typeof' in (node as object)
}

function text(node: ReactNode): string {
  if (node === null || node === undefined || typeof node === 'boolean') return ''
  if (typeof node === 'string' || typeof node === 'number') return String(node)
  if (Array.isArray(node)) return node.map((child) => text(child as ReactNode)).join('|')
  if (isElement(node)) return text((node.props as { children?: ReactNode }).children)
  return ''
}

const items = [[{ type: 'text', value: 'five' }], [{ type: 'text', value: 'six' }]]
const render = (block: Record<string, unknown>) =>
  text(renderBlockNative({ type: 'list', ordered: true, items, ...block }, paper, 0))

describe('list start', () => {
  it('an ordered list with start 5 numbers 5, 6', () => {
    const out = render({ start: 5 })
    expect(out).toContain('5.|five')
    expect(out).toContain('6.|six')
    expect(out).not.toContain('1.|five')
  })

  it('absent start and start 1 number from 1, identically', () => {
    const absent = render({})
    expect(absent).toContain('1.|five')
    expect(absent).toContain('2.|six')
    expect(render({ start: 1 })).toBe(absent)
  })

  it('start 0 is honoured; a bullet list and a string start are not numbered from it', () => {
    expect(render({ start: 0 })).toContain('0.|five')
    expect(render({ ordered: false, start: 5 })).not.toContain('5.')
    expect(render({ start: '5' })).toContain('1.|five')
  })

  it('a nested ordered list numbers from its own start', () => {
    const out = render({
      items: [
        {
          content: [{ type: 'text', value: 'outer' }],
          children: [{ type: 'list', ordered: true, start: 3, items }],
        },
      ],
    })
    expect(out).toContain('1.|outer')
    expect(out).toContain('3.|five')
    expect(out).toContain('4.|six')
  })
})
