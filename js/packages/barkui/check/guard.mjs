// The run-time half of "only part.css and the base styles style the stage".
// The demo lint names a styling line; this guard catches whatever dodges it.
// It reads the page from an isolated world over CDP, so page script (a demo, a
// press step) can neither see nor patch what it reads. It compares the page
// with the same build run without any demo (the baseline): the stylesheets,
// their rules, adopted sheets, and animations started from script. For style
// attributes it asks the census's world for placement's fails each time it
// looks (placement.mjs; docs/PARTS.md "Placement" says what is read and when).
import { source } from './probes.mjs'

// Runs in the isolated world. Rule text is read wherever the world may read it;
// a linked sheet it may not read counts by its file name.
const SNAPSHOT = `(() => {
  const rules = (s) => { try { return [...s.cssRules].map((r) => r.cssText).join('\\n') } catch { return null } }
  const tag = (e) => e.localName + (e.id ? '#' + e.id : '')
  const sheets = [...document.styleSheets].map((s) => ({ name: s.href ? s.href.split('/').pop() : '<' + (s.ownerNode ? s.ownerNode.localName : 'constructed') + '>', rules: rules(s) }))
  const roots = [document, ...[...document.querySelectorAll('*')].map((e) => e.shadowRoot).filter(Boolean)]
  const adopted = roots.flatMap((r) => [...r.adoptedStyleSheets].map(rules))
  const animated = document.getAnimations().filter((a) => !(a instanceof CSSTransition || a instanceof CSSAnimation)).map((a) => (a.effect && a.effect.target ? tag(a.effect.target) : 'the page'))
  return { sheets, adopted, animated }
})()`

/** Runs functions in an isolated world of the page's main frame: it shares the DOM with the page but
    none of its script, so nothing the page (a demo) does to its globals or prototypes reaches it.
    `fn` is serialised; it gets one JSON argument and may return a promise. */
const PROBE = {}
const FNS = {}
process.on('exit', () => { for (const [k, w] of Object.entries(PROBE)) console.log(`probe-world ${k}: ${w.n} calls, ${(w.all / 1000).toFixed(1)} s in all, rest ${(w.rest / 1000).toFixed(1)} s, run ${(w.run / 1000).toFixed(1)} s, gate ${w.gn} looks ${(w.gate / 1000).toFixed(1)} s`); for (const [k, f] of Object.entries(FNS).sort((a, b) => b[1].run - a[1].run).slice(0, 10)) console.log(`probe-fn ${(f.run / 1000).toFixed(1)} s ${f.n}x ${k}`) })
export async function isolate(page, name) {
  const cdp = await page.context().newCDPSession(page)
  const { frameTree } = await cdp.send('Page.getFrameTree')
  const { executionContextId } = await cdp.send('Page.createIsolatedWorld', { frameId: frameTree.frame.id, worldName: name, grantUniveralAccess: true })
  return async (fn, arg = null) => {
    // In a world with the check's helpers, every call first lets what moves and has an end come to rest, inside
    // settle's bound (toRest, probes.mjs): a call reads on a page at rest, or the gate there is red by name.
    const expression = `(async () => { const c = globalThis.__barkCheck; const g0 = c?.state?.gateMs ?? 0, n0 = c?.state?.gateN ?? 0; const t0 = performance.now(); await c?.toRest?.(); const t1 = performance.now(); const v = await (${source(fn)})(${JSON.stringify(arg)}); const t2 = performance.now(); return { v, rest: t1 - t0, run: t2 - t1, gate: (c?.state?.gateMs ?? 0) - g0, gn: (c?.state?.gateN ?? 0) - n0 } })()`
    const t = performance.now()
    const { result, exceptionDetails } = await cdp.send('Runtime.evaluate', { expression, contextId: executionContextId, returnByValue: true, awaitPromise: true })
    if (exceptionDetails) throw new Error(String(exceptionDetails.exception?.description ?? exceptionDetails.text).split('\n')[0])
    const w = (PROBE[name] ??= { n: 0, all: 0, rest: 0, run: 0, gate: 0, gn: 0 })
    const key = source(fn).replace(/\s+/g, ' ').slice(0, 90)
    const f = (FNS[key] ??= { n: 0, run: 0 }); f.n++; f.run += result.value.run
    w.n++; w.all += performance.now() - t; w.rest += result.value.rest; w.run += result.value.run; w.gate += result.value.gate; w.gn += result.value.gn
    return result.value.v
  }
}

/** A reader of the page's styling, in an isolated world of its own. */
export async function styleReader(page) {
  const run = await isolate(page, 'barkui-guard')
  return () => run(new Function(`return ${SNAPSHOT}`))
}

/** What changed between the baseline and now, in plain words, or null. */
export function styleChange(base, now) {
  if (now.animated.length) return `a script animation runs on ${now.animated[0]}`
  // Pair off identical sheets first; whatever is left over changed, arrived or went.
  const left = [...base.sheets]
  const extra = []
  for (const sh of now.sheets) {
    const i = left.findIndex((b) => b.name === sh.name && b.rules === sh.rules)
    if (i >= 0) left.splice(i, 1)
    else extra.push(sh)
  }
  for (const sh of extra) {
    if (left.some((b) => b.name === sh.name)) return `the rules changed in ${sh.name.startsWith('<') ? `a ${sh.name} sheet` : sh.name}`
    return `a stylesheet the build did not put there (${sh.name}${sh.rules ? `: ${sh.rules.slice(0, 60)}` : ''})`
  }
  if (left.length) return `a stylesheet the build put there is gone (${left[0].name})`
  if (now.adopted.length !== base.adopted.length || now.adopted.some((r, i) => r !== base.adopted[i]))
    return `an adopted stylesheet the build did not put there${now.adopted[0] ? ` (${now.adopted[0].slice(0, 60)})` : ''}`
  return null
}

/** Throws, naming what changed, when the page's styling differs from the baseline, or a style attribute in the
    stage has held more than placement, or a stage stands where it may not (each placement fail too, in one line). */
export async function assertStyles(page, base, when) {
  const placed = page.barkPlacement ? await page.barkPlacement() : []
  // The placement fails first: a sheet's rule text may run over lines.
  const change = [...placed, styleChange(base, await page.barkStyles())].filter(Boolean).join('; ')
  if (change) throw new Error(`styled outside part.css ${when}: ${change}`)
}
