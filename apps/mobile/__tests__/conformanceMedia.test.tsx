import { Image, Linking, Pressable, Text, View } from 'react-native'

import {
  MISSING,
  conform,
} from '../../../api/priv/portable_doc/conformance/conformance.mjs'
import { BLOCK_RENDERERS, renderBlockNative } from '../src/papers/portabledoc/blocks'
import { light } from '../src/ui/theme'
import { mobileStructuralVerdict } from './support/mobileStructuralConformance'

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

function render(golden: Golden) {
  return renderBlockNative(golden.input, { theme: light }, 0)
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

describe('mobile source coverage for text-uncheckable conformance goldens', () => {
  it('owns exactly the canonical divider, image, and video inputs', () => {
    expect(goldens.map(({ type }) => type)).toEqual(['divider', 'image', 'video'])
    for (const golden of goldens) expect(golden.input.type).toBe(golden.type)
  })

  it.each(goldens)('passes $type through its native structural arm', (golden) => {
    expect(mobileStructuralVerdict(golden, render(golden), observePressTarget)).toEqual({
      diff: [],
      via: 'native-structure',
    })
  })

  it('produces explicit native-structure pass rows without relabeling the text comparator', async () => {
    const report = await conform({
      renderer: 'mobile',
      compare: 'text',
      judge(golden) {
        if (!(golden.type in BLOCK_RENDERERS)) return MISSING
        return mobileStructuralVerdict(golden, render(golden), observePressTarget) ?? MISSING
      },
    })
    expect(report.rows.filter(({ type }) => ['divider', 'image', 'video'].includes(type))).toEqual([
      { type: 'divider', via: 'native-structure', status: 'pass' },
      { type: 'image', via: 'native-structure', status: 'pass' },
      { type: 'video', via: 'native-structure', status: 'pass' },
    ])
  })

  it('reds a divider mutant that keeps the mark but drops the rule', () => {
    const verdict = mobileStructuralVerdict(goldens[0]!, <Text>§</Text>)
    expect(verdict?.diff).toContain('divider: missing visible 1px stretched rule')
  })

  it('reds an image mutant that points at a different asset', () => {
    const verdict = mobileStructuralVerdict(
      goldens[1]!,
      <Image
        source={{ uri: 'https://cdn.example.com/wrong.png' }}
        accessibilityLabel="Cover art"
        style={{ width: '100%', aspectRatio: 640 / 360 }}
      />,
    )
    expect(verdict?.diff).toContain(
      'image src: "https://cdn.example.com/wrong.png" != "https://cdn.example.com/cover.png"',
    )
  })

  it('reds a video mutant that looks right but has no handoff target', () => {
    const verdict = mobileStructuralVerdict(
      goldens[2]!,
      <View>
        <Image source={{ uri: 'https://ex.com/demo-poster.jpg' }} />
        <Text>▶ Video · 1 caption track · open in browser</Text>
      </View>,
    )
    expect(verdict?.diff).toContain('video handoff count: 0 != 1')
  })

  it('reds a video mutant that drops the canonical caption-track evidence', () => {
    const verdict = mobileStructuralVerdict(
      goldens[2]!,
      <Pressable onPress={() => undefined}>
        <Image source={{ uri: 'https://ex.com/demo-poster.jpg' }} />
        <Text>▶ Video · open in browser</Text>
      </Pressable>,
      observePressTarget,
    )
    expect(verdict?.diff).toContain('video: missing 1 caption track')
  })

  it('reds a video mutant whose handoff targets a different URL', () => {
    const verdict = mobileStructuralVerdict(
      goldens[2]!,
      <Pressable onPress={() => Linking.openURL('https://ex.com/wrong.mp4')}>
        <Image source={{ uri: 'https://ex.com/demo-poster.jpg' }} />
        <Text>▶ Video · 1 caption track · open in browser</Text>
      </Pressable>,
      observePressTarget,
    )
    expect(verdict?.diff).toContain(
      'video handoff target: "https://ex.com/wrong.mp4" != "https://ex.com/demo.mp4"',
    )
  })
})
