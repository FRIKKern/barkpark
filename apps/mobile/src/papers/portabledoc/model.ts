// PortableDoc model + coercion spine — the RN sibling of
// js/packages/react/src/inline.tsx's shared helpers (str / num / asList /
// isMap / safeUrl) and the traversal LAWS the reference renderer encodes:
//
//   • paragraphInline (the content||text fallback law, charter D12): a
//     non-empty `content` inline array wins; otherwise the bare `text`
//     string. The 16/16 capstone headings persist the `content[]` shape —
//     reading `text` alone renders them EMPTY.
//   • headingLevel: 1|2|3 (number or string), anything else → 2.
//   • normalizeListItem: a string item that parses as a JSON-encoded inline
//     array (the drifted `bullet_list` authoring shape) decodes to that
//     array; otherwise verbatim. Mirrors compose.ex normalize_list_item/1.
//   • itemInlines: the corpus additionally persists list items as MAPS with
//     their own `content[]`/`text` (1,774 of 2,431 live items scanned
//     2026-07-25) — those route through the same content||text law.
//
// This module is pure TS (no React, no react-native imports) so the jest
// suite exercises the laws directly.

export type Inline = string | number | ({ type: string } & Record<string, unknown>)

export type Block = { type: string } & Record<string, unknown>

/* ── scalar coercion (mirrors inline.tsx str / num / asList / isMap) ───────── */

export function str(v: unknown): string {
  if (typeof v === 'string') return v
  if (typeof v === 'number' && Number.isFinite(v)) return String(v)
  return ''
}

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

/* ── URL gate (mirrors inline.tsx safeUrl; RN opens instead of hrefs) ──────── */

const ALLOWED_SCHEME = /^(?:https?|mailto|tel):/i

/** A tappable-safe URL or undefined. Narrower than the web twin: RN has no
 * in-doc anchor navigation, so only absolute http(s)/mailto/tel URLs are
 * openable; everything else (javascript:, data:, relative, #anchor) is inert
 * text — never a tap target. */
export function openableUrl(href: unknown): string | undefined {
  if (typeof href !== 'string') return undefined
  const trimmed = href.replace(/^[\x00-\x20]+/, '')
  return ALLOWED_SCHEME.test(trimmed) ? trimmed : undefined
}

/* ── the content||text fallback law (D12) ──────────────────────────────────── */

/** Paragraph/heading/callout/pullquote/ingress/blockquote body: a non-empty
 * `content` inline array, else the bare `text` string, else []. The exact
 * paragraphInline law from blocks/core.ts. */
export function paragraphInline(b: Record<string, unknown>): Inline[] | string {
  const content = b.content
  if (Array.isArray(content) && content.length) return content as Inline[]
  const text = str(b.text)
  return text !== '' ? text : []
}

/** Heading level law from blocks/core.ts heading: 1|2|3 as number or string,
 * anything else (absent, 0, 7, junk) → 2. */
export function headingLevel(b: Record<string, unknown>): 1 | 2 | 3 {
  const raw = b.level
  if (raw === 1 || raw === '1') return 1
  if (raw === 3 || raw === '3') return 3
  return 2
}

/* ── list item normalization ───────────────────────────────────────────────── */

/** Decode a list item persisted as a JSON-encoded inline array (the drifted
 * `bullet_list` authoring shape) into that array; otherwise return verbatim.
 * Mirrors blocks/core.ts normalizeListItem. */
export function normalizeListItem(item: unknown): unknown {
  if (typeof item !== 'string') return item
  const trimmed = item.trim()
  if (!trimmed.startsWith('[')) return item
  try {
    const parsed: unknown = JSON.parse(trimmed)
    if (Array.isArray(parsed) && parsed.length > 0 && isMap(parsed[0])) return parsed
  } catch {
    // not JSON — keep the plain string
  }
  return item
}

/** The inline content of one list item, whatever authored shape it took:
 *  - array → inline nodes verbatim
 *  - string → JSON-decoded inline array, else the plain string
 *  - map → its own content||text (the DOMINANT live-corpus shape: 1,774 of
 *    2,431 items scanned 2026-07-25 are `{content:[…]}` maps)
 */
export function itemInlines(item: unknown): Inline[] | string {
  const normalized = normalizeListItem(item)
  if (Array.isArray(normalized)) return normalized as Inline[]
  if (typeof normalized === 'string') return normalized
  if (isMap(normalized)) return paragraphInline(normalized)
  if (typeof normalized === 'number') return String(normalized)
  return []
}

/* ── inline marks (mirrors inline.tsx markName/markAttr) ───────────────────── */

export function markName(m: unknown): string {
  if (typeof m === 'string') return m
  if (isMap(m)) return str(m.type)
  return ''
}

export function markAttr(m: unknown, key: string): string {
  if (!isMap(m)) return ''
  const attrs = isMap(m.attrs) ? m.attrs : undefined
  const v = (attrs && attrs[key]) ?? m[key]
  return typeof v === 'string' ? v : ''
}
