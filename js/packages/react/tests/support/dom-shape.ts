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
//   - immediate text (whitespace-collapsed; pure-whitespace text nodes are dropped so
//     HEEx indentation does not create phantom diffs)
//   - element children, compared in order, recursively
//
// It deliberately does NOT compare incidental attributes (href/src/id/colspan/…): the
// golden's own shape projection (golden-gen slice) is defined as tag + class-set +
// data-* + text, and comparing e.g. CDN image URLs would red on cross-surface query
// ordering that is not a structural divergence. `style` is the one addition, mandated
// by D4/D6 for the inline-mark and chat families.

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
function project(el: Element): ShapeNode {
  const classAttr = el.getAttribute('class') ?? ''
  const classes = classAttr.split(/\s+/).filter(Boolean)
  classes.sort()

  const data: Record<string, string> = {}
  for (const attr of Array.from(el.attributes)) {
    if (attr.name.startsWith('data-')) data[attr.name] = attr.value ?? ''
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
    tag: el.tagName.toLowerCase(),
    classes,
    data,
    style: parseStyle(el.getAttribute('style')),
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
