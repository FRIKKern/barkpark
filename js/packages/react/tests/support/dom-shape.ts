// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Layer-2 DOM-shape comparator for the cross-surface PortableDoc parity harness.
//
// WHY THIS EXISTS (charter D10): Elixir HEEx and JS SSR never match byte-for-byte
// — different whitespace, different attribute order, different self-closing style.
// Each runtime freezes its OWN HTML snapshot (Layer 1: the Elixir golden mirror at
// tests/fixtures/pd-golden/, the JS `renderToStaticMarkup` output). This module is
// Layer 2: it parses BOTH HTML strings into a normalized shape tree and asserts they
// are *shape-equal* node-for-node. It is net-new and STRICTER than any repo precedent
// (Go's pdrender golden asserts only text presence + order; this asserts full tree
// structure). No prior art was ported — this is authored fresh.
//
// SHAPE, not bytes. Two nodes are equal when they agree on:
//   - tag name (lower-cased)
//   - class SET (order-insensitive — `class="a b"` == `class="b a"`)
//   - data-* attributes (name -> value map)
//   - the `style` attribute (parsed to a property -> value map, order-insensitive;
//     required for D4 inline-mark spans and D6 chat markup — "shape+style-attribute")
//   - EVERY OTHER attribute, minus the small justified {@link VARIABLE_ATTRS} denylist
//   - immediate text (whitespace-collapsed; pure-whitespace text nodes are dropped so
//     HEEx indentation does not create phantom diffs)
//   - element children, compared in order, recursively
//
// ## Why the exclusion is a DENYLIST, not an allowlist (2026-08-31)
//
// This comparator's `data-*` leg carries NO allowlist, and that breadth is exactly
// why it caught a live half-change (Elixir emitting an attribute the JS mirror
// lacked). Every other attribute used to be dropped wholesale, with the stated
// rationale "incidental attributes (href/src/id/colspan/…) … comparing e.g. CDN
// image URLs would red on cross-surface query ordering". That rationale justifies
// the URL-bearing attributes and NOTHING ELSE — but the exclusion was far wider
// than its own justification, so the mirrors could diverge silently on:
//
//   - `role`, `aria-label`, `aria-hidden`, `aria-selected` — accessibility SEMANTICS
//   - `scope`, `colspan`, `rowspan`, `headers` — table STRUCTURE
//   - `alt` — accessibility text
//   - `rel` (`noopener`) — a SECURITY property
//   - `x`/`y`/`points`/`d`/`viewBox`/`fill`/`stroke` — the whole SVG geometry
//     surface, which for the `route` block IS the content
//
// MEASURED before the change, across all 64 pd-golden fixtures: 41 distinct
// attribute names appear on the two mirrors and were compared by nothing, and
// they currently AGREE on every one — the exclusion was hiding no live
// divergence, only future ones. A `scope="row"` -> `scope="col"` flip on the
// Elixir mirror (real screen-reader breakage) left the whole harness green at
// 81/81. So the exclusion set is now a NAMED DENYLIST with a per-entry reason,
// and everything outside it is compared. A guard that compares a subset reads
// as coverage while failing silently; that is the failure mode being closed.

/**
 * The ONLY attributes exempt from comparison, each for a stated reason. Anything
 * not listed here is compared — adding an entry needs a reason of the same kind
 * (the value legitimately varies BETWEEN SURFACES without a structural meaning).
 */
export const VARIABLE_ATTRS: ReadonlySet<string> = new Set([
  // URL-bearing: a CDN/asset URL's query-parameter ORDER differs per surface
  // (the original, legitimate rationale for this exclusion).
  'href',
  'src',
  'srcset',
  'poster',
  // Identity-bearing: React/Astro/Next may mint their own instance ids, and an
  // id is a handle rather than a structural property.
  'id',
])

/**
 * Tags on which `width`/`height` are consumer-supplied RESPONSIVE SIZING HINTS
 * rather than structure — `composed-doc-parity.test.ts`'s "RESPONSIVE WIDTHS"
 * case asserts exactly that (`{...image, width: 320}` must stay shape-identical
 * to the base image). Scoped to the media tags on purpose: on `<svg>` and its
 * children `width`/`height` ARE geometry, so they stay compared there.
 */
const SIZING_HINT_TAGS: ReadonlySet<string> = new Set([
  'img',
  'video',
  'audio',
  'iframe',
  'source',
  'embed',
  'canvas',
  'object',
])

/** True when `name` on `tag` is exempt from comparison. */
function isVariableAttr(tag: string, name: string): boolean {
  if (VARIABLE_ATTRS.has(name)) return true
  if ((name === 'width' || name === 'height') && SIZING_HINT_TAGS.has(tag)) return true
  return false
}

import { Window, type Element } from 'happy-dom'

/** A normalized, comparable projection of one DOM element. */
export interface ShapeNode {
  /** lower-cased tag name */
  tag: string
  /** the class attribute as a sorted SET (order-insensitive) */
  classes: string[]
  /** data-* attributes, name -> value */
  data: Record<string, string>
  /** the `style` attribute parsed to a property -> value map (order-insensitive) */
  style: Record<string, string>
  /**
   * Every remaining attribute, name -> value: everything that is not `class`,
   * not `style`, not `data-*` (those have their own fields above) and not in
   * {@link VARIABLE_ATTRS}. Names are lower-cased; values compared verbatim.
   */
  attrs: Record<string, string>
  /** immediate text of this element (whitespace-collapsed), excluding descendants */
  text: string
  /** element children, in document order */
  children: ShapeNode[]
}

const NODE_ELEMENT = 1
const NODE_TEXT = 3

function normText(s: string): string {
  return s.replace(/\s+/g, ' ').trim()
}

/** Parse a `style="a: 1; b: 2"` string into an order-insensitive property map. */
function parseStyle(raw: string | null): Record<string, string> {
  const out: Record<string, string> = {}
  if (!raw) return out
  for (const decl of raw.split(';')) {
    const idx = decl.indexOf(':')
    if (idx === -1) continue
    const prop = decl.slice(0, idx).trim().toLowerCase()
    const val = normText(decl.slice(idx + 1))
    if (prop) out[prop] = val
  }
  return out
}

/** Project a live DOM element into a normalized {@link ShapeNode}. */
/**
 * The `class` attribute as a SORTED set. Shared by BOTH projections below, so the
 * cross-projector check in the parity harness actually exercises this normalization
 * (see {@link parseGoldenShape}).
 */
function classSet(el: Element): string[] {
  const classes = (el.getAttribute('class') ?? '').split(/\s+/).filter(Boolean)
  classes.sort()
  return classes
}

/** The `data-*` attributes as a name -> value map. Shared by both projections. */
function dataAttrs(el: Element): Record<string, string> {
  const data: Record<string, string> = {}
  for (const attr of Array.from(el.attributes)) {
    const name = attr.name.toLowerCase()
    if (name.startsWith('data-')) data[name] = attr.value ?? ''
  }
  return data
}

function project(el: Element): ShapeNode {
  const tag = el.tagName.toLowerCase()
  const classes = classSet(el)
  const data = dataAttrs(el)

  const attrs: Record<string, string> = {}
  for (const attr of Array.from(el.attributes)) {
    const name = attr.name.toLowerCase()
    if (name.startsWith('data-')) continue
    // `class` and `style` are projected into their own order-insensitive fields.
    if (name === 'class' || name === 'style') continue
    if (isVariableAttr(tag, name)) continue
    attrs[name] = attr.value ?? ''
  }

  // Immediate text: only direct text-node children, whitespace-collapsed.
  let text = ''
  const children: ShapeNode[] = []
  for (const node of Array.from(el.childNodes)) {
    if (node.nodeType === NODE_TEXT) {
      text += node.textContent ?? ''
    } else if (node.nodeType === NODE_ELEMENT) {
      children.push(project(node as unknown as Element))
    }
    // comments / CDATA / processing instructions are ignored — not shape.
  }

  return {
    tag,
    classes,
    data,
    style: parseStyle(el.getAttribute('style')),
    attrs,
    text: normText(text),
    children,
  }
}

export interface ParseOptions {
  /**
   * When the fragment is exactly ONE root element carrying this class, descend into
   * its children before projecting. Lets a per-block Elixir golden (bare block markup)
   * compare against a JS renderer that wraps every document in `.bp-paper-surface`,
   * regardless of which side carries the wrapper. Applied to BOTH sides in the harness.
   */
  unwrapClass?: string
}

/** Parse an HTML fragment string into its top-level {@link ShapeNode}s. */
export function parseShape(html: string, opts: ParseOptions = {}): ShapeNode[] {
  const window = new Window()
  try {
    const doc = window.document
    doc.body.innerHTML = html
    let roots = Array.from(doc.body.children).map((el) => project(el as unknown as Element))
    const only = roots[0]
    if (opts.unwrapClass && roots.length === 1 && only && only.classes.includes(opts.unwrapClass)) {
      roots = only.children
    }
    return roots
  } finally {
    // happy-dom retains timers/observers; release them so the test process exits clean.
    window.close?.()
  }
}

/** A human-readable path to the node under comparison, e.g. `root[0] > div.bp-callout > p`. */
function label(node: ShapeNode): string {
  return node.classes.length ? `${node.tag}.${node.classes.join('.')}` : node.tag
}

function diffNode(a: ShapeNode, b: ShapeNode, path: string, diffs: string[]): void {
  if (a.tag !== b.tag) {
    diffs.push(`${path}: tag <${a.tag}> != <${b.tag}>`)
    // Different tag => the subtrees are not meaningfully alignable; stop here.
    return
  }
  const ca = a.classes.join(' ')
  const cb = b.classes.join(' ')
  if (ca !== cb) diffs.push(`${path} <${a.tag}>: class set {${ca}} != {${cb}}`)

  diffAttrMap(a.data, b.data, `${path} <${a.tag}> data-*`, diffs)
  diffAttrMap(a.style, b.style, `${path} <${a.tag}> style`, diffs)
  // Everything else: aria-*, role, scope, colspan, alt, rel, SVG geometry, …
  // Only VARIABLE_ATTRS is exempt (see the module note on denylist-not-allowlist).
  diffAttrMap(a.attrs, b.attrs, `${path} <${a.tag}> attr`, diffs)

  if (a.text !== b.text) {
    diffs.push(`${path} <${a.tag}>: text "${a.text}" != "${b.text}"`)
  }

  if (a.children.length !== b.children.length) {
    diffs.push(
      `${path} <${a.tag}>: child count ${a.children.length} != ${b.children.length} ` +
        `(actual: [${a.children.map(label).join(', ')}] vs golden: [${b.children.map(label).join(', ')}])`,
    )
  }
  const n = Math.min(a.children.length, b.children.length)
  for (let i = 0; i < n; i++) {
    const ac = a.children[i]
    const bc = b.children[i]
    if (!ac || !bc) continue
    diffNode(ac, bc, `${path} > ${label(ac)}[${i}]`, diffs)
  }
}

function diffAttrMap(a: Record<string, string>, b: Record<string, string>, path: string, diffs: string[]): void {
  const keys = new Set([...Object.keys(a), ...Object.keys(b)])
  for (const k of Array.from(keys).sort()) {
    const av = a[k]
    const bv = b[k]
    if (av === undefined) diffs.push(`${path}: golden has ${k}="${bv}", actual missing it`)
    else if (bv === undefined) diffs.push(`${path}: actual has ${k}="${av}", golden missing it`)
    else if (av !== bv) diffs.push(`${path}: ${k} "${av}" != "${bv}"`)
  }
}

export interface DiffResult {
  equal: boolean
  diffs: string[]
}

/**
 * Compare two HTML fragment strings by DOM shape. `actual` is the JS-rendered HTML,
 * `golden` the frozen Elixir snapshot. Returns every divergence found (empty => equal).
 */
export function diffShape(actualHtml: string, goldenHtml: string, opts: ParseOptions = {}): DiffResult {
  const actual = parseShape(actualHtml, opts)
  const golden = parseShape(goldenHtml, opts)
  const diffs: string[] = []

  if (actual.length !== golden.length) {
    diffs.push(
      `root: top-level node count ${actual.length} != ${golden.length} ` +
        `(actual: [${actual.map(label).join(', ')}] vs golden: [${golden.map(label).join(', ')}])`,
    )
  }
  const n = Math.min(actual.length, golden.length)
  for (let i = 0; i < n; i++) {
    const ac = actual[i]
    const gc = golden[i]
    if (!ac || !gc) continue
    diffNode(ac, gc, `root[${i}] ${label(ac)}`, diffs)
  }
  return { equal: diffs.length === 0, diffs }
}

/**
 * Assert two HTML fragment strings are DOM-shape-equal. Throws with a node-path diff
 * report on any divergence; returns void on match.
 */
export function assertShapeEqual(actualHtml: string, goldenHtml: string, opts: ParseOptions = {}): void {
  const { equal, diffs } = diffShape(actualHtml, goldenHtml, opts)
  if (!equal) {
    throw new Error(`DOM shape mismatch (${diffs.length} divergence${diffs.length === 1 ? '' : 's'}):\n  - ` + diffs.join('\n  - '))
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// The GOLDEN-shape projection — the cross-projector check on THIS module
// ─────────────────────────────────────────────────────────────────────────────
//
// Every pd-golden fixture carries a `shape` field the ELIXIR side computed
// (mix barkpark.portable_doc.gen_pd_parity, `shape/1`, via LazyHTML) from the
// same `expectedHtml`. Until 2026-09-02 nothing read it: both parity suites
// re-derived shape from `expectedHtml` with the JS parser above, so a
// SYSTEMATIC bug here (e.g. dropping the class sort, or mis-scoping data-*)
// cancelled on both sides of every comparison and all 64 went vacuously green.
//
// `parseGoldenShape` closes that. It projects `expectedHtml` into the ELIXIR
// projector's schema so the two can be compared directly, and it does so through
// the SAME {@link classSet} / {@link dataAttrs} normalization `project()` uses —
// which is the point: an independent re-implementation would only validate the
// copy. The Elixir projection is a second, independently-written witness to what
// this parser should see.
//
// The Elixir schema differs from {@link ShapeNode} in three deliberate ways:
//   - text nodes are SIBLINGS in `children`, in document order — not an
//     `text` field on the parent (so `<p>a <b>x</b> c</p>` keeps its interleaving)
//   - text is VERBATIM, not whitespace-collapsed; whitespace-ONLY nodes are
//     dropped (`skip_whitespace_nodes: true`)
//   - only `tag` / `classes` / `data` / `children` — no `style`, no `attrs`
//     (those live in the frozen `expectedHtml`, per charter D10)

/** One element in the Elixir `shape/1` projection. */
export interface GoldenElementNode {
  tag: string
  classes: string[]
  data: Record<string, string>
  children: GoldenShapeNode[]
}

/** One non-whitespace text node in the Elixir `shape/1` projection. */
export interface GoldenTextNode {
  text: string
}

export type GoldenShapeNode = GoldenElementNode | GoldenTextNode

function projectGolden(el: Element): GoldenElementNode {
  return {
    tag: el.tagName.toLowerCase(),
    classes: classSet(el),
    data: dataAttrs(el),
    children: goldenChildren(el.childNodes),
  }
}

function goldenChildren(nodes: ArrayLike<{ nodeType: number; textContent: string | null }>): GoldenShapeNode[] {
  const out: GoldenShapeNode[] = []
  for (const node of Array.from(nodes)) {
    if (node.nodeType === NODE_TEXT) {
      const text = node.textContent ?? ''
      // `skip_whitespace_nodes: true` on the Elixir side: HEEx indentation must
      // not become a phantom node. Non-whitespace text is kept VERBATIM.
      if (text.trim() !== '') out.push({ text })
    } else if (node.nodeType === NODE_ELEMENT) {
      out.push(projectGolden(node as unknown as Element))
    }
    // comments / CDATA / processing instructions: dropped, same as Elixir.
  }
  return out
}

/**
 * Project an HTML fragment into the Elixir `shape/1` schema, so a golden's
 * Elixir-computed `shape` can be asserted against what this parser sees.
 */
export function parseGoldenShape(html: string): GoldenShapeNode[] {
  const window = new Window()
  try {
    window.document.body.innerHTML = html
    return goldenChildren(window.document.body.childNodes)
  } finally {
    window.close?.()
  }
}
