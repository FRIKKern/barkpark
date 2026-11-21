// The run-time half of "only part.css and the base styles style the stage".
// The demo lint names a styling line; this guard catches whatever dodges it.
// It reads the page from an isolated world over CDP, so page script (a demo, a
// press step) can neither see nor patch what it reads. It compares the page
// with the same build run without any demo (the baseline): the stylesheets,
// their rules, adopted sheets, and animations started from script. A style
// attribute in a stage may hold placement only: the census's world logs every
// value one holds from the first frame (placement.mjs), and the guard asks it
// for its fails each time it looks.
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
export async function isolate(page, name) {
  const cdp = await page.context().newCDPSession(page)
  const { frameTree } = await cdp.send('Page.getFrameTree')
  const { executionContextId } = await cdp.send('Page.createIsolatedWorld', { frameId: frameTree.frame.id, worldName: name, grantUniveralAccess: true })
  return async (fn, arg = null) => {
    const expression = `(${source(fn)})(${JSON.stringify(arg)})`
    const { result, exceptionDetails } = await cdp.send('Runtime.evaluate', { expression, contextId: executionContextId, returnByValue: true, awaitPromise: true })
    if (exceptionDetails) throw new Error(String(exceptionDetails.exception?.description ?? exceptionDetails.text).split('\n')[0])
    return result.value
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
    stage has held more than placement (every such fail, in one line). */
export async function assertStyles(page, base, when) {
  const placed = page.barkPlacement ? await page.barkPlacement() : []
  const change = styleChange(base, await page.barkStyles()) ?? (placed.length ? placed.join('; ') : null)
  if (change) throw new Error(`styled outside part.css ${when}: ${change}`)
}
