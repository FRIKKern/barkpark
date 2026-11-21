// Coverage is checked, not assumed. Every judged reading (each readView, in every light) first records which of
// the part's rules apply right then, and to which stage elements, by asking the browser: element.matches with the
// selector the page holds, inside the media conditions that hold in that page. After a full run, a rule that sets
// anything and never applied at a judged moment fails the part ("a rule nothing read"), and so does any pair of a
// state rule and a live control that states.mjs had to drive but no reading saw. A rule with a selector list is read
// branch by branch: a branch that never applied fails it too ("a branch nothing read"), so a dead branch cannot hide
// behind one that applies.

/** Runs in the check's world: the (rule, element) pairs that apply now, as rule * 1e5 + element, elements by index
    in [stage, ...its descendants]; and, for a rule of more than one branch, each branch that applies now, as
    `rule.branch`. */
export function cover([n, entries]) {
  const root = document.querySelector(`[data-part="${n}"]`)
  const els = [root, ...root.querySelectorAll('*')]
  const hits = []
  const branches = []
  entries.forEach((e, k) => {
    if (!e.media.every((m) => matchMedia(m).matches)) return
    els.forEach((el, i) => el.matches(e.now) && hits.push(k * 1e5 + i))
    if (e.branches.length > 1) e.branches.forEach((b, j) => els.some((el) => el.matches(b.now)) && branches.push(`${k}.${j}`))
  })
  return { hits, branches }
}

/** From now on, every reading of this page records what applies (reading.mjs calls page.barkCover first). */
export function installCover(page, ctx) {
  if (!ctx.entries) return
  ctx.branchesRead ??= new Set()
  page.barkCover = async () => {
    const { hits, branches } = await page.barkCheck(cover, [ctx.part, ctx.entries])
    for (const x of hits) ctx.judged.add(x)
    for (const b of branches) ctx.branchesRead.add(b)
  }
}

/** Every rule and every driven pair that no judged reading saw, in plain words. */
export function unread(ctx) {
  const seen = new Set([...ctx.judged].map((x) => Math.floor(x / 1e5)))
  const read = ctx.branchesRead ?? new Set()
  const out = ctx.entries.flatMap((e, k) => {
    if (!seen.has(k)) return [`a rule nothing read: ${e.label} applies to nothing in the stage at any moment the lights read`]
    if (e.branches.length < 2) return []
    return e.branches.flatMap((b, j) => (read.has(`${k}.${j}`) ? [] : [`a branch nothing read: ${b.label}, of ${e.label}, applies to nothing in the stage at any moment the lights read`]))
  })
  for (const p of ctx.pairs) if (!ctx.judged.has(p.rule * 1e5 + p.el)) out.push(`a pair nothing read: ${ctx.entries[p.rule].label} on ${p.at}`)
  return out
}
