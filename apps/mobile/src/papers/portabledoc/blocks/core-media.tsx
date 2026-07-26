// core-media family — the media band of react's core family (charter D49):
// code, divider, image, figure, diagram. MermaidIsland (a WebView island) is
// the one stateful leaf, mounted as a component element the test walker
// treats as a leaf.
//
// Metro TDZ law (D49): this module imports renderBlockNative ONLY — never
// BLOCK_RENDERERS, which is a const assembled from spreads and therefore
// undefined while the family modules evaluate.
import type { ReactNode } from 'react'
import { Image, ScrollView, Text, View } from 'react-native'

import type { Theme } from '../../../ui/theme'
import { roles, scale } from '../../../ui/typography'
import { MermaidIsland } from '../MermaidIsland'
import { num, openableUrl, str, isMap, type Block } from '../model'
import { MONO, type BlockCtx, type Render } from '../register'
import { renderBlockNative } from '../registry'

// The paper register frames code as a quoted passage (surface slab + accent
// rule). In chat that reads as a pulled-out card; the transcript instead wants
// a quiet code REGION, so the chat register uses the codeBg/codeFg role pair
// and drops the rule. The chrome is register-scoped — charter D22's no-chrome
// law is TURN-level, so a code block still gets to look like a code block.
const code: Render = (b, ctx, key) => {
  const chat = (ctx.register ?? 'paper') === 'chat'
  const frame = chat
    ? { backgroundColor: ctx.theme.codeBg, borderRadius: 8, marginVertical: 10 }
    : {
        backgroundColor: ctx.theme.surface,
        borderLeftWidth: 3,
        borderLeftColor: ctx.theme.accent,
        marginVertical: 10,
      }
  return (
    <ScrollView key={key} horizontal style={frame} contentContainerStyle={{ padding: 12 }}>
      <Text
        style={{
          ...roles.codeBlock,
          fontFamily: MONO,
          color: chat ? ctx.theme.codeFg : ctx.theme.text,
        }}
      >
        {str(b.value)}
      </Text>
    </ScrollView>
  )
}

const divider: Render = (_b, ctx, key) => (
  <View key={key} style={{ alignItems: 'center', marginVertical: 18 }}>
    <View style={{ height: 1, alignSelf: 'stretch', backgroundColor: ctx.theme.border }} />
    <Text style={{ marginTop: -11, backgroundColor: ctx.theme.bg, paddingHorizontal: 10, color: ctx.theme.textMuted }}>
      §
    </Text>
  </View>
)

/** Resolve an image src to a fetchable absolute URL: absolute http(s) passes
 * the openableUrl gate; root-relative `/…` (the DOMINANT live shape, F2)
 * resolves against ctx.serverBase; protocol-relative `//host` and every other
 * scheme are rejected (mirrors the reference safeUrl's `//` rejection). */
function resolveImageSrc(src: string, ctx: BlockCtx): string | undefined {
  const absolute = openableUrl(src)
  if (absolute !== undefined && /^https?:/i.test(absolute)) return absolute
  if (src.startsWith('/') && !/^\/[/\\]/.test(src)) {
    const base = (ctx.serverBase ?? '').trim().replace(/\/+$/, '')
    if (base !== '' && /^https?:\/\//i.test(base)) return base + src
  }
  return undefined
}

const image: Render = (b, ctx, key) => {
  const src = str(b.src).trim()
  if (src === '') return null // asset-less image = editor scaffolding, skip on read
  const uri = resolveImageSrc(src, ctx)
  if (uri === undefined) {
    // Unresolvable (no server base, or unsafe scheme): labeled placeholder,
    // never null — the image must not silently vanish (F2).
    return (
      <View
        key={key}
        style={{
          borderWidth: 1,
          borderStyle: 'dashed',
          borderColor: ctx.theme.border,
          borderRadius: 6,
          padding: 10,
          marginVertical: 8,
        }}
      >
        <Text numberOfLines={3} style={{ ...scale.xs, color: ctx.theme.textMuted, fontStyle: 'italic' }}>
          Image unavailable: {src}
        </Text>
      </View>
    )
  }
  const w = num(b.width)
  const h = num(b.height)
  const ratio = w !== undefined && h !== undefined ? w / h : 16 / 9
  return (
    <Image
      key={key}
      source={{ uri }}
      accessibilityLabel={str(b.alt)}
      style={{ width: '100%', aspectRatio: ratio, borderRadius: 6, marginVertical: 8 }}
      resizeMode="contain"
    />
  )
}

/* figure / diagram — captions share the "Figure N." bold run-in law */

function figcaption(caption: string, theme: Theme, key: string | number): ReactNode {
  if (caption === '') return null
  const m = /^(Figure\s+\S+?\.)\s*([\s\S]*)$/.exec(caption)
  return (
    <Text key={key} style={{ ...scale.sm, fontStyle: 'italic', color: theme.textMuted, marginTop: 6 }}>
      {m ? (
        <>
          <Text style={{ fontWeight: '700' }}>{m[1]}</Text>
          {m[2] !== '' ? ' ' + m[2] : ''}
        </>
      ) : (
        caption
      )}
    </Text>
  )
}

const figure: Render = (b, ctx, key) => {
  const child = b.child
  return (
    <View key={key} style={{ marginVertical: 12 }}>
      {isMap(child) ? renderBlockNative(child as Block, ctx, 0) : null}
      {figcaption(str(b.caption), ctx.theme, 'cap')}
    </View>
  )
}

const diagram: Render = (b, ctx, key) => (
  <View key={key} style={{ marginVertical: 12 }}>
    <MermaidIsland source={str(b.source)} theme={ctx.theme} />
    {figcaption(str(b.caption), ctx.theme, 'cap')}
  </View>
)

export const coreMediaRenderers: Record<string, Render> = {
  code,
  divider,
  image,
  figure,
  diagram,
}
