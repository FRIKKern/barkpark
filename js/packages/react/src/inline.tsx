// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Type-keyed PortableDocument renderer — the shared inline + helper core.
//
// This is the canonical JS twin of Phoenix's `Barkpark.PortableDoc.Render`
// string-emitter family (`walk.ex` / `compose.ex` / `inline.ex`). Like those,
// every function here returns an HTML **string**: the renderer is a pure string
// emitter (no React elements, no hooks, no context) so its DOM shape can be held
// byte/shape-faithful to the Elixir + Go renderers by the cross-surface golden
// harness (charter D9/D10). `PortableDoc.tsx` wraps the joined block strings in a
// single `.bp-paper-surface` container via `dangerouslySetInnerHTML` — exactly the
// escape-hatch model `walk.ex` uses for its `_raw` nodes. Every author-supplied
// string flows through `escapeHtml` / `escapeAttr` / `safeUrl`, the same security
// posture as the Elixir renderer.
//
// This module owns the whole renderer tree's SHARED spine — escaping, coercion,
// the status ladder (D15), and inline-mark rendering (D4) — so the per-family
// block modules under `./blocks/` and the `PortableDoc` dispatcher never conflict
// over it.

/* ── the type-keyed AST (Barkpark's own block grammar, NOT Sanity PortableText) ── */

export type Inline = string | number | ({ type: string } & Record<string, unknown>)

export type Block = { type: string } & Record<string, unknown>

/* ── escaping (mirrors Render.Util.escape_html/escape_attr/safe_url) ──────────── */

/** Escape the five HTML-significant chars in EXACT order `& < > " '` (ampersand
 * first so entities never double-escape). Non-string → "" (fail-soft twin). */
export function escapeHtml(s: unknown): string {
  if (typeof s === 'number') s = String(s)
  if (typeof s !== 'string') return ''
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}

/** Attribute escape — same rule as escapeHtml (Render.Util.escape_attr). */
export const escapeAttr = escapeHtml

const ALLOWED_SCHEME = /^(?:https?|mailto|tel):/i
const IN_DOC = /^(#|\?|\.\/|\.\.\/)/

/** Return the URL attribute-escaped if safe to emit, else `#` — a faithful port
 * of `Render.Util.safe_url/1` (twin of web/lib/safe-href.ts & pdrender sanitizeURL).
 * Permitted: allowlisted scheme, root-relative `/…` (NOT protocol-relative
 * `//host`), or scheme-less in-doc `#`/`?`/`./`/`../` forms. */
export function safeUrl(href: unknown): string {
  if (typeof href !== 'string') return '#'
  // Strip leading ASCII control/whitespace (browser tolerance for `\tjavascript:`).
  const trimmed = href.replace(/^[\x00-\x20]+/, '')
  if (trimmed.startsWith('/')) {
    // Reject protocol-relative `//host` (and `/\host`).
    return /^\/[/\\]/.test(trimmed) ? '#' : escapeAttr(trimmed)
  }
  if (ALLOWED_SCHEME.test(trimmed)) return escapeAttr(trimmed)
  if (IN_DOC.test(trimmed)) return escapeAttr(trimmed)
  return '#'
}

/* ── scalar coercion (mirrors Compose.stringish / Inline.coerce_text_value) ───── */

export function str(v: unknown): string {
  if (typeof v === 'string') return v
  if (typeof v === 'number' && Number.isFinite(v)) return String(v)
  return ''
}

/** A text leaf's payload, dual-read `value` || legacy `text`: raw mutate
 * writers persisted text leaves keyed {"type":"text","text":…}, and the Hollow
 * predicate counts BOTH spellings as content — so every reader of the leaf must
 * agree or such a paper renders (or suppresses) as structure with zero prose.
 * Twins: inline.ex compose_inline, pdrender inline.go attrStrFirst. */
export function textLeafValue(n: Record<string, unknown>): string {
  return str(n.value) || str(n.text)
}

/** Positive finite number from a number or numeric string, else undefined. */
export function num(v: unknown): number | undefined {
  if (typeof v === 'number') return Number.isFinite(v) && v > 0 ? v : undefined
  if (typeof v === 'string') {
    const n = Number.parseFloat(v)
    return Number.isFinite(n) && n > 0 ? n : undefined
  }
  return undefined
}

export function asList<T = unknown>(v: unknown): T[] {
  return Array.isArray(v) ? (v as T[]) : []
}

export function isMap(v: unknown): v is Record<string, unknown> {
  return !!v && typeof v === 'object' && !Array.isArray(v)
}

/* ── the status ladder (white ladder) — D15 ───────────────────────────────────
 *
 * HAND-COPIED from design/status-manifest.json (the ONE source of truth). The
 * Elixir side (Render.StatusVocab) inlines the manifest at compile time so it
 * cannot drift; this JS copy CAN. DRIFT RISK: if a role/glyph/label/meaning is
 * added or changed in design/status-manifest.json, update this table in lockstep.
 * A later wave wires a manifest→JS generator + drift guard (charter D15 backlog
 * child); until then this comment IS the guard. `scripts/status-manifest-check.sh`
 * gates the Elixir/CSS surfaces against the manifest — extend it to this file. */

export interface StatusRole {
  role: string
  glyph: string
  spinner: boolean
  label: string
  meaning: string
}

export const STATUS_ROLES: StatusRole[] = [
  { role: 'open', glyph: '○', spinner: false, label: 'open', meaning: 'backlog — not ready yet' },
  {
    role: 'ready',
    glyph: '○',
    spinner: false,
    label: 'ready',
    meaning: 'unchecked — claim it now',
  },
  {
    role: 'progress',
    glyph: '',
    spinner: true,
    label: 'in progress',
    meaning: 'being worked right now',
  },
  {
    role: 'blocked',
    glyph: '!',
    spinner: false,
    label: 'blocked',
    meaning: 'something is required first',
  },
  { role: 'done', glyph: '✓', spinner: false, label: 'done', meaning: 'complete' },
  {
    role: 'cancel',
    glyph: '✕',
    spinner: false,
    label: 'cancelled',
    meaning: 'abandoned or superseded',
  },
  // ── thought states (task-lifecycle-visibility): a task is contemplated before
  // it is ever ready. Dim, glyph-only, at the tail of the ladder. `considering` =
  // a candidate the strategizer named; `researching` = under investigation.
  {
    role: 'considering',
    glyph: '◌', // U+25CC dotted circle — a candidate, not yet committed
    spinner: false,
    label: 'considering',
    meaning: 'a candidate being weighed',
  },
  {
    role: 'researching',
    glyph: '◎', // U+25CE bullseye — under investigation before it is ready
    spinner: false,
    label: 'researching',
    meaning: 'under active investigation',
  },
  // ── fail-open sentinel (D11): an UNRECOGNIZED non-empty status renders here —
  // a dim neutral glyph, never masquerading as the bright `open` circle. Absent/
  // empty status still defaults to `open` (see roleOf).
  {
    role: 'unknown',
    glyph: '◦', // U+25E6 white bullet — dim neutral, distinct from open's ○
    spinner: false,
    label: 'unknown',
    meaning: 'unrecognized status — shown dim until the vocabulary catches up',
  },
]

const STATUS_TO_ROLE: Record<string, string> = {
  open: 'open',
  ready: 'ready',
  in_progress: 'progress',
  blocked: 'blocked',
  done: 'done',
  closed: 'done',
  cancelled: 'cancel',
  considering: 'considering',
  researching: 'researching',
}

const DEFAULT_ROLE = 'open'
// The fail-open role for an unrecognized NON-EMPTY status (D11). Absent/empty
// stays on DEFAULT_ROLE so nothing about today's blank-status rows changes.
const UNKNOWN_ROLE = 'unknown'
const ROLE_BY_NAME: Record<string, StatusRole> = Object.fromEntries(
  STATUS_ROLES.map((r) => [r.role, r]),
)

/** The status-legend ladder — the cross-surface vocabulary KEY. Byte-frozen to
 * the Elixir StatusVocab / design/status-manifest.json (the canonical states),
 * so the react legend stays shape-equal to the Elixir golden. ONE role is held
 * OUT deliberately: the fail-open `unknown` sentinel is JS-only and NEVER a
 * real lifecycle state — so the legend is DERIVED as "everything but the
 * sentinel" rather than from a second hand-maintained role-name list (the old
 * MANIFEST_LADDER set was a duplicate of STATUS_ROLES' manifest rows, and a
 * duplicate list is a drift surface; rpu-backlog-role-ladder-drift-guard).
 * tests/status-manifest-parity.test.ts pins LEGEND_ROLES ≡ the manifest's
 * roles array — order, glyph, spinner, label, meaning.
 * Everything else (roleOf, glyphHtml, the board columns) already resolves all
 * nine roles via ROLE_BY_NAME — only the legend key is manifest-scoped. */
export const LEGEND_ROLES: StatusRole[] = STATUS_ROLES.filter((r) => r.role !== UNKNOWN_ROLE)

export function roleOf(status: unknown): string {
  const s = str(status)
  if (s === '') return DEFAULT_ROLE
  return STATUS_TO_ROLE[s] ?? UNKNOWN_ROLE
}

const DEFAULT_STATUS_ROLE: StatusRole = STATUS_ROLES[0]!

function role(name: string): StatusRole {
  return ROLE_BY_NAME[name] ?? DEFAULT_STATUS_ROLE
}

export function labelForRole(name: string): string {
  return role(name).label
}
export function meaningForRole(name: string): string {
  return role(name).meaning
}
export function glyphChar(name: string): string {
  return role(name).glyph
}
export function spinnerRole(name: string): boolean {
  return role(name).spinner
}

/** The status glyph span (Components.glyph_html/1): a spinner role is an empty
 * span whose ::before CSS-animates the Braille frames; every other role is its
 * static glyph, both keyed `bp-g bp-g--<role>`. */
export function glyphHtml(name: string): string {
  if (spinnerRole(name)) {
    return `<span class="bp-g bp-g--${name}" aria-label="${escapeHtml(labelForRole(name))}"></span>`
  }
  return `<span class="bp-g bp-g--${name}">${glyphChar(name)}</span>`
}

/* ── inline rendering (D4) ─────────────────────────────────────────────────────
 *
 * The type-keyed inline grammar folds ProseMirror-style text marks + first-class
 * inline nodes into the SAME HTML `walk.ex` emits after `inline.ex` composes them
 * into Pd nodes. Marks nest ONE `<span style=…>` per mark, first-mark-outermost
 * (matches the serializer order); `code`/`link` marks become BARE class-less
 * `<code>`/`<a>` (styled by the `.bp-paper-surface code`/`a` element selectors —
 * NOT `<strong>`/`<em>` and NEVER a `bp-*` class). The ONLY class a text span
 * carries is the block-role class (`bp-role-*`), applied at block level. An
 * unmarked text leaf emits BARE escaped text — no wrapping span (walk.ex renders
 * a string child through `escape_html` with no element). */

// Article link colour — the evergreen `--paper-accent`, with the captured
// paperEmail brand hex as the stylesheet-less fallback (Palettes.article_palette
// link_color = `var(--paper-accent, #1e5347)`).
const LINK_STYLE = 'color:var(--paper-accent, #1e5347)'

function markName(m: unknown): string {
  if (typeof m === 'string') return m
  if (isMap(m)) return str(m.type)
  return ''
}

function markAttr(m: unknown, key: string): string {
  if (!isMap(m)) return ''
  const attrs = isMap(m.attrs) ? m.attrs : undefined
  const v = (attrs && attrs[key]) ?? m[key]
  return typeof v === 'string' ? v : ''
}

/** Fold a mark list around an already-escaped text value, right-to-left so the
 * first mark ends up OUTERMOST. Mirrors Inline.apply_marks/3 + Walk emission. */
function applyMarks(escaped: string, marks: unknown[]): string {
  let acc = escaped
  let bare = true // acc is still un-wrapped text (code is leaf-only, per apply_mark)
  for (let i = marks.length - 1; i >= 0; i--) {
    const m = marks[i]
    const name = markName(m)
    switch (name) {
      case 'bold':
      case 'strong':
        acc = `<span style="font-weight:bold">${acc}</span>`
        bare = false
        break
      case 'italic':
      case 'em':
        acc = `<span style="font-style:italic">${acc}</span>`
        bare = false
        break
      case 'underline':
        acc = `<span style="text-decoration:underline">${acc}</span>`
        bare = false
        break
      case 'strike':
      case 's':
      case 'strikethrough':
        acc = `<span style="text-decoration:line-through">${acc}</span>`
        bare = false
        break
      case 'code':
        // Leaf-only: only wraps when acc is still bare text (apply_mark code/2).
        if (bare) {
          acc = `<code>${acc}</code>`
          bare = false
        }
        break
      case 'link': {
        const href = markAttr(m, 'href')
        acc = `<a href="${safeUrl(href)}" style="${LINK_STYLE}">${acc}</a>`
        bare = false
        break
      }
      case 'wikilink': {
        const target = escapeHtml(markAttr(m, 'target'))
        const alias = markAttr(m, 'alias')
        const label = alias !== '' ? escapeHtml(alias) : acc
        acc = `<span data-wikilink="${target}" class="bp-wikilink bp-wikilink--unresolved">${label}</span>`
        bare = false
        break
      }
      case 'blockref': {
        const target = escapeHtml(markAttr(m, 'target'))
        const anchor = escapeHtml(markAttr(m, 'anchor'))
        acc = `<span data-blockref="${target}" data-anchor="${anchor}" class="bp-blockref">^${anchor}</span>`
        bare = false
        break
      }
      case 'tag': {
        acc = tagHtml(markAttr(m, 'name'))
        bare = false
        break
      }
      case 'valueref': {
        acc = valuerefHtml({
          target: markAttr(m, 'target'),
          field: markAttr(m, 'field'),
          fallback: markAttr(m, 'fallback'),
        })
        bare = false
        break
      }
      default:
        // Unknown mark passes through with no wrapper (apply_mark catch-all).
        break
    }
  }
  return acc
}

function tagHtml(rawName: string): string {
  const name = escapeHtml(rawName)
  const href = escapeHtml('/tags/' + encodeURIComponent(rawName))
  return `<a href="${href}" data-tag="${name}" class="bp-tag">#${name}</a>`
}

function valuerefHtml(v: {
  target: string
  field: string
  fallback: string
  resolved?: string | undefined
}): string {
  const resolved = typeof v.resolved === 'string' && v.resolved !== '' ? v.resolved : null
  const fallback = typeof v.fallback === 'string' ? v.fallback : ''
  // Without a walk-time :values map, node.resolved stands in: drift is the ONE
  // comparison (fallback vs resolved), dangling when unresolved.
  let state: string
  let text: string
  if (resolved !== null) {
    state = fallback === '' || resolved === fallback ? 'resolved' : 'drift'
    text = resolved
  } else {
    state = 'dangling'
    text = fallback
  }
  return `<span data-valueref="${escapeHtml(v.target)}" data-field="${escapeHtml(v.field)}" data-valueref-state="${state}">${escapeHtml(text)}</span>`
}

/** The concatenated, UNESCAPED text of an inline-node tree — no markup. Used by
 * text-leaf emitters (inline code) that must fold nested `children` into a flat
 * string rather than nested elements. */
function inlineText(nodes: unknown): string {
  if (typeof nodes === 'string' || typeof nodes === 'number') return String(nodes)
  if (!Array.isArray(nodes)) return ''
  return nodes
    .map((n) => (isMap(n) ? textLeafValue(n) || inlineText(n.children) : inlineText(n)))
    .join('')
}

/** Render one inline node to an HTML string. */
export function renderInline(node: Inline): string {
  if (typeof node === 'string') return escapeHtml(node)
  if (typeof node === 'number') return escapeHtml(String(node))
  // A bare ARRAY where an inline node was expected (`content: [[{text…}]]` —
  // flattened one level too shallow by an upstream author path). This is the
  // js-only divergence from the Elixir twin: inline.ex `compose_inline(l) when
  // is_list(l)` wraps the composed children in a PdText, which walk.ex `text/3`
  // emits as a bare `<span>`; js returned '' and the text VANISHED. 59 live
  // paragraphs + 18 list blocks carry the shape.
  if (Array.isArray(node)) return `<span>${renderInlines(node)}</span>`
  if (!isMap(node)) return ''

  switch (str(node.type)) {
    case 'text': {
      // Dual-read `value` || legacy `text`: raw mutate writers persisted text
      // leaves keyed {"type":"text","text":…}; the Hollow predicate counts both
      // spellings as content, so the renderers must agree or such a paper reads
      // as structure with zero prose. Twins: inline.ex compose_inline,
      // pdrender inline.go attrStrFirst(n, "value", "text").
      const value = escapeHtml(textLeafValue(node))
      const marks = asList(node.marks)
      return marks.length ? applyMarks(value, marks) : value
    }
    case 'strong':
    case 'bold':
      return `<span style="font-weight:bold">${renderInlines(node.children)}</span>`
    case 'em':
    case 'italic':
      return `<span style="font-style:italic">${renderInlines(node.children)}</span>`
    case 'underline':
      return `<span style="text-decoration:underline">${renderInlines(node.children)}</span>`
    case 'strike':
    case 's':
    case 'strikethrough':
      return `<span style="text-decoration:line-through">${renderInlines(node.children)}</span>`
    case 'code':
      // Swept sibling of the block-level content[] defect, at inline level: an
      // inline code node authored with `children` inline nodes (rather than a
      // flat `value`) rendered an empty `<code></code>`. 66 live paragraphs
      // carry that shape. Inline code is a TEXT leaf — the children are folded
      // to their concatenated text, never to nested markup, so the emitted
      // `<code>` body stays escaped plain text exactly as the `value` path.
      return `<code>${escapeHtml(str(node.value) || inlineText(node.children))}</code>`
    case 'link':
      return `<a href="${safeUrl(str(node.href))}" style="${LINK_STYLE}">${renderInlines(node.children)}</a>`
    case 'wikilink': {
      const target = escapeHtml(str(node.target))
      const alias = str(node.alias)
      const kids = renderInlines(node.children)
      const label =
        alias !== '' ? escapeHtml(alias) : kids !== '' ? kids : escapeHtml(str(node.target))
      return `<span data-wikilink="${target}" class="bp-wikilink bp-wikilink--unresolved">${label}</span>`
    }
    case 'blockref': {
      const target = escapeHtml(str(node.target))
      const anchor = escapeHtml(str(node.anchor))
      return `<span data-blockref="${target}" data-anchor="${anchor}" class="bp-blockref">^${anchor}</span>`
    }
    case 'tag':
      return tagHtml(str(node.name))
    case 'valueref':
      return valuerefHtml({
        target: str(node.target),
        field: str(node.field),
        fallback: str(node.fallback),
        resolved: typeof node.resolved === 'string' ? node.resolved : undefined,
      })
    default: {
      // Unknown inline → degrade to its children when present, else nothing.
      const kids = asList(node.children)
      return kids.length ? renderInlines(kids) : ''
    }
  }
}

/** Render an inline-node array (or a scalar cell) to an HTML string. */
export function renderInlines(nodes: unknown): string {
  if (typeof nodes === 'string') return escapeHtml(nodes)
  if (typeof nodes === 'number') return escapeHtml(String(nodes))
  if (!Array.isArray(nodes)) return ''
  return nodes.map((n) => renderInline(n as Inline)).join('')
}

/** Render a TABLE cell's inline content the way `walk.ex` does — one PdText per
 * node, so a bare text node is wrapped in a `<span>` (mark styles fold ONTO that
 * span). This differs from {@link renderInlines} (used by paragraph/list/callout,
 * which leave unmarked text bare): table cells route through `render_children` →
 * `walk`, which projects every inline node to a PdText element. */
export function renderCell(cell: unknown): string {
  const nodes = Array.isArray(cell) ? cell : cell == null ? [] : [cell]
  return nodes
    .map((n) => {
      if (typeof n === 'string') return `<span>${escapeHtml(n)}</span>`
      if (typeof n === 'number') return `<span>${escapeHtml(String(n))}</span>`
      if (!isMap(n)) return ''
      if (str(n.type) === 'text') {
        const value = escapeHtml(textLeafValue(n))
        const inner = asList(n.marks).length ? applyMarks(value, asList(n.marks)) : value
        // A mark that produced a wrapper element (bold/italic/code/link/…) is the
        // PdText span itself; only genuinely-bare text needs the base `<span>`.
        return inner.startsWith('<') ? inner : `<span>${inner}</span>`
      }
      return renderInline(n as Inline)
    })
    .join('')
}
