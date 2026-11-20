// One full reading of a part's stage in the view the page is in: every control's
// boundary, and every text run and graphic read from pixels (see drawn.mjs and
// boundary.mjs). All of it goes through the check's own isolated world and CDP.
const fmt = (n) => n.toFixed(2)

/** `waits`: this view's waits on the sheet (verdict); the reading marks each text drawn in one of their pairs. */
export async function readView(page, part, waits = []) {
  // A judged moment: first note which of the part's rules apply now (coverage.mjs).
  if (page.barkCover) await page.barkCover()
  const sel = `[data-part="${part.name}"]`
  const world = page.barkCheck
  const scale = page.barkScale
  const frame = () => world(() => window.__barkCheck.frame())
  // Captures go through Playwright, which keeps the page's pixel ratio: a capture from a CDP session of our
  // own resets the emulated ratio to 1 for everything after it. The caret is left as it is (no style added).
  const capture = async (p, c) => (await p.screenshot({ clip: { x: c.x, y: c.y, width: c.w, height: c.h }, fullPage: true, scale: 'device', caret: 'initial' })).toString('base64')
  const shoot = (clip) => capture(page, clip)
  const bounds = await world(([s, t]) => window.__barkCheck.boundaries(document.querySelector(s), t), [sel, part.json.textOnly ?? []])
  // The things of the view and, for any not yet drawn alone, their references, drawn and measured in the
  // reference tab (see drawn.mjs) so the page under test is never laid out differently.
  const { missing } = await world((s) => window.__barkCheck.things(document.querySelector(s)), sel)
  if (missing.length) {
    const specs = await world((keys) => window.__barkCheck.specs(keys), missing)
    const ref = page.barkRef
    const at = await ref.world((list) => window.__barkCheck.alone(list), specs)
    await ref.world(() => window.__barkCheck.frame())
    const png = await capture(ref.page, at)
    await world((list) => window.__barkCheck.keep(list), await ref.world(([p, c, k]) => window.__barkCheck.measureAlone(p, c, k), [png, at, scale]))
  }
  // The stage's box, widened to whole CSS pixels (so whole device pixels too): a capture's pixels are the page's own.
  const clip = await world((s) => {
    const r = document.querySelector(s).getBoundingClientRect()
    const x = Math.floor(r.left + scrollX)
    const y = Math.floor(r.top + scrollY)
    return { x, y, w: Math.ceil(r.right + scrollX) - x, h: Math.ceil(r.bottom + scrollY) - y }
  }, sel)
  const drawn = await shoot(clip)
  const without = {}
  try {
    for (const what of ['glyphs', 'graphics']) {
      await world((w) => window.__barkCheck.unpaint(w), what)
      await frame()
      without[what] = await shoot(clip)
    }
  } finally {
    await world(() => window.__barkCheck.unpaint(null))
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
  for (const at of view.grown ?? []) fails.push(`${where}a reader put a child into ${at}, an element it measures`)
  for (const at of view.empty) fails.push(`${where}control has nothing to show at ${at}`)
  for (const at of view.unlabelled) fails.push(`${where}text-only ${at} has no text label`)
  for (const m of view.bounds.misnamed) if (m.ratio < 3) fails.push(`${where}text-only ${m.at} draws its ${m.by} at ${fmt(m.ratio)}:1; drop it or meet 3:1`)
  return { fails, weakest, waited }
}
