// core-prose family — the prose band of react's core family (charter D49):
// heading, paragraph, eyebrow, byline, ingress, pullquote, list + its four
// authoring-drift aliases, numbered_list, callout, blockquote + quote,
// footnote. Every renderer is a PURE function (no hooks) so jest can walk the
// element trees without a native host.
import { Text, View } from 'react-native'

import type { Theme } from '../../../ui/theme'
import { roles, scale } from '../../../ui/typography'
import { renderInlineNodes } from '../inlines'
import {
  asList,
  headingLevel,
  isMap,
  itemInlines,
  paragraphInline,
  str,
} from '../model'
import { bodyText, spec, type Render } from '../register'

const heading: Render = (b, ctx, key) => {
  const level = headingLevel(b)
  const s = spec(ctx).heading[level]
  return (
    <Text
      key={key}
      accessibilityRole="header"
      style={{
        fontWeight: '700',
        ...s.step,
        marginTop: s.marginTop,
        marginBottom: 6,
        color: ctx.theme.text,
      }}
    >
      {renderInlineNodes(paragraphInline(b), ctx)}
    </Text>
  )
}

const paragraph: Render = (b, ctx, key) => (
  <Text key={key} style={[bodyText(ctx), { marginVertical: 6 }]}>
    {renderInlineNodes(paragraphInline(b), ctx)}
  </Text>
)

const eyebrow: Render = (b, ctx, key) => (
  <Text
    key={key}
    style={{
      ...scale.xs,
      fontWeight: '700',
      letterSpacing: 1.2,
      textTransform: 'uppercase',
      color: ctx.theme.accent,
      marginTop: 14,
      marginBottom: 2,
    }}
  >
    {str(b.text)}
  </Text>
)

const byline: Render = (b, ctx, key) => {
  const items = b.items
  const text = Array.isArray(items) ? items.map((i) => str(i)).join(' · ') : str(b.text)
  return (
    <Text key={key} style={{ ...scale.sm, color: ctx.theme.textMuted, marginVertical: 4 }}>
      {text}
    </Text>
  )
}

const ingress: Render = (b, ctx, key) => (
  <Text
    key={key}
    style={{
      ...roles.paperIngress,
      color: ctx.theme.text,
      marginVertical: 8,
    }}
  >
    {renderInlineNodes(paragraphInline(b), ctx)}
  </Text>
)

const pullquote: Render = (b, ctx, key) => (
  <Text
    key={key}
    style={{
      ...roles.paperPullquote,
      fontStyle: 'italic',
      color: ctx.theme.text,
      marginVertical: 14,
      paddingHorizontal: 12,
      textAlign: 'center',
    }}
  >
    {renderInlineNodes(paragraphInline(b), ctx)}
  </Text>
)

const list: Render = (b, ctx, key) => {
  const ordered = b.ordered === true
  const items = asList(b.items)
  return (
    <View key={key} style={{ marginVertical: 6, gap: 4 }}>
      {items.map((item, i) => (
        <View key={i} style={{ flexDirection: 'row', paddingLeft: 8 }}>
          <Text style={[bodyText(ctx), { width: 24 }]}>{ordered ? `${i + 1}.` : '•'}</Text>
          <Text style={[bodyText(ctx), { flex: 1 }]}>
            {renderInlineNodes(itemInlines(item), ctx)}
          </Text>
        </View>
      ))}
    </View>
  )
}

const numberedList: Render = (b, ctx, key) => list({ ...b, ordered: true }, ctx, key)

/* callout */

function calloutTone(theme: Theme, tone: unknown): string {
  switch (str(tone)) {
    case 'success':
      return theme.success
    case 'warning':
      return '#c98a1b'
    case 'danger':
      return theme.danger
    case 'neutral':
      return theme.textMuted
    default:
      return theme.accent // info
  }
}

const callout: Render = (b, ctx, key) => {
  const tone = calloutTone(ctx.theme, b.tone)
  const title = str(b.title)
  // A collapsible callout renders OPEN with its body visible — the same
  // posture as the reference's no-JS degrade (every panel visible pre-
  // hydration); v1 mobile ships no collapse interaction.
  return (
    <View
      key={key}
      style={{
        borderLeftWidth: 3,
        borderLeftColor: tone,
        backgroundColor: ctx.theme.surface,
        borderRadius: 6,
        padding: 12,
        marginVertical: 8,
      }}
    >
      {title !== '' && (
        <Text style={{ ...scale.base, fontWeight: '700', color: ctx.theme.text, marginBottom: 4 }}>
          {title}
        </Text>
      )}
      <Text style={[bodyText(ctx), roles.calloutBody]}>
        {renderInlineNodes(paragraphInline(b), ctx)}
      </Text>
    </View>
  )
}

/* blockquote / quote — content||text body + cite */

const blockquote: Render = (b, ctx, key) => {
  const cite = str(b.cite) || str(b.attribution)
  return (
    <View
      key={key}
      style={{
        borderLeftWidth: 3,
        borderLeftColor: ctx.theme.border,
        paddingLeft: 14,
        marginVertical: 10,
      }}
    >
      <Text style={[bodyText(ctx), { fontStyle: 'italic' }]}>
        {renderInlineNodes(paragraphInline(b), ctx)}
      </Text>
      {cite !== '' && (
        <Text style={{ ...scale.sm, color: ctx.theme.textMuted, marginTop: 4 }}>— {cite}</Text>
      )}
    </View>
  )
}

/* footnote — numbered reference apparatus */

const footnote: Render = (b, ctx, key) => {
  const rows = asList(b.notes)
    .filter(isMap)
    .filter((n) => str(n.text) !== '')
  if (rows.length === 0) return null
  return (
    <View key={key} style={{ marginVertical: 8, gap: 4 }}>
      {rows.map((n, i) => (
        <View key={i} style={{ flexDirection: 'row', gap: 8 }}>
          <Text style={{ ...scale.xs, color: ctx.theme.textMuted, marginTop: 2 }}>{i + 1}.</Text>
          <Text style={{ flex: 1, ...scale.sm, color: ctx.theme.textMuted }}>
            {str(n.text)}
          </Text>
        </View>
      ))}
    </View>
  )
}

export const coreProseRenderers: Record<string, Render> = {
  heading,
  paragraph,
  eyebrow,
  byline,
  ingress,
  pullquote,
  list,
  // authoring-drift aliases (the compose.ex / blocks/core.ts choke point)
  bulletList: list,
  bullet_list: list,
  'bulleted-list': list,
  bulleted_list: list,
  numbered_list: numberedList,
  callout,
  blockquote,
  quote: blockquote,
  footnote,
}
