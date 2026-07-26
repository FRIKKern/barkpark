// Inline renderer — the RN sibling of js/packages/react/src/inline.tsx's
// renderInline/renderInlines/applyMarks, emitting nested <Text> runs instead
// of HTML strings. Traversal semantics mirror the reference:
//
//   • a bare string/number leaf renders as plain text (no extra wrapper),
//   • `text` nodes fold their marks right-to-left (first mark outermost),
//   • a bare ARRAY inline node recurses into its children (the shallow
//     `content: [[{text…}]]` authoring shape),
//   • `code` marks are leaf-only (only wrap still-bare text), and a `code`
//     NODE is a text leaf — `value` or its children flattened to plain text,
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
import { scale } from '../../ui/typography'
import { asList, isMap, markAttr, markName, openableUrl, str, type Inline } from './model'

/** Which typographic voice the same tree speaks in. `paper` is the reader's
 * serif document register; `chat` is the transcript's sans register (charter
 * D22). Declared HERE rather than in blocks.tsx so inline styling can be
 * register-aware without a module cycle; blocks.tsx re-exports it, so every
 * existing `import { BlockRegister } from './blocks'` still resolves. */
export type BlockRegister = 'paper' | 'chat'

export interface InlineCtx {
  theme: Theme
  /** Defaults to 'paper'. */
  register?: BlockRegister
}

const MONO_FONT = 'monospace' // Android; the reader is Android-first (bpspike)

/**
 * Inline `code` runs. The register matters: on the PAPER surface a code span
 * sits on the reader's page and `surface` (#ffffff on the light page) reads as
 * a raised chip. In a CHAT turn the same #ffffff lands on the transcript
 * background and the span goes near-invisible — while fenced code two lines
 * below paints on `codeBg` (#eef1ef). Threading the register makes the inline
 * span agree with the fence: ONE code surface per register, not two.
 *
 * Exported so the register binding is REACHABLE by jest — inlined in the mark
 * folder it would be unpinnable.
 */
export function inlineCodeStyle(ctx: InlineCtx): TextStyle {
  const chat = (ctx.register ?? 'paper') === 'chat'
  const theme = ctx.theme
  return {
    fontFamily: MONO_FONT,
    // NESTED RUN: size only, no lead. An inline code span lives inside a
    // paragraph — giving it its own lineHeight would fight the paragraph's
    // line box and make prose containing code jump. `sm.fontSize` is the
    // token; the lead stays the parent's.
    fontSize: scale.sm.fontSize,
    backgroundColor: chat ? theme.codeBg : theme.surface,
    color: chat ? theme.codeFg : theme.text,
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
function applyMarks(key: number, leaf: ReactNode, marks: unknown[], ctx: InlineCtx): ReactNode {
  const theme = ctx.theme
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
            <Text key={key} style={inlineCodeStyle(ctx)}>
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

/** Flatten an inline subtree to its concatenated PLAIN text — the inlineText
 * twin (inline.tsx:389). Used by the `code` leaf, whose children fold to text
 * rather than to nested markup. */
function inlineText(nodes: unknown): string {
  if (typeof nodes === 'string' || typeof nodes === 'number') return String(nodes)
  if (!Array.isArray(nodes)) return ''
  return nodes.map((n) => (isMap(n) ? str(n.value) || inlineText(n.children) : inlineText(n))).join('')
}

/** Render one inline node. Mirrors inline.tsx renderInline's dispatch. */
export function renderInlineNode(node: Inline, ctx: InlineCtx, key: number): ReactNode {
  if (typeof node === 'string') return node
  if (typeof node === 'number') return String(node)
  // A bare ARRAY where an inline node was expected (`content: [[{text…}]]` —
  // flattened one level too shallow by an upstream author path). react wraps it
  // in a span and recurses (inline.tsx:407) and Elixir composes it into a
  // PdText (inline.ex:186 `compose_inline(l) when is_list(l)`); RN returned
  // null and the text VANISHED. Recurse into the array inside a keyed <Text>,
  // the RN equivalent of the reference's bare wrapper span.
  if (Array.isArray(node)) {
    return <Text key={key}>{renderInlineNodes(node, ctx)}</Text>
  }
  if (!isMap(node)) return null

  const theme = ctx.theme
  switch (str(node.type)) {
    case 'text': {
      const value = str(node.value)
      const marks = asList(node.marks)
      return marks.length ? applyMarks(key, value, marks, ctx) : value
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
      // Inline code is a TEXT leaf (inline.tsx:435): an author-persisted
      // `children` shape with no flat `value` folds to its CONCATENATED text,
      // never to nested markup — so a bold child inside a code span stays plain
      // monospace, exactly as the `value` path renders. `value` still wins.
      return (
        <Text key={key} style={inlineCodeStyle(ctx)}>
          {str(node.value) || inlineText(node.children)}
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
