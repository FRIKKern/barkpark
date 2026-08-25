// Related Paper cards — authored fallbacks work offline; `_paper_links` accepts
// the same transient live metadata the web reader resolves at read time.
import { Linking, Pressable, Text, View } from 'react-native'

import { scale } from '../../../ui/typography'
import { asList, isMap, openableUrl, str } from '../model'
import { bodyText, type Render } from '../register'

interface PaperLinkRef {
  slug: string
  title: string
  description: string
  reason: string
  metadata: string
}

function clean(v: unknown): string {
  return str(v).trim()
}

function paperLinkRef(raw: unknown, resolved: Record<string, unknown>): PaperLinkRef | undefined {
  const authored = typeof raw === 'string' ? { slug: raw } : isMap(raw) ? raw : undefined
  if (authored === undefined) return undefined
  const slug = clean(authored.slug)
  if (!/^[a-z0-9][a-z0-9-]*$/.test(slug)) return undefined

  const live = isMap(resolved[slug]) ? resolved[slug] : {}
  const description = clean(live.description) || clean(authored.description)
  const reason = clean(authored.reason)
  const eventType = clean(live.event_type).replaceAll('_', ' ')
  const rev = clean(live.rev)

  return {
    slug,
    title: clean(live.title) || clean(authored.title) || slug,
    description,
    reason: reason.toLowerCase() === description.toLowerCase() ? '' : reason,
    metadata: [eventType, rev === '' ? '' : `revision ${rev}`].filter(Boolean).join(' · '),
  }
}

function paperLinkUrl(slug: string, serverBase: string | undefined): string | undefined {
  const base = clean(serverBase).replace(/\/+$/, '')
  if (base === '') return undefined
  return openableUrl(`${base}/papers/${slug}`)
}

const paperLinks: Render = (b, ctx, key) => {
  const resolved = isMap(b._paper_links) ? b._paper_links : {}
  const refs = asList(b.refs)
    .map((ref) => paperLinkRef(ref, resolved))
    .filter((ref): ref is PaperLinkRef => ref !== undefined)
  if (refs.length === 0) return null

  const title = clean(b.title) || 'Explore the work'
  const description = clean(b.description)

  return (
    <View key={key} style={{ marginTop: 20, paddingTop: 14, borderTopWidth: 1, borderTopColor: ctx.theme.border }}>
      <Text style={{ ...scale.lg, fontWeight: '700', color: ctx.theme.text }}>{title}</Text>
      {description !== '' && (
        <Text style={{ ...bodyText(ctx), color: ctx.theme.textMuted, marginTop: 5 }}>{description}</Text>
      )}
      <View style={{ gap: 10, marginTop: 12 }}>
        {refs.map((ref) => {
          const url = paperLinkUrl(ref.slug, ctx.serverBase)
          const content = (
            <View
              style={{
                padding: 14,
                borderWidth: 1,
                borderLeftWidth: 3,
                borderColor: ctx.theme.border,
                borderLeftColor: ctx.theme.accent,
                borderRadius: 9,
                backgroundColor: ctx.theme.surface,
              }}
            >
              <Text style={{ ...scale.md, fontWeight: '700', color: ctx.theme.accent }}>{ref.title}</Text>
              {ref.description !== '' && <Text style={{ ...bodyText(ctx), marginTop: 5 }}>{ref.description}</Text>}
              {ref.reason !== '' && (
                <Text style={{ ...scale.sm, color: ctx.theme.textMuted, marginTop: 5 }}>{ref.reason}</Text>
              )}
              {ref.metadata !== '' && (
                <Text style={{ ...scale.micro, color: ctx.theme.textMuted, marginTop: 8 }}>{ref.metadata}</Text>
              )}
            </View>
          )

          if (url === undefined) return <View key={ref.slug}>{content}</View>
          return (
            <Pressable
              key={ref.slug}
              accessibilityRole="link"
              accessibilityLabel={`Open ${ref.title}`}
              onPress={() => {
                Linking.openURL(url).catch(() => {
                  // Honest no-op: a link that cannot open must not crash the reader.
                })
              }}
            >
              {content}
            </Pressable>
          )
        })}
      </View>
    </View>
  )
}

export const paperLinkRenderers: Record<string, Render> = {
  'paper-links': paperLinks,
}
