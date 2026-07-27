// The element-tree walker the crown suites share (charter D50/D51).
//
// The renderers are PURE functions returning a ReactNode tree — no native host,
// no react-test-renderer, no emulator — so a plain recursive walk over
// `props.children` collecting text and flattened styles IS the observation
// instrument. The per-family round-2 suites each grew their own private copy of
// this walker because they landed in parallel under a per-file territory law;
// the three crown suites share ONE copy instead, because a crown tripwire that
// disagreed with itself about how a style is flattened would be worse than
// useless. The older copies are left where they are on purpose: each carries
// family-specific extras (font-family censuses, island counts), and rewriting
// six suites to funnel through here would be churn with no new guarantee.
//
// NOT a .test.tsx: jest.config testMatch is `**/__tests__/**/*.test.ts(x)`, so
// this file is importable support and never collected as a suite.
import type { ReactElement, ReactNode } from 'react'

export interface Walk {
  /** Every string/number leaf, concatenated in tree order. */
  text: string
  /** One flattened style object per styled element, in tree order. RN accepts
   * an array of styles; flattening with Object.assign is what the platform
   * itself does, so the census sees the value that actually paints. */
  styles: Record<string, unknown>[]
  /** Elements whose type was on the OPAQUE list — walked no further. */
  opaque: number
}

function isElement(node: unknown): node is ReactElement {
  return !!node && typeof node === 'object' && 'props' in (node as object) && '$$typeof' in (node as object)
}

/** Component types to count and NOT descend into — stateful leaves whose
 * subtree is not a pure function of the block (MermaidIsland renders a WebView
 * whose HTML is built in an effect). Passed in rather than imported so this
 * module stays dependency-free. */
export type Opaque = readonly unknown[]

function walkNode(node: ReactNode, acc: Walk, opaque: Opaque): void {
  if (node === null || node === undefined || typeof node === 'boolean') return
  if (typeof node === 'string' || typeof node === 'number') {
    acc.text += String(node)
    return
  }
  if (Array.isArray(node)) {
    for (const child of node) walkNode(child as ReactNode, acc, opaque)
    return
  }
  if (!isElement(node)) return
  if (opaque.includes(node.type)) {
    acc.opaque++
    return
  }
  const props = node.props as Record<string, unknown>
  const raw = props.style
  if (raw !== undefined) {
    const parts = Array.isArray(raw) ? raw : [raw]
    acc.styles.push(Object.assign({}, ...parts.filter((p) => !!p)) as Record<string, unknown>)
  }
  walkNode(props.children as ReactNode, acc, opaque)
}

export function walk(node: ReactNode, opaque: Opaque = []): Walk {
  const acc: Walk = { text: '', styles: [], opaque: 0 }
  walkNode(node, acc, opaque)
  return acc
}

/** The style census as a comparable value: the flattened style list with keys
 * sorted so key ORDER never counts as a difference. Two renders with the same
 * census are byte-identical in everything that paints. */
export function styleCensus(w: Walk): string {
  return JSON.stringify(
    w.styles.map((s) =>
      Object.keys(s)
        .sort()
        .map((k) => [k, s[k]]),
    ),
  )
}
