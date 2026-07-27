// core-container family — the container band of react's core family (charter
// D49): section, columns, terminal, steps, expandable, toc, action. Containers
// recurse through renderBlockNative, forwarding ctx WHOLESALE (D50 — a
// re-minted ctx literal would silently drop the register).
//
// Metro TDZ law (D49): this module imports renderBlockNative ONLY — never
// BLOCK_RENDERERS, which is a const assembled from spreads and therefore
// undefined while the family modules evaluate.
import type { ReactNode } from 'react'
import { Linking, Text, View } from 'react-native'

import { roles, scale } from '../../../ui/typography'
import { asList, isMap, num, openableUrl, str, type Block } from '../model'
import { MONO, type Render } from '../register'
import { renderBlockNative } from '../registry'

/* section / columns / terminal — containers; phone width stacks children */

const section: Render = (b, ctx, key) => {
  const blocks = asList<Block>(b.blocks)
  const title = b.title != null ? str(b.title) : ''
  return (
    <View key={key} style={{ marginVertical: 10 }}>
      <View style={{ height: 1, backgroundColor: ctx.theme.border, marginBottom: 8 }} />
      {title !== '' && (
        <Text style={{ ...scale.md, fontWeight: '700', color: ctx.theme.text, marginBottom: 4 }}>
          {title}
        </Text>
      )}
      {blocks.map((child, i) => renderBlockNative(child, ctx, i))}
      <View style={{ height: 1, backgroundColor: ctx.theme.border, marginTop: 8 }} />
    </View>
  )
}

// Columns stack VERTICALLY on a phone — the grid geometry is a wide-surface
// affordance; the traversal (each column's blocks recursed in order) is what
// the reference law prescribes.
const columns: Render = (b, ctx, key) => {
  const cols = asList(b.columns)
  return (
    <View key={key} style={{ marginVertical: 6, gap: 8 }}>
      {cols.map((col, i) => (
        <View key={i}>{asList<Block>(col).map((child, ci) => renderBlockNative(child, ctx, ci))}</View>
      ))}
    </View>
  )
}

const terminal: Render = (b, ctx, key) => {
  const title = str(b.title)
  const footer = str(b.footer)
  const kids = asList<Block>(b.children ?? b.blocks)
  return (
    <View key={key} style={{ borderRadius: 8, overflow: 'hidden', marginVertical: 10, backgroundColor: '#15211d' }}>
      <View style={{ flexDirection: 'row', alignItems: 'center', padding: 8, gap: 8, backgroundColor: '#0c1512' }}>
        {/* The terminal frame is ALWAYS dark, in both app themes — the hexes
            below are that constant, not theme drift. They stay hand-written:
            S1 minted no theme role for an always-dark chrome, so routing them
            through `theme.*` would make them follow the app theme and break
            the frame. Only the type moves onto tokens here. */}
        <Text style={{ ...scale.xs, color: '#55635e' }}>●●●</Text>
        {title !== '' && <Text style={{ ...scale.xs, color: '#93a198', fontFamily: MONO }}>{title}</Text>}
      </View>
      <View style={{ padding: 10 }}>
        {kids.map((child, i) =>
          renderBlockNative(child, ctx, i),
        )}
      </View>
      {footer !== '' && (
        <Text style={{ ...scale.micro, color: '#93a198', padding: 8, paddingTop: 0 }}>{footer}</Text>
      )}
    </View>
  )
}

/* steps — numbered procedure, blocks recursed */

const steps: Render = (b, ctx, key) => {
  const rows = asList(b.steps).filter(isMap)
  if (rows.length === 0) return null
  return (
    <View key={key} style={{ marginVertical: 6, gap: 10 }}>
      {rows.map((s, i) => {
        const title = str(s.title)
        const blocks = asList<Block>(s.blocks ?? s.children)
        if (title === '' && blocks.length === 0) return null
        return (
          <View key={i} style={{ flexDirection: 'row', gap: 10 }}>
            <Text style={{ ...scale.md, fontWeight: '700', color: ctx.theme.accent, minWidth: 22 }}>
              {i + 1}.
            </Text>
            <View style={{ flex: 1 }}>
              {title !== '' && (
                <Text style={{ ...scale.md, fontWeight: '700', color: ctx.theme.text }}>{title}</Text>
              )}
              {blocks.map((child, ci) => renderBlockNative(child, ctx, ci))}
            </View>
          </View>
        )
      })}
    </View>
  )
}

/* expandable — summary + children, rendered OPEN (the reference's no-JS
 * degrade posture: every panel visible; v1 ships no collapse interaction) */

const expandable: Render = (b, ctx, key) => {
  const summary = str(b.summary)
  const blocks = asList<Block>(b.blocks ?? b.children)
  if (summary === '' && blocks.length === 0) return null
  return (
    <View
      key={key}
      style={{
        borderWidth: 1,
        borderColor: ctx.theme.border,
        borderRadius: 8,
        padding: 12,
        marginVertical: 8,
        backgroundColor: ctx.theme.surface,
      }}
    >
      {summary !== '' && (
        <Text style={{ ...scale.base, fontWeight: '700', color: ctx.theme.text, marginBottom: 4 }}>
          {summary}
        </Text>
      )}
      {blocks.map((child, i) => renderBlockNative(child, ctx, i))}
    </View>
  )
}

/* toc — static author-supplied outline (items/depth/numbered) */

interface TocItem {
  text: string
  level: number
}

function tocItems(raw: unknown): TocItem[] {
  const out: TocItem[] = []
  for (const it of asList(raw)) {
    if (!isMap(it)) continue
    const text = str(it.text)
    if (text === '') continue
    const n = num(it.level)
    out.push({ text, level: n !== undefined ? n : 1 })
  }
  return out
}

const toc: Render = (b, ctx, key) => {
  const items = tocItems(b.items)
  if (items.length === 0) return null
  const depthRaw = num(b.depth)
  const depth = depthRaw !== undefined ? depthRaw : 2
  const numbered = b.numbered === true
  const minLevel = Math.min(...items.map((i) => i.level))
  const counters = new Array(depth + 1).fill(0) as number[]
  const rows: ReactNode[] = []
  items.forEach((item, idx) => {
    const rel = item.level - minLevel + 1
    if (rel > depth) return
    counters[rel] = (counters[rel] ?? 0) + 1
    for (let lvl = rel + 1; lvl <= depth; lvl++) counters[lvl] = 0
    const prefix = numbered ? counters.slice(1, rel + 1).join('.') + '. ' : ''
    rows.push(
      <Text
        key={idx}
        style={{
          ...roles.tocRow,
          color: ctx.theme.accent,
          paddingLeft: (rel - 1) * 16,
        }}
      >
        {prefix + item.text}
      </Text>,
    )
  })
  return (
    <View
      key={key}
      style={{
        borderWidth: 1,
        borderColor: ctx.theme.border,
        borderRadius: 8,
        padding: 12,
        marginVertical: 10,
        backgroundColor: ctx.theme.surface,
      }}
    >
      {rows}
    </View>
  )
}

/* action — a tappable link button. It LOOKED tappable and was not: the renderer
 * dropped `href` entirely, so every action block shipped as a dead underlined
 * label. The href now opens through Linking behind the openableUrl gate — the
 * same gate and the same honest no-op catch the inline link folder uses, so an
 * unsafe/relative href still renders its label as inert accent text rather than
 * a tap target that goes nowhere. An EMPTY label still renders nothing (editor
 * scaffolding), href or no href. */

const action: Render = (b, ctx, key) => {
  const label = str(b.label)
  if (label === '') return null
  const style = {
    ...scale.md,
    color: ctx.theme.accent,
    fontWeight: '700' as const,
    textDecorationLine: 'underline' as const,
    marginVertical: 6,
  }
  const url = openableUrl(b.href)
  if (url === undefined) {
    return (
      <Text key={key} style={style}>
        {label}
      </Text>
    )
  }
  return (
    <Text
      key={key}
      accessibilityRole="link"
      style={style}
      onPress={() => {
        Linking.openURL(url).catch(() => {
          // Honest no-op: a link that cannot open must never crash the reader.
        })
      }}
    >
      {label}
    </Text>
  )
}

export const coreContainerRenderers: Record<string, Render> = {
  section,
  columns,
  terminal,
  steps,
  expandable,
  toc,
  action,
}
