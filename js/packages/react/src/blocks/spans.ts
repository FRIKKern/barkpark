export type Span = [number, number, number, number]

export interface SpanLookup {
  anchors: Map<string, [number, number]>
  covered: Set<string>
}

export function coverSpans(spans: Span[], lens: number[], keepFirst: boolean): SpanLookup {
  const anchors = new Map<string, [number, number]>()
  const covered = new Set<string>()
  let left = lens.reduce((n, len) => n + len, 0)
  for (const [r0, c0, rs, cs] of spans) {
    if (r0 >= lens.length || c0 >= lens[r0]!) continue
    const cost = spanCost(lens, r0, c0, rs, cs)
    if (cost > left) break
    for (let r = r0; r < Math.min(r0 + rs, lens.length); r++)
      for (let c = c0; c < Math.min(c0 + cs, lens[r]!); c++)
        if (r !== r0 || c !== c0) covered.add(`${r},${c}`)
    const origin = `${r0},${c0}`
    if (!(keepFirst && anchors.has(origin))) anchors.set(origin, [rs, cs])
    left -= cost
  }
  return { anchors, covered }
}

function spanCost(lens: number[], r0: number, c0: number, rs: number, cs: number): number {
  const end = Math.min(r0 + rs, lens.length)
  let cells = 0
  for (let r = r0; r < end; r++) cells += Math.max(Math.min(c0 + cs, lens[r]!) - c0, 0)
  return Math.max(cells, end - r0)
}

export function spanAttr(anchors: Map<string, [number, number]>, r: number, c: number): string {
  const hit = anchors.get(`${r},${c}`)
  if (!hit) return ''
  const [rs, cs] = hit
  return (cs > 1 ? ` colspan="${cs}"` : '') + (rs > 1 ? ` rowspan="${rs}"` : '')
}
