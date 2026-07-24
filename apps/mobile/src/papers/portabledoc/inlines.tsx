// Inline renderer — the RN sibling of js/packages/react/src/inline.tsx's
// renderInline/renderInlines/applyMarks, emitting nested <Text> runs instead
// of HTML strings. Traversal semantics mirror the reference:
//
//   • a bare string/number leaf renders as plain text (no extra wrapper),
//   • `text` nodes fold their marks right-to-left (first mark outermost),
//   • `code` marks are leaf-only (only wrap still-bare text),
//   • unknown marks pass through unwrapped, unknown inline nodes degrade to
//     their children (else nothing) — the apply_mark / renderInline
//     catch-alls,
//   • links tap-open via Linking, gated by openableUrl (the safeUrl twin);
//     an unsafe href renders the label as plain accent text, never a tap.
//
// Everything here is a PURE function returning ReactNodes — no hooks — so the
// jest suite can walk rendered trees without a native host.
import type { ReactNode } from 'react'
import { Linking, Text, type StyleProp, type TextStyle } from 'react-native'

import type { Theme } from '../../ui/theme'
import { asList, isMap, markAttr, markName, openableUrl, str, type Inline } from './model'

export interface InlineCtx {
  theme: Theme
}

const MONO_FONT = 'monospace' // Android; the reader is Android-first (bpspike)

function codeStyle(theme: Theme): TextStyle {
  return {
    fontFamily: MONO_FONT,
    fontSize: 13,
    backgroundColor: theme.surface,
    color: theme.text,
  }
}

function openLink(url: string): void {
  Linking.openURL(url).catch(() => {
    // Honest no-op: a link that cannot open must never crash the reader.
  })
}

function linkText(key: number | string, href: string, label: ReactNode, theme: Theme): ReactNode {
  const url = openableUrl(href)
  const style: StyleProp<TextStyle> = { color: theme.accent, textDecorationLine: 'underline' }
  if (url === undefined) {
    // Unsafe/relative href: label stays visible (never vanishes), not tappable.
    return (
      <Text key={key} style={style}>
        {label}
      </Text>
    )
  }
  return (
    <Text key={key} style={style} onPress={() => openLink(url)}>
      {label}
    </Text>
  )
}

/** Fold a mark list around a rendered leaf, right-to-left so the FIRST mark
 * ends up outermost — mirrors inline.tsx applyMarks. */
function applyMarks(key: number, leaf: ReactNode, marks: unknown[], theme: Theme): ReactNode {
  let acc = leaf
  let bare = true // code is leaf-only, per the reference apply_mark
  for (let i = marks.length - 1; i >= 0; i--) {
    const m = marks[i]
    switch (markName(m)) {
      case 'bold':
      case 'strong':
        acc = (
          <Text key={key} style={{ fontWeight: 'bold' }}>
            {acc}
          </Text>
        )
        bare = false
        break
      case 'italic':
      case 'em':
        acc = (
          <Text key={key} style={{ fontStyle: 'italic' }}>
            {acc}
          </Text>
        )
        bare = false
        break
      case 'underline':
        acc = (
          <Text key={key} style={{ textDecorationLine: 'underline' }}>
            {acc}
          </Text>
        )
        bare = false
        break
      case 'strike':
      case 's':
      case 'strikethrough':
        acc = (
          <Text key={key} style={{ textDecorationLine: 'line-through' }}>
            {acc}
          </Text>
        )
        bare = false
        break
      case 'code':
        if (bare) {
          acc = (
            <Text key={key} style={codeStyle(theme)}>
              {acc}
            </Text>
          )
          bare = false
        }
        break
      case 'link':
        acc = linkText(key, markAttr(m, 'href'), acc, theme)
        bare = false
        break
      default:
        // Unknown mark passes through with no wrapper (apply_mark catch-all).
        break
    }
  }
  return acc
}

/** Render one inline node. Mirrors inline.tsx renderInline's dispatch. */
export function renderInlineNode(node: Inline, ctx: InlineCtx, key: number): ReactNode {
  if (typeof node === 'string') return node
  if (typeof node === 'number') return String(node)
  if (!isMap(node)) return null

  const theme = ctx.theme
  switch (str(node.type)) {
    case 'text': {
      const value = str(node.value)
      const marks = asList(node.marks)
      return marks.length ? applyMarks(key, value, marks, theme) : value
    }
    case 'strong':
    case 'bold':
      return (
        <Text key={key} style={{ fontWeight: 'bold' }}>
          {renderInlineNodes(node.children, ctx)}
        </Text>
      )
    case 'em':
    case 'italic':
      return (
        <Text key={key} style={{ fontStyle: 'italic' }}>
          {renderInlineNodes(node.children, ctx)}
        </Text>
      )
    case 'underline':
      return (
        <Text key={key} style={{ textDecorationLine: 'underline' }}>
          {renderInlineNodes(node.children, ctx)}
        </Text>
      )
    case 'strike':
    case 's':
    case 'strikethrough':
      return (
        <Text key={key} style={{ textDecorationLine: 'line-through' }}>
          {renderInlineNodes(node.children, ctx)}
        </Text>
      )
    case 'code':
      return (
        <Text key={key} style={codeStyle(theme)}>
          {str(node.value)}
        </Text>
      )
    case 'link':
      return linkText(key, str(node.href), renderInlineNodes(node.children, ctx), theme)
    case 'wikilink': {
      // Unresolved on mobile (no resolver): render the alias/children/target
      // label, dashed-underlined like the web's bp-wikilink--unresolved.
      const alias = str(node.alias)
      const kids = asList(node.children)
      const label: ReactNode =
        alias !== '' ? alias : kids.length ? renderInlineNodes(kids, ctx) : str(node.target)
      return (
        <Text key={key} style={{ color: theme.accent, textDecorationLine: 'underline' }}>
          {label}
        </Text>
      )
    }
    case 'blockref':
      return (
        <Text key={key} style={{ color: theme.textMuted }}>
          {'^' + str(node.anchor)}
        </Text>
      )
    case 'tag':
      return (
        <Text key={key} style={{ color: theme.accent }}>
          {'#' + str(node.name)}
        </Text>
      )
    case 'valueref': {
      // Without a resolver, mirror the reference's dangling leg: fallback text.
      const resolved = typeof node.resolved === 'string' && node.resolved !== '' ? node.resolved : undefined
      return <Text key={key}>{resolved ?? str(node.fallback)}</Text>
    }
    default: {
      // Unknown inline → degrade to its children when present, else nothing.
      const kids = asList(node.children)
      return kids.length ? renderInlineNodes(kids, ctx) : null
    }
  }
}

/** Render an inline-node array (or scalar) to ReactNodes — the renderInlines
 * twin. Callers place the result inside a styled <Text> block. */
export function renderInlineNodes(nodes: unknown, ctx: InlineCtx): ReactNode {
  if (typeof nodes === 'string') return nodes
  if (typeof nodes === 'number') return String(nodes)
  if (!Array.isArray(nodes)) return null
  return nodes.map((n, i) => renderInlineNode(n as Inline, ctx, i))
}
