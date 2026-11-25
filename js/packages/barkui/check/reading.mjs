// One full reading of a part's stage in the view the page is in: every control's
// boundary, and every text run and graphic read from pixels (see drawn.mjs and
// boundary.mjs). All of it goes through the check's own isolated world and CDP.
import { capture } from './capture.mjs'
import { UNNAMED } from './layers.mjs'
const fmt = (n) => n.toFixed(2)

/** `waits`: this view's waits on the sheet (verdict); the reading marks each text drawn in one of their pairs. */
export async function readView(page, part, waits = []) {
  // A judged moment: first note which of the part's rules apply now (coverage.mjs).
  if (page.barkCover) await page.barkCover()
  const sel = `[data-part="${part.name}"]`
  const world = page.barkCheck
  const scale = page.barkScale
  const frame = () => world(() => window.__barkCheck.frame())
  // Every capture goes through capture.mjs: the page at rest, or red by name.
  const shoot = (clip) => capture(page, world, clip)
  // The stage's box, widened to whole CSS pixels (so whole device pixels too): a capture's pixels are the page's own.
  // With a box of the part's layers open in the top layer, the capture covers that box too, and what the page draws
  // behind it is captured first with the open boxes hidden (layers.mjs).
  await world(() => window.__barkCheck.still('a reading'))
  // A checked page holds no shadow root of its own (no part makes one): one found, of any mode, is red by name, as
  // the check does not read inside it. The browser's own roots (an input's, a select's) are not the page's.
  if (page.barkCdp) {
    const { root } = await page.barkCdp.send('DOM.getDocument', { depth: -1, pierce: true })
    const hosts = []
    const walk = (n) => {
      for (const s of n.shadowRoots ?? []) if (s.shadowRootType !== 'user-agent') hosts.push(`${n.localName}${n.attributes?.includes('id') ? `#${n.attributes[n.attributes.indexOf('id') + 1]}` : ''}`)
      for (const c of [...(n.children ?? []), ...(n.shadowRoots ?? []), ...(n.contentDocument ? [n.contentDocument] : [])]) walk(c)
    }
    walk(root)
    if (hosts.length) throw new Error(`the check could not read (not a fault of the part): unread: shadow root at ${hosts.slice(0, 3).join('; ')}`)
  }
  const open = await world(([s, b]) => window.__barkCheck.layers(document.querySelector(s), b), [sel, (part.json.layers ?? []).map((l) => l.box)])
  const clip = await world(([s, boxes]) => {
    const r = document.querySelector(s).getBoundingClientRect()
    const all = [{ x: r.left + scrollX, y: r.top + scrollY, w: r.width, h: r.height }, ...boxes]
    const x = Math.floor(Math.min(...all.map((b) => b.x)))
    const y = Math.floor(Math.min(...all.map((b) => b.y)))
    return { x, y, w: Math.ceil(Math.max(...all.map((b) => b.x + b.w))) - x, h: Math.ceil(Math.max(...all.map((b) => b.y + b.h))) - y }
  }, [sel, open.boxes])
  const R0 = performance.now()
  try {
  if (open.boxes.length) {
    try {
      await world(() => window.__barkCheck.hideLayers(true))
      await frame()
      const behind = await shoot(clip)
      await world(([png, c, k]) => window.__barkCheck.under(png, c, k), [behind, clip, scale])
    } finally {
      await world(() => window.__barkCheck.hideLayers(false))
      await frame()
    }
  }
  try {
    const can = page.barkCensus ? await page.barkCensus(part) : []
    return { ...(await readNow(page, part, waits, { sel, world, scale, frame, shoot, clip })), unnamed: open.unnamed, can }
  } finally {
    if (open.boxes.length) await world(() => window.__barkCheck.under(null))
  }
  } finally {
    if (!readView.seen) readView.seen = new Set()
    const k = `${part.name} ${clip.w}x${clip.h}@${scale}`
    readView.n = (readView.n ?? 0) + 1
    if (!readView.seen.has(k) || readView.n % 25 === 0) { readView.seen.add(k); process.stderr.write(`T> ${part.name}       reading ${clip.w}x${clip.h} at ${scale}x took ${((performance.now() - R0) / 1000).toFixed(2)} s\n`) }
  }
}

async function readNow(page, part, waits, { sel, world, scale, frame, shoot, clip }) {
  const bounds = await world(([s, t]) => window.__barkCheck.boundaries(document.querySelector(s), t), [sel, part.json.textOnly ?? []])
  // The things of the view and, for any not yet drawn alone, their references, drawn and measured in the
  // reference tab (see drawn.mjs) so the page under test is never laid out differently.
  const { missing } = await world((s) => window.__barkCheck.things(document.querySelector(s)), sel)
  if (missing.length) {
    const specs = await world((keys) => window.__barkCheck.specs(keys), missing)
    const ref = page.barkRef
    const at = await ref.world((list) => window.__barkCheck.alone(list), specs)
    await ref.world(() => window.__barkCheck.frame())
    const png = await capture(ref.page, ref.world, at)
    await world((list) => window.__barkCheck.keep(list), await ref.world(([p, c, k]) => window.__barkCheck.measureAlone(p, c, k), [png, at, scale]))
  }
  // A caret blinks, so it could be in one capture and not another by chance: every capture is taken without it.
  // A selection is painted in the browser's colours, not the field's: every capture is taken with it painted plain.
  let drawn
  const without = {}
  try {
    await world(() => window.__barkCheck.caret(false))
    await world(() => window.__barkCheck.selection(false))
    await frame()
    drawn = await shoot(clip)
    for (const what of ['glyphs', 'graphics']) {
      await world((w) => window.__barkCheck.unpaint(w), what)
      await frame()
      without[what] = await shoot(clip)
    }
  } finally {
    await world(() => {
      window.__barkCheck.unpaint(null)
      window.__barkCheck.caret(true)
      window.__barkCheck.selection(true)
    })
    await frame()
  }
  const pairs = waits.map((w) => [w.text, w.ground])
  const seen = await world(([a, b, c, cl, k, s, p]) => window.__barkCheck.judge(a, b, c, cl, k, document.querySelector(s), p), [drawn, without.glyphs, without.graphics, clip, scale, sel, pairs])
  return { ...seen, bounds }
}

/** The least a label's picture may match its reference (match.mjs). An honest label reads 1.00 on macOS and
    Linux; the selftest's ladder pins what a step below this costs (docs/PARTS.md "What the check proves"). */
export const MATCH_MIN = 0.975
const NEEDS = { text: 4.5, graphic: 3 }

/** What a reading fails on, text first; the weakest text, graphic and label that draw; the least share of itself
    that a graphic draws. Disabled things must draw in full but are not held to contrast. A drawn text under 4.5:1
    is let through only by a wait on the sheet (`waits`, those of this view, see build/sheet-waits.mjs) whose two
    tokens it is drawn in, and only while it measures no worse than the wait records; `waited` says which. */
export function verdict(view, where = '', waits = []) {
  const fails = []
  const waited = []
  const weakest = { text: { ratio: Infinity, at: '' }, graphic: { ratio: Infinity, at: '' }, share: 1, label: { match: Infinity, at: '' } }
  for (const kind of ['text', 'graphic']) {
    for (const t of view.things.filter((x) => x.kind === kind)) {
      const label = t.match !== undefined
      if (t.draws && label && t.match < weakest.label.match) weakest.label = { match: t.match, at: t.at }
      if (t.draws && !label && t.share !== null) weakest.share = Math.min(weakest.share, t.share)
      if (!t.draws) fails.push(`${where}${kind} does not draw at ${t.at}`)
      else if (label && t.match < MATCH_MIN) fails.push(`${where}label is not drawn as itself: ${fmt(t.match)} of it matches its own words drawn alone, needs ${MATCH_MIN}, at ${t.at}`)
      else if (!label && t.share !== null && t.share < 0.9) fails.push(`${where}${kind === 'text' ? 'label' : 'graphic'} is cut: ${Math.round(t.share * 100)}% of it draws at ${t.at}`)
      else if (!t.quiet) {
        const w = kind === 'text' && t.ratio < NEEDS.text && t.fits !== undefined ? waits[t.fits] : null
        if (w && +fmt(t.ratio) >= w.measured) {
          waited.push({ wait: w, ratio: t.ratio, at: t.at })
          continue
        }
        if (t.ratio < weakest[kind].ratio) weakest[kind] = { ratio: t.ratio, at: t.at }
        if (w) fails.push(`${where}drawn text ${fmt(t.ratio)}:1 at ${t.at}, under the ${w.measured}:1 its wait on the sheet records`)
        else if (t.ratio < NEEDS[kind]) fails.push(`${where}drawn ${kind} ${fmt(t.ratio)}:1 at ${t.at}`)
      }
    }
  }
  for (const at of view.unnamed ?? []) fails.push(`${where}${UNNAMED(at)}`)
  for (const f of view.can ?? []) fails.push(`${where}${f}`)
  for (const at of view.grown ?? []) fails.push(`${where}a reader put a child into ${at}, an element it measures`)
  for (const at of view.empty) fails.push(`${where}control has nothing to show at ${at}`)
  for (const at of view.unlabelled) fails.push(`${where}text-only ${at} has no text label`)
  for (const m of view.bounds.misnamed) if (m.ratio < 3) fails.push(`${where}text-only ${m.at} draws its ${m.by} at ${fmt(m.ratio)}:1; drop it or meet 3:1`)
  return { fails, weakest, waited }
}
