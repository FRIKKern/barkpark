import { act, create, type ReactTestRenderer, type ReactTestRendererJSON } from 'react-test-renderer'
import { Linking } from 'react-native'

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
import { mobileStructuralVerdict } from './support/mobileStructuralConformance'

jest.mock('react-native-webview', () => ({ WebView: () => null }))

type Host = ReactTestRendererJSON | ReactTestRendererJSON[] | string | null

function textOf(node: Host): string {
  if (node === null) return ''
  if (typeof node === 'string') return node
  if (Array.isArray(node)) return node.map(textOf).join(' ')
  return (node.children ?? []).map(textOf).join(' ')
}

function observePressTarget(press: () => void): string | undefined {
  const open = jest.spyOn(Linking, 'openURL').mockResolvedValue(true)
  try {
    press()
    return open.mock.calls[0]?.[0]
  } finally {
    open.mockRestore()
  }
}

function judge(golden: GoldenCase) {
  if (!(golden.type in BLOCK_RENDERERS)) return MISSING
  const output = renderBlockNative(golden.input, { theme: light }, 0)
  const structural = mobileStructuralVerdict(golden, output, observePressTarget)
  if (structural !== undefined) return structural
  let tree!: ReactTestRenderer
  act(() => {
    tree = create(<>{output}</>)
  })
  const text = textOf(tree.toJSON())
  act(() => tree.unmount())
  return diffWords(text, goldenWords(golden.shape))
}

describe('mobile renderer conformance against the golden pack', () => {
  it('passes the six-row R6 renderer cluster', async () => {
    const target = new Set([
      'api-endpoint',
      'chat-tool-diff',
      'code-tabs',
      'diagram',
      'tabs',
      'terminal',
    ])
    const report = await conform({ renderer: 'mobile', compare: 'text', judge })
    expect(report.rows.filter((row) => target.has(row.type))).toEqual(
      [...target].map((type) => ({ type, status: 'pass' })),
    )
  })

  it('passes the three wordless media rows through native structure', async () => {
    const target = new Set(['divider', 'image', 'video'])
    const report = await conform({ renderer: 'mobile', compare: 'text', judge })
    expect(report.rows.filter((row) => target.has(row.type))).toEqual(
      [...target].map((type) => ({ type, via: 'native-structure', status: 'pass' })),
    )
  })

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
