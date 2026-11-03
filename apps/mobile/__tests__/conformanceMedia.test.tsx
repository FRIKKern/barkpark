import type { ReactElement, ReactNode } from 'react'
import { Linking } from 'react-native'

import { renderBlockNative } from '../src/papers/portabledoc/blocks'
import { light } from '../src/ui/theme'

jest.mock('react-native-webview', () => ({ WebView: () => null }))

interface Golden {
  type: string
  input: Record<string, unknown>
}

const goldens = [
  require('../../../api/priv/portable_doc/goldens/blocks/divider.golden.json') as Golden,
  require('../../../api/priv/portable_doc/goldens/blocks/image.golden.json') as Golden,
  require('../../../api/priv/portable_doc/goldens/blocks/video.golden.json') as Golden,
]

interface Walk {
  text: string
  styles: Record<string, unknown>[]
  images: { uri?: string; accessibilityLabel?: string }[]
  presses: (() => void)[]
}

function isElement(node: unknown): node is ReactElement {
  return !!node && typeof node === 'object' && 'props' in (node as object) && '$$typeof' in (node as object)
}

function typeName(type: unknown): string {
  if (typeof type === 'string') return type
  if (typeof type === 'function') {
    const candidate = type as { displayName?: string; name: string }
    return candidate.displayName ?? candidate.name
  }
  if (type !== null && typeof type === 'object') {
    const candidate = type as { displayName?: string; render?: { name?: string } }
    return candidate.displayName ?? candidate.render?.name ?? ''
  }
  return ''
}

function walkNode(node: ReactNode, acc: Walk): void {
  if (node === null || node === undefined || typeof node === 'boolean') return
  if (typeof node === 'string' || typeof node === 'number') {
    acc.text += String(node)
    return
  }
  if (Array.isArray(node)) {
    for (const child of node) walkNode(child as ReactNode, acc)
    return
  }
  if (!isElement(node)) return

  const props = node.props as Record<string, unknown>
  const rawStyle = props.style
  if (rawStyle !== undefined) {
    const parts = Array.isArray(rawStyle) ? rawStyle : [rawStyle]
    acc.styles.push(Object.assign({}, ...parts.filter(Boolean)) as Record<string, unknown>)
  }
  if (typeName(node.type) === 'Image') {
    acc.images.push({
      uri: (props.source as { uri?: string } | undefined)?.uri,
      accessibilityLabel: typeof props.accessibilityLabel === 'string' ? props.accessibilityLabel : undefined,
    })
  }
  if (typeof props.onPress === 'function') acc.presses.push(props.onPress as () => void)
  walkNode(props.children as ReactNode, acc)
}

function render(golden: Golden): Walk {
  const acc: Walk = { text: '', styles: [], images: [], presses: [] }
  walkNode(renderBlockNative(golden.input, { theme: light }, 0), acc)
  return acc
}

describe('mobile source coverage for text-uncheckable conformance goldens', () => {
  it('owns exactly the canonical divider, image, and video inputs', () => {
    expect(goldens.map(({ type }) => type)).toEqual(['divider', 'image', 'video'])
    for (const golden of goldens) expect(golden.input.type).toBe(golden.type)
  })

  it('paints the divider golden as a visible native rule with its section mark', () => {
    const output = render(goldens[0]!)
    expect(output.text).toBe('§')
    expect(output.styles).toContainEqual(expect.objectContaining({ height: 1, alignSelf: 'stretch' }))
  })

  it('preserves the image golden source, accessible name, and authored ratio', () => {
    const output = render(goldens[1]!)
    expect(output.images).toEqual([
      { uri: 'https://cdn.example.com/cover.png', accessibilityLabel: 'Cover art' },
    ])
    expect(output.styles).toContainEqual(expect.objectContaining({ width: '100%', aspectRatio: 640 / 360 }))
  })

  it('renders the video golden as an honest poster-backed handoff with its track count', () => {
    const open = jest.spyOn(Linking, 'openURL').mockResolvedValue(true)
    try {
      const output = render(goldens[2]!)
      expect(output.text).toContain('▶ Video · 1 caption track · open in browser')
      expect(output.images).toEqual([
        { uri: 'https://ex.com/demo-poster.jpg', accessibilityLabel: '' },
      ])
      expect(output.presses).toHaveLength(1)
      output.presses[0]?.()
      expect(open).toHaveBeenCalledWith('https://ex.com/demo.mp4')
    } finally {
      open.mockRestore()
    }
  })
})
