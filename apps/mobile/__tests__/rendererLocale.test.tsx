// The PortableDoc renderer's own words follow the workspace language
// (task-5ba3360aecba7a99). The mobile renderer printed a hard-coded Norwegian
// «Kilde» under every data-viz figure, so an English workspace read
// "Kilde: …". It now says Source/Sources in English and Kilde/Kilder in
// nb-NO, as the Elixir and @barkpark/react renderers do (#22689).
import type { ReactNode } from 'react'
import { act, create, type ReactTestRenderer } from 'react-test-renderer'

import { fetchWorkspaceLocale } from '../src/api/workspace'
import { renderBlockNative, type BlockCtx } from '../src/papers/portabledoc/blocks'
import { chromeWord } from '../src/papers/portabledoc/chrome'
import { light } from '../src/ui/theme'

jest.mock('react-native-webview', () => ({ WebView: () => null }))

// Mount the block and read every string its Text hosts paint.
function text(node: ReactNode): string {
  let tree: ReactTestRenderer | undefined
  act(() => {
    tree = create(<>{node}</>)
  })
  const out = strings(tree!.toJSON()).join('')
  act(() => tree!.unmount())
  return out
}

// Every text leaf of the rendered host tree, in order.
function strings(node: unknown): string[] {
  if (typeof node === 'string') return [node]
  if (Array.isArray(node)) return node.flatMap(strings)
  if (node && typeof node === 'object' && 'children' in node)
    return strings((node as { children: unknown }).children)
  return []
}

const oneSource = { type: 'stat', value: '42', label: 'answers', source: 'commit:591fdcd53' }
const twoSources = {
  type: 'stats',
  items: [
    { value: '7', label: 'seven', source: 'commit:aaa1111' },
    { value: '9', label: 'nine', source: 'commit:bbb2222' },
  ],
}

function render(block: unknown, locale?: string): string {
  const ctx: BlockCtx = { theme: light, ...(locale !== undefined && { locale }) }
  return text(renderBlockNative(block, ctx, 0))
}

describe('the data-viz source stamp follows the workspace language', () => {
  test('English: Source / Sources', () => {
    expect(render(oneSource, 'en')).toContain('Source: ')
    expect(render(twoSources, 'en')).toContain('Sources: ')
    expect(render(oneSource, 'en')).not.toContain('Kilde')
  })

  test('no locale is English (the default)', () => {
    expect(render(oneSource)).toContain('Source: ')
    expect(render(twoSources)).toContain('Sources: ')
  })

  test('nb-NO: Kilde / Kilder', () => {
    expect(render(oneSource, 'nb-NO')).toContain('Kilde: ')
    expect(render(twoSources, 'nb-NO')).toContain('Kilder: ')
    expect(render(oneSource, 'nb-NO')).not.toContain('Source')
  })

  test('an unknown locale and an unknown word fall back to English', () => {
    expect(chromeWord('xx-XX', 'Source')).toBe('Source')
    expect(chromeWord('nb-NO', 'Not a chrome word')).toBe('Not a chrome word')
  })
})

describe('fetchWorkspaceLocale', () => {
  const client = (impl: () => Promise<unknown>) =>
    ({ fetchRaw: jest.fn(impl) }) as unknown as Parameters<typeof fetchWorkspaceLocale>[0]

  test('reads the locale the server reports', async () => {
    const c = client(async () => ({ ok: true, json: async () => ({ locale: 'nb-NO' }) }))
    await expect(fetchWorkspaceLocale(c)).resolves.toBe('nb-NO')
  })

  test('a 404 (unscoped connection) is English', async () => {
    const c = client(async () => ({ ok: false, status: 404, json: async () => ({}) }))
    await expect(fetchWorkspaceLocale(c)).resolves.toBe('en')
  })

  test('offline is English', async () => {
    const c = client(async () => {
      throw new Error('network down')
    })
    await expect(fetchWorkspaceLocale(c)).resolves.toBe('en')
  })
})
