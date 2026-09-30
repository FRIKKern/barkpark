import { describe, expect, it } from 'vitest'
import { renderPortableDocument, type Block } from '../src/PortableDoc'

// An ordered list's first number (`start`), the web twin of walk.ex
// list_start_attr/1: absent or 1 keeps the bare `<ol>`; any other integer
// opens `<ol start="N">`; bullets and non-integers ignore it.
const items = [[{ type: 'text', value: 'five' }], [{ type: 'text', value: 'six' }]]
const list = (extra: Record<string, unknown>): Block =>
  ({ type: 'list', ordered: true, items, ...extra }) as unknown as Block

describe('list start', () => {
  it('an ordered list with start 5 opens <ol start="5">', () => {
    expect(renderPortableDocument([list({ start: 5 })])).toContain('<ol start="5"><li>')
  })

  it('absent start and start 1 render the same bare <ol>', () => {
    const absent = renderPortableDocument([list({})])
    expect(absent).toContain('<ol><li>')
    expect(renderPortableDocument([list({ start: 1 })])).toBe(absent)
  })

  it('start 0 is honoured; a bullet list and a string start are not numbered from it', () => {
    expect(renderPortableDocument([list({ start: 0 })])).toContain('<ol start="0">')
    expect(renderPortableDocument([list({ ordered: false, start: 5 })])).not.toContain('start=')
    expect(renderPortableDocument([list({ start: '5' })])).not.toContain('start=')
  })

  it('a nested ordered list honours its own start', () => {
    const html = renderPortableDocument([
      list({
        items: [{ content: [{ type: 'text', value: 'outer' }], children: [list({ start: 3 })] }],
      }),
    ])
    expect(html).toContain('<ol><li>')
    expect(html).toContain('<ol start="3">')
  })
})
