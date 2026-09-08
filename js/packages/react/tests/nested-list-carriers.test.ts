import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { renderPortableDocument, type Block } from '../src/PortableDoc'
import { toPlainText } from '../src/toPlainText'

const fixture = JSON.parse(
  readFileSync(
    new URL('../../../../api/test/support/fixtures/nested-list-carriers.json', import.meta.url),
    'utf8',
  ),
) as { blocks: Block[] }

describe('nested list carriers', () => {
  it('renders nested semantic lists and extracts all words in reading order without mutation', () => {
    const before = JSON.stringify(fixture)
    const html = renderPortableDocument(fixture.blocks)
    expect(html).toContain('<ol>')
    expect(html.match(/<ul>/g)).toHaveLength(2)
    expect(html.match(/<ol>/g)).toHaveLength(2)
    for (const word of [
      'Plan',
      'Build',
      'Verify',
      'Ship',
      'Flat sibling',
      'Fallback parent',
      'Alias child',
    ]) {
      expect(html).toContain(word)
    }
    expect(html).not.toContain('Inactive parent fallback')
    expect(toPlainText(fixture.blocks)).toBe(
      'Plan\nBuild\nVerify\nShip\nFlat sibling\nFallback parent\nAlias child',
    )
    expect(JSON.stringify(fixture)).toBe(before)
  })

  it('keeps invalid child fields opaque', () => {
    for (const children of [
      null,
      'not a list',
      {},
      [{ type: 'paragraph', text: 'opaque' }],
      [{ type: 'list', items: 'invalid' }],
    ]) {
      const item = { id: 'item', text: 'Flat', audit: true }
      const block = { type: 'list', items: [item] } as Block
      const extended = { ...block, items: [{ ...item, children }] } as Block
      expect(renderPortableDocument([extended])).toBe(renderPortableDocument([block]))
      expect(toPlainText([extended])).toBe('Flat')
    }
  })
})
