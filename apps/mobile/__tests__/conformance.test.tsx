import { act, create, type ReactTestRenderer, type ReactTestRendererJSON } from 'react-test-renderer'

import {
  MISSING,
  conform,
  counts,
  diffWords,
  goldenWords,
  modeFromEnv,
  settle,
  type GoldenCase,
} from '../../../api/priv/portable_doc/conformance/conformance.mjs'
import { BLOCK_RENDERERS, renderBlockNative } from '../src/papers/portabledoc/blocks'
import { light } from '../src/ui/theme'

jest.mock('react-native-webview', () => ({ WebView: () => null }))

type Host = ReactTestRendererJSON | ReactTestRendererJSON[] | string | null

function textOf(node: Host): string {
  if (node === null) return ''
  if (typeof node === 'string') return node
  if (Array.isArray(node)) return node.map(textOf).join(' ')
  return (node.children ?? []).map(textOf).join(' ')
}

function judge(golden: GoldenCase) {
  if (!(golden.type in BLOCK_RENDERERS)) return MISSING
  let tree!: ReactTestRenderer
  act(() => {
    tree = create(<>{renderBlockNative(golden.input, { theme: light }, 0)}</>)
  })
  const text = textOf(tree.toJSON())
  act(() => tree.unmount())
  return diffWords(text, goldenWords(golden.shape))
}

describe('mobile renderer conformance against the golden pack', () => {
  it('matches the committed conformance/mobile.json', async () => {
    const report = await conform({ renderer: 'mobile', compare: 'text', judge })
    const problems = settle(report, modeFromEnv())
    console.log('mobile', counts(report))
    expect(problems).toEqual([])
  })

  it('refuses an absent pack', async () => {
    await expect(conform({ renderer: 'mobile', compare: 'text', judge, pack: '/nonexistent-pack' })).rejects.toThrow(/no golden pack/)
  })
})
