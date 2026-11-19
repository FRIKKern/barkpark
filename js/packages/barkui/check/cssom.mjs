// part.css as the browser parses it, wrapped in the bark-parts layer exactly as
// the build places it. The lint (build/css-lint.mjs) reads the text; this reads
// the rules Chromium builds from it: one bark-parts layer block, nothing beside
// it (a stray } that closes the layer early is refused), so a name the text spells
// one way and the browser reads another (an escape, a rule type the lint never
// heard of) meets the same walls. Everything here is an allow-list: style rules,
// their nested declarations, and @media for the conditions in MEDIA; the
// properties of the vocabulary, as the browser expands them (a left-out longhand
// a shorthand sets only at its initial value, and EXTRA's properties only at
// their values); animation names from KEYFRAMES only. Any other rule type,
// condition or property is refused.
import { inPartsLayer, SELECTOR_RULES } from '../build/css-lint.mjs'
import { EXTRA, KEYFRAMES, LEFT_OUT_INITIAL, MEDIA, MOTION_ONLY, VOCABULARY } from '../build/vocabulary.mjs'

/** What the browser makes of `css`: one message per thing it may not hold. */
export async function readPartCss(browser, css) {
  const context = await browser.newContext()
  try {
    const page = await context.newPage()
    const { found, selectors } = await page.evaluate(
      ([css, vocabulary, motionOnly, extra, leftOut, keyframes, media]) => {
        const found = []
        const selectors = []
        // Every longhand a vocabulary property sets, as this browser expands it.
        const covers = new Set()
        const motion = new Set()
        for (const v of vocabulary) {
          const s = document.createElement('div').style
          s.setProperty(v, 'inherit')
          for (const l of s.length ? [...s] : [v]) {
            covers.add(l)
            if (motionOnly.includes(v)) motion.add(l)
          }
        }
        const declarations = (style, inMotion, where) => {
          for (let i = 0; i < style.length; i++) {
            const p = style[i]
            if (p.startsWith('--')) continue
            const v = style.getPropertyValue(p).trim()
            if (inMotion && !motion.has(p)) found.push(`${where}: ${p} inside @media (prefers-reduced-motion): only transition, animation and scroll-behavior properties may change there`)
            else if (extra[p]) {
              if (!extra[p].includes(v)) found.push(`${where}: ${p}: ${v}; it may only be ${extra[p].join(' or ')}`)
            } else if (leftOut[p]) {
              if (v && v !== 'initial' && !leftOut[p].includes(v)) found.push(`${where}: ${p}: ${v}; a shorthand may leave ${p} only at ${leftOut[p][0]}`)
            } else if (!covers.has(p)) found.push(`${where}: ${p} is outside part.css's vocabulary`)
            if (p === 'animation-name')
              for (const n of v.split(',').map((x) => x.trim()))
                if (n && n !== 'none' && !keyframes.includes(n)) found.push(`${where}: animation-name ${n}; a part names only the shared keyframes (${keyframes.join(', ')})`)
          }
        }
        const walk = (rules, inMotion) => {
          for (const r of rules) {
            if (r instanceof CSSStyleRule) {
              selectors.push(r.selectorText)
              declarations(r.style, inMotion, r.selectorText)
              walk(r.cssRules, inMotion)
            } else if (typeof CSSNestedDeclarations === 'function' && r instanceof CSSNestedDeclarations) declarations(r.style, inMotion, 'nested declarations')
            else if (r instanceof CSSMediaRule) {
              if (!media.includes(r.conditionText)) found.push(`@media ${r.conditionText}: not a view the check renders`)
              walk(r.cssRules, inMotion || /prefers-reduced-motion/.test(r.conditionText))
            } else found.push(`${r.constructor.name} "${r.cssText.replace(/\s+/g, ' ').slice(0, 60)}": not a rule part.css may hold`)
          }
        }
        const sheet = new CSSStyleSheet()
        sheet.replaceSync(css)
        const top = [...sheet.cssRules]
        if (top.length === 1 && top[0] instanceof CSSLayerBlockRule && top[0].name === 'bark-parts') walk(top[0].cssRules, false)
        else found.push(`the page would hold ${top.length} rule(s) where part.css's one bark-parts layer belongs: a brace closes the layer early, or a rule stands outside it`)
        return { found, selectors }
      },
      [inPartsLayer(css), [...VOCABULARY], [...MOTION_ONLY], EXTRA, LEFT_OUT_INITIAL, KEYFRAMES, MEDIA],
    )
    for (const s of selectors) for (const [re, say] of SELECTOR_RULES) for (const m of s.matchAll(new RegExp(re.source, 'gi'))) found.push(`${s}: ${say(m)}`)
    return found
  } finally {
    await context.close()
  }
}
