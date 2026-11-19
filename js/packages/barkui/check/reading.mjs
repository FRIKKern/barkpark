// One full reading of a part's stage in the view the page is in: every control's
// boundary, and every text run and graphic read from pixels (see drawn.mjs and
// boundary.mjs). All of it goes through the check's own isolated world and CDP.
const fmt = (n) => n.toFixed(2)

export async function readView(page, part) {
  const sel = `[data-part="${part.name}"]`
  const world = page.barkCheck
  const scale = page.barkScale
  const frame = () => world(() => window.__barkCheck.frame())
  const shoot = async (clip) => (await page.barkCdp.send('Page.captureScreenshot', { format: 'png', clip: { x: clip.x, y: clip.y, width: clip.w, height: clip.h, scale }, captureBeyondViewport: true })).data
  const bounds = await world(([s, t]) => window.__barkCheck.boundaries(document.querySelector(s), t), [sel, part.json.textOnly ?? []])
  const clip = await world((s) => {
    const r = document.querySelector(s).getBoundingClientRect()
    return { x: r.left + scrollX, y: r.top + scrollY, w: r.width, h: r.height }
  }, sel)
  const { missing } = await world((s) => window.__barkCheck.things(document.querySelector(s)), sel)
  if (missing.length) {
    const at = await world((keys) => window.__barkCheck.alone(keys), missing)
    await frame()
    const png = await shoot(at)
    await world(([p, c, k]) => window.__barkCheck.measureAlone(p, c, k), [png, at, scale])
    await frame()
  }
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
  const seen = await world(([a, b, c, cl, k, s]) => window.__barkCheck.judge(a, b, c, cl, k, document.querySelector(s)), [drawn, without.glyphs, without.graphics, clip, scale, sel])
  return { ...seen, bounds }
}

/** What a reading fails on, text first, the weakest text and graphic that draw, and the least share of itself
    that anything draws. Disabled things must draw in full but are not held to contrast. */
export function verdict(view, where = '') {
  const fails = []
  const weakest = { text: { ratio: Infinity, at: '' }, graphic: { ratio: Infinity, at: '' }, share: 1 }
  for (const kind of ['text', 'graphic']) {
    const need = kind === 'text' ? 4.5 : 3
    for (const t of view.things.filter((x) => x.kind === kind)) {
      if (t.draws && t.share !== null) weakest.share = Math.min(weakest.share, t.share)
      if (!t.draws) fails.push(`${where}${kind} does not draw at ${t.at}`)
      else if (t.share !== null && t.share < 0.9) fails.push(`${where}${kind === 'text' ? 'label' : 'graphic'} is cut: ${Math.round(t.share * 100)}% of it draws at ${t.at}`)
      else if (!t.quiet) {
        if (t.ratio < weakest[kind].ratio) weakest[kind] = { ratio: t.ratio, at: t.at }
        if (t.ratio < need) fails.push(`${where}drawn ${kind} ${fmt(t.ratio)}:1 at ${t.at}`)
      }
    }
  }
  for (const at of view.empty) fails.push(`${where}control has nothing to show at ${at}`)
  for (const at of view.unlabelled) fails.push(`${where}text-only ${at} has no text label`)
  for (const m of view.bounds.misnamed) if (m.ratio < 3) fails.push(`${where}text-only ${m.at} draws its ${m.by} at ${fmt(m.ratio)}:1; drop it or meet 3:1`)
  return { fails, weakest }
}
