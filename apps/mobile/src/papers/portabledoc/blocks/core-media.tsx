// core-media family — the media band of react's core family (charter D49):
// code, divider, image, figure, diagram, plus the two DEGRADE CARDS video and
// asciicast (D46d/D47). MermaidIsland (a WebView island) is the one stateful
// leaf, mounted as a component element the test walker treats as a leaf.
//
// Metro TDZ law (D49): this module imports `renderBlockNative` from ../registry
// (a hoisted function declaration, and only ever CALLED at render time) and
// never BLOCK_RENDERERS, which is a const assembled from spreads and therefore
// undefined while the family modules evaluate. `degradeCard` is called at THIS
// module's EVAL time — a strictly stronger requirement — so it is imported from
// ../register, which is outside the registry↔families cycle entirely.
import type { ReactNode } from 'react'
import { Image, Linking, Pressable, ScrollView, Text, View } from 'react-native'

import type { Theme } from '../../../ui/theme'
import { roles, scale } from '../../../ui/typography'
import { MermaidIsland } from '../MermaidIsland'
import { asList, num, openableUrl, str, isMap, type Block } from '../model'
import { degradeCard, MONO, type BlockCtx, type Render } from '../register'
import { renderBlockNative } from '../registry'

// The paper register frames code as a quoted passage (surface slab + accent
// rule). In chat that reads as a pulled-out card; the transcript instead wants
// a quiet code REGION, so the chat register uses the codeBg/codeFg role pair
// and drops the rule. The chrome is register-scoped — charter D22's no-chrome
// law is TURN-level, so a code block still gets to look like a code block.
//
// THE LANGUAGE HEADER (bl-frommarkdown-fence-language). The block's language
// field is `lang` — the same key `Blocks.default_block("code")` writes, the
// Studio's code editor reads and `FromMarkdown` now carries off a ```python
// fence. It is OPTIONAL and absent far more often than present, so the header
// is strictly additive:
//
//   * NO lang  → the element returned is the one this renderer has always
//     returned: the frame-styled ScrollView as the ROOT, byte-identical.
//     `rootStyle()` in chatBlocks.test.tsx reads that root's style, and the
//     register-default suite JSON-compares whole trees, so anything that
//     wrapped the no-lang case in a View would be a silent regression on both.
//   * WITH lang → the frame moves out to a wrapping View so the label can sit
//     ABOVE the scroller. It must not sit inside a horizontal ScrollView: a
//     label that scrolls away with the code is not a label, and it would also
//     ride the scroller's content width.
//
// Still ONE horizontal scroller (charter D50) — the wrapper is a plain View.
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
  const body = (
    <Text
      style={{
        ...roles.codeBlock,
        fontFamily: MONO,
        color: chat ? ctx.theme.codeFg : ctx.theme.text,
      }}
    >
      {str(b.value)}
    </Text>
  )
  // STRICT on purpose, where the rest of this module uses `str()`. `str()`
  // coerces a number, so a junk `lang: 42` would paint "42" as a language
  // label — chrome that lies. A language identifier is a string or it is
  // nothing, and anything else falls back to the untouched no-lang tree.
  const lang = typeof b.lang === 'string' ? b.lang.trim() : ''

  if (lang === '') {
    return (
      <ScrollView key={key} horizontal style={frame} contentContainerStyle={{ padding: 12 }}>
        {body}
      </ScrollView>
    )
  }

  return (
    <View key={key} style={frame}>
      <Text
        style={{
          // `scale.micro` (11/15) is the chrome ladder's smallest rung — the
          // same step the tab-bar badge uses. Hand-typing the pair here is an
          // eslint error by design (no-restricted-syntax, the S8 token guard).
          ...scale.micro,
          fontFamily: MONO,
          letterSpacing: 0.4,
          color: ctx.theme.textMuted,
          paddingHorizontal: 12,
          paddingTop: 10,
        }}
      >
        {lang}
      </Text>
      <ScrollView horizontal contentContainerStyle={{ padding: 12, paddingTop: 4 }}>
        {body}
      </ScrollView>
    </View>
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

/* ── video / asciicast — the ONLY two degrade cards (charter D46d / D47) ─────── */

// THE HONEST-CEILING DOCTRINE, quoted from the surface that wrote it down
// (hardblocks.go): a capability this surface lacks renders as "a clearly-LABELED
// box that states its ceiling — never a fake of a capability it lacks". The
// labels are the whole point: a reader must not mistake the placeholder for a
// render bug.
//
// These two are the only blocks in the mobile register that ship as a card
// ABOUT the content instead of the content, which is exactly why they are also
// the only members of DEGRADE_ONLY (registry.tsx). Read that comment before
// adding a third: a degrade card that counts as "renderable" at TURN level
// silently replaces a chat answer's full markdown with a summary.

/** A tap that opens the asset in the system browser. A URL that will not open
 * must never crash the reader (the inlines.tsx openLink precedent). */
function openInBrowser(url: string): void {
  Linking.openURL(url).catch(() => {
    // Honest no-op.
  })
}

/** attrInt's coercion (attrs.go:59) for the asciicast metadata: an integer
 * number (JSON numbers arrive as floats, so a whole float counts; a fractional
 * one does not) or an all-digit string. */
function intAttr(v: unknown): number | undefined {
  if (typeof v === 'number') return Number.isInteger(v) ? v : undefined
  if (typeof v === 'string' && /^-?\d+$/.test(v.trim())) return Number.parseInt(v, 10)
  return undefined
}

/** Whole seconds as M:SS (formatDuration's twin). */
function formatDuration(secs: number): string {
  const s = secs < 0 ? 0 : secs
  const sec = s % 60
  return `${Math.floor(s / 60)}:${sec < 10 ? '0' : ''}${sec}`
}

/** The "M:SS · COLSxROWS" suffix from whatever the block carries: a top-level
 * duration/cols/rows, or an asciicast-v2 cast `header` object
 * ({width, height, duration}) — the nested lift asciicastMeta does
 * (hardblocks.go:188-215). Returns '' when nothing is known, and the suffix is
 * then simply omitted rather than shown as zeros. A top-level 0 for cols/rows
 * (or a negative duration) reads as ABSENT and falls through to the header,
 * matching attrInt's sentinel defaults on the Go side. */
function asciicastMeta(b: Block): string {
  const header = isMap(b.header) ? b.header : {}
  const own = (v: unknown, floor: number): number | undefined => {
    const n = intAttr(v)
    return n !== undefined && n >= floor ? n : undefined
  }
  const dur = own(b.duration, 0) ?? own(header.duration, 0)
  const cols = own(b.cols, 1) ?? own(header.width, 1)
  const rows = own(b.rows, 1) ?? own(header.height, 1)

  const parts: string[] = []
  if (dur !== undefined) parts.push(formatDuration(dur))
  if (cols !== undefined && rows !== undefined) parts.push(`${cols}x${rows}`)
  return parts.join(' · ')
}

/** The shared card frame: a bordered box, optionally tinted like a terminal. */
function cardFrame(children: ReactNode, ctx: BlockCtx, terminal: boolean): ReactNode {
  return (
    <View
      style={{
        borderWidth: 1,
        borderColor: ctx.theme.border,
        borderRadius: 8,
        overflow: 'hidden',
        backgroundColor: terminal ? ctx.theme.codeBg : ctx.theme.surface,
      }}
    >
      {children}
    </View>
  )
}

// FLIP TRIGGER — expo-video. Deliberately NOT now: it is a native module, so it
// costs a dev-client rebuild and a store submission, bought for a block type the
// live corpus has zero instances of. Flip on an explicit user ask, or on the
// first `video` block appearing in a corpus census. Until then the poster IS the
// render and the tap hands off to the platform player, which is a better video
// experience than an in-app <video> would be anyway.
const video: Render = degradeCard((b, ctx, key) => {
  const src = str(b.src).trim()
  // THE PARITY LAW: a src-less video renders NOTHING — not a dashed box, not an
  // empty card. Both twins agree (react's `video` returns '', videoRenderer
  // returns nil) because an asset-less video block is editor scaffolding,
  // exactly like the asset-less `image` above.
  if (src === '') return null

  // The src resolves through the same pipeline as an image src, for the same
  // reason: root-relative `/media/files/…` is the dominant live media shape
  // (census F2). An unresolvable one still gets its card — the asset exists,
  // this client just cannot open it — but no tap target (linkText's precedent).
  const url = resolveImageSrc(src, ctx)
  const poster = resolveImageSrc(str(b.poster).trim(), ctx)
  const tracks = asList(b.captions).filter(isMap).length

  let head = '▶ Video'
  if (tracks > 0) head += ` · ${tracks} caption track${tracks === 1 ? '' : 's'}`
  // The card must state its ceiling in WORDS on both arms. Withholding "open in
  // browser" is necessary but not sufficient: with a poster resolved and no
  // label, what is left is a ▶ glyph over a 16:9 thumbnail — the universal
  // play-button idiom with every counter-signal removed — plus no Pressable, so
  // the tap is a silent no-op and the reader concludes the app is broken. The
  // `image` sibling above states the same ceiling the same way ("Image
  // unavailable: …"), as does figures.ex's degrade arm ("Watch the video").
  head += url !== undefined ? ' · open in browser' : ' · cannot be opened here'

  const card = cardFrame(
    <>
      {poster !== undefined && (
        <Image
          source={{ uri: poster }}
          accessibilityLabel={str(b.caption)}
          style={{ width: '100%', aspectRatio: 16 / 9 }}
          resizeMode="cover"
        />
      )}
      <Text style={{ ...scale.sm, color: ctx.theme.text, padding: 10 }}>{head}</Text>
    </>,
    ctx,
    false,
  )

  return (
    <View key={key} style={{ marginVertical: 12 }}>
      {url === undefined ? (
        card
      ) : (
        <Pressable accessibilityRole="button" onPress={() => openInBrowser(url)}>
          {card}
        </Pressable>
      )}
      {figcaption(str(b.caption), ctx.theme, 'cap')}
    </View>
  )
})

// FLIP TRIGGER — none. A real `.cast` player is an asciinema-player WebView
// island, and D42 ruled WebView islands out for anything but the Mermaid one
// that already exists. There is no native path, so this card IS the ceiling
// rather than a stop on the way to one.
//
// `poster` (an npt timestamp naming the frame the WEB player rests on before
// play) is therefore INERT here, by the same rule as video's `loop`: it is a
// player option, and there is no player. Unlike video's `poster` — an image URL
// this card CAN show — there is no image to resolve, only a timestamp into a
// stream nothing on this surface decodes.
const asciicast: Render = degradeCard((b, ctx, key) => {
  const src = str(b.src).trim()
  const url = resolveImageSrc(src, ctx)

  let head = '▶ Asciicast'
  const meta = asciicastMeta(b)
  if (meta !== '') head += ` · ${meta}`
  // The TUI appends "open in browser" unconditionally; withholding it when
  // there is nothing to open is the one place this leg is stricter, because on
  // a phone that phrase reads as a tap affordance rather than as a label.
  if (url !== undefined) head += ' · open in browser'

  const card = cardFrame(
    <Text style={{ ...scale.sm, fontFamily: MONO, color: ctx.theme.codeFg, padding: 10 }}>{head}</Text>,
    ctx,
    true,
  )

  return (
    // Renders EVEN src-less — the video/asciicast ASYMMETRY both twins carry,
    // preserved deliberately: asciicastRenderer reads src and then renders its
    // box unconditionally (it never returns nil the way videoRenderer does), and
    // the web emitter emits its mount div unconditionally too. A cast block
    // is authored ABOUT a recording, so its duration and dimensions are content
    // in their own right; a src-less video block carries nothing at all.
    <View key={key} style={{ marginVertical: 12 }}>
      {url === undefined ? (
        card
      ) : (
        <Pressable accessibilityRole="button" onPress={() => openInBrowser(url)}>
          {card}
        </Pressable>
      )}
      {figcaption(str(b.caption), ctx.theme, 'cap')}
    </View>
  )
})

export const coreMediaRenderers: Record<string, Render> = {
  code,
  divider,
  image,
  figure,
  diagram,
  video,
  asciicast,
}
