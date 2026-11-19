// part.css as the browser parses it, wrapped in the bark-parts layer exactly as
// the build places it. The lint (build/css-lint.mjs) reads the text; this reads
// the rules Chromium builds from it: one bark-parts layer block, nothing beside
// it (a stray } that closes the layer early is refused), so a name the text spells
// one way and the browser reads another (an escape, a rule type the lint never
// heard of) meets the same walls. Everything here is an allow-list: style rules,
// their nested declarations, and @media for the conditions in MEDIA; the
// properties of the vocabulary, as the browser expands them (a left-out longhand
// a shorthand sets only at its initial value, and EXTRA's properties only at
// their values); animation names from KEYFRAMES only; inside the phone
// breakpoint only PHONE_ONLY (layout and type); selectors to the pseudo-classes
// and pseudo-elements in check/selectors.mjs, a pinned state only on the element
// a rule styles. Any other rule type, condition, property or selector is refused.
//
// The page loads every part in one barkui.css, so part.css must also end where
// its rules end: a rule placed after it (SENTINEL) must come back as a rule of
// its own, last in the layer. And what the page loads must be what was judged:
// sameAsShipped parses the built barkui.css as the page loads it and holds each
// part's section to the rules read here, alone.
import { inPartsLayer, SELECTOR_RULES } from '../build/css-lint.mjs'
import { pinStates } from '../build/showroom.mjs'
import { EXTRA, KEYFRAMES, LEFT_OUT_INITIAL, MEDIA, MOTION_ONLY, PHONE, PHONE_ONLY, VOCABULARY } from '../build/vocabulary.mjs'
import { readFileSync } from 'node:fs'
import { resolve, selectorFindings, statesOnSubject, strip, unpinned } from './selectors.mjs'

const SENTINEL = '[data-barkui-sentinel] { gap: 0px; }'

// Runs in the page: every rule of a list as the browser serialises it, nested rules after their parent, one
// string each, so two parses compare rule by rule.
const RULES = `(rules) => {
  const out = []
  const walk = (list, depth) => {
    for (const r of list) {
      const pad = '  '.repeat(depth)
      if (r instanceof CSSStyleRule) out.push(pad + r.selectorText + ' { ' + r.style.cssText + ' }')
      else if (r instanceof CSSMediaRule) out.push(pad + '@media ' + r.conditionText)
      else if (typeof CSSNestedDeclarations === 'function' && r instanceof CSSNestedDeclarations) out.push(pad + r.style.cssText)
      else out.push(pad + r.cssText)
      if (r.cssRules) walk(r.cssRules, depth + 1)
    }
  }
  walk(rules, 0)
  return out
}`

/** What the browser makes of `css`: `found`, one message per thing it may not hold; `rules`, the pinned part as
    the page would hold it, rule by rule (sameAsShipped). */
export async function readPartCss(browser, css) {
  const context = await browser.newContext()
  try {
    const page = await context.newPage()
    const { found, selectors, rules, pinnedSelectors } = await page.evaluate(
      ([texts, sentinel, rulesSrc, vocabulary, motionOnly, extra, leftOut, keyframes, media, phone, phoneOnly]) => {
        const found = []
        const selectors = []
        // Every longhand a vocabulary property sets, as this browser expands it.
        const covers = new Set()
        const motion = new Set()
        const narrow = new Set()
        for (const v of vocabulary) {
          const s = document.createElement('div').style
          s.setProperty(v, 'inherit')
          for (const l of s.length ? [...s] : [v]) {
            covers.add(l)
            if (motionOnly.includes(v)) motion.add(l)
            if (phoneOnly.includes(v)) narrow.add(l)
          }
        }
        // A shorthand outside the phone list can expand into longhands inside it, so a longhand counts as layout or
        // type only if no paint property in the vocabulary sets it too.
        for (const v of vocabulary) {
          if (phoneOnly.includes(v)) continue
          const s = document.createElement('div').style
          s.setProperty(v, 'inherit')
          for (const l of s) narrow.delete(l)
        }
        // A var() with a fallback anywhere in a declaration block: the browser keeps var() as written.
        const fallback = (text) => {
          for (let i = text.indexOf('var('); i >= 0; i = text.indexOf('var(', i + 1)) {
            let depth = 0
            for (let j = i + 3; j < text.length; j++) {
              const c = text[j]
              if (c === '"' || c === "'") {
                for (j++; j < text.length && text[j] !== c; j++) if (text[j] === '\\') j++
              } else if (c === '(') depth++
              else if (c === ')' && !--depth) break
              else if (c === ',' && depth === 1) return text.slice(i, j + 1)
            }
          }
          return null
        }
        const declarations = (style, { inMotion, inPhone }, where) => {
          const fb = fallback(style.cssText)
          if (fb) found.push(`${where}: ${fb}… gives a variable a fallback; the sheet sets every variable`)
          for (let i = 0; i < style.length; i++) {
            const p = style[i]
            if (style.getPropertyPriority(p) === 'important') found.push(`${where}: ${p} is !important; part.css wins by its layer alone`)
            if (inPhone && !narrow.has(p)) found.push(`${where}: ${p} inside @media ${phone}: only layout and type may change at phone width (no paint, no decoration, no custom property)`)
            const still = inMotion && !motion.has(p)
            if (still) found.push(`${where}: ${p} inside @media (prefers-reduced-motion): only transition, animation and scroll-behavior properties may change there`)
            if (p.startsWith('--')) continue
            const v = style.getPropertyValue(p).trim()
            if (still) continue
            if (extra[p]) {
              if (!extra[p].includes(v)) found.push(`${where}: ${p}: ${v}; it may only be ${extra[p].join(' or ')}`)
            } else if (leftOut[p]) {
              if (v && v !== 'initial' && !leftOut[p].includes(v)) found.push(`${where}: ${p}: ${v}; a shorthand may leave ${p} only at ${leftOut[p][0]}`)
            } else if (!covers.has(p)) found.push(`${where}: ${p} is outside part.css's vocabulary`)
            if (p === 'animation-name')
              for (const n of v.split(',').map((x) => x.trim()))
                if (n && n !== 'none' && !keyframes.includes(n)) found.push(`${where}: animation-name ${n}; a part names only the shared keyframes (${keyframes.join(', ')})`)
          }
        }
        const walk = (rules, at, parent) => {
          for (const r of rules) {
            if (r instanceof CSSStyleRule) {
              selectors.push({ text: r.selectorText, parent, media: at.media, decls: r.style.length })
              declarations(r.style, at, r.selectorText)
              walk(r.cssRules, at, selectors.length - 1)
            } else if (typeof CSSNestedDeclarations === 'function' && r instanceof CSSNestedDeclarations) declarations(r.style, at, 'nested declarations')
            else if (r instanceof CSSMediaRule) {
              if (!media.includes(r.conditionText)) found.push(`@media ${r.conditionText}: not a view the check renders`)
              walk(r.cssRules, { inMotion: at.inMotion || /prefers-reduced-motion/.test(r.conditionText), inPhone: at.inPhone || r.conditionText === phone, media: [...at.media, r.conditionText] }, parent)
            } else found.push(`${r.constructor.name} "${r.cssText.replace(/\s+/g, ' ').slice(0, 60)}": not a rule part.css may hold`)
          }
        }
        const ruleList = (0, eval)(rulesSrc)
        // The layer's rules, or null when the text does not hold one bark-parts layer whose last rule is the sentinel.
        const layer = (text, say) => {
          const sheet = new CSSStyleSheet()
          sheet.replaceSync(text)
          const top = [...sheet.cssRules]
          if (!(top.length === 1 && top[0] instanceof CSSLayerBlockRule && top[0].name === 'bark-parts')) {
            if (say) found.push(`the page would hold ${top.length} rule(s) where part.css's one bark-parts layer belongs: a brace closes the layer early, or a rule stands outside it`)
            return null
          }
          const rules = [...top[0].cssRules]
          const end = rules.at(-1)
          if (!(end instanceof CSSStyleRule && ruleList([end]).join('\n') === sentinel)) {
            if (say) found.push(`part.css does not end where its rules end: a rule placed after it is not read as a rule of its own (an open bracket, parenthesis, string or comment runs on into what follows it on the page)`)
            return null
          }
          return rules.slice(0, -1)
        }
        const asWritten = layer(texts.asWritten, true)
        if (asWritten) walk(asWritten, { inMotion: false, inPhone: false, media: [] }, -1)
        const pinned = asWritten && layer(texts.pinned, true)
        const pinnedSelectors = []
        if (pinned) {
          const all = (list) => {
            for (const r of list) {
              if (r instanceof CSSStyleRule) pinnedSelectors.push(r.selectorText)
              if (r.cssRules) all(r.cssRules)
            }
          }
          all(pinned)
        }
        return { found, selectors, rules: pinned ? ruleList(pinned) : null, pinnedSelectors }
      },
      [{ asWritten: inPartsLayer(`${css}\n${SENTINEL}`), pinned: pinStates(inPartsLayer(`${css}\n${SENTINEL}`)) }, SENTINEL, RULES, [...VOCABULARY], [...MOTION_ONLY], EXTRA, LEFT_OUT_INITIAL, KEYFRAMES, MEDIA, PHONE, [...PHONE_ONLY]],
    )
    const has = []
    selectors.forEach((s, i) => {
      const parentHas = s.parent >= 0 && has[s.parent]
      has[i] = statesOnSubject(s.text, parentHas)
      for (const f of selectorFindings(s.text, parentHas)) found.push(`${s.text}: ${f}`)
      for (const [re, say] of SELECTOR_RULES) for (const m of s.text.matchAll(new RegExp(re.source, 'gi'))) found.push(`${s.text}: ${say(m)}`)
    })
    // The pin must reach every state, whatever case or spacing the text gave it.
    for (const s of pinnedSelectors) for (const p of unpinned(s)) found.push(`${s}: ${p} is not pinned in the showroom; data-pin cannot show it`)
    return { found, rules, entries: found.length ? [] : ruleEntries(selectors, pinnedSelectors) }
  } finally {
    await context.close()
  }
}

/** Each rule of the part that sets anything, for the coverage reading (check/coverage.mjs): `label`, its selector
    made absolute; `now`, the selector the page holds (states pinned), less any pseudo-element, which an element
    matches while the rule applies to it; `rest`, the same with its states taken out, which an element matches when
    a state is all it needs; `states`, those states; `media`, the conditions it sits in. */
function ruleEntries(selectors, pinned) {
  const label = []
  const now = []
  const rest = []
  const states = []
  const entries = []
  selectors.forEach((s, i) => {
    const up = s.parent >= 0 ? s.parent : null
    label[i] = resolve(s.text, up === null ? null : label[up])
    now[i] = resolve(pinned[i], up === null ? null : now[up])
    const own = strip(s.text)
    rest[i] = strip(resolve(s.text, up === null ? null : rest[up])).selector
    states[i] = [...new Set([...own.states, ...(up !== null && statesOnSubject(s.text, true) ? states[up] : [])])]
    if (s.decls) entries.push({ label: label[i], now: strip(now[i]).selector, rest: rest[i], states: states[i], media: s.media })
  })
  return entries
}

/** The page's own barkui.css (`file`, the sheet index.html links), parsed whole in the same browser: each part's
    bark-parts section must hold, rule by rule, what readPartCss read from that part alone (`judged`:
    [{ name, rules }], in folder order). A page opened from disk may not read its own sheet's rules, so the file's
    text goes to the same parser through a constructed sheet (it holds no @import, which only that would drop).
    One message per part whose section differs; anything after the parts (the selftest's plant) is not a part. */
export async function sameAsShipped(browser, file, judged) {
  const context = await browser.newContext()
  try {
    const page = await context.newPage()
    const sections = await page.evaluate(
      ([text, rulesSrc]) => {
        const ruleList = (0, eval)(rulesSrc)
        const sheet = new CSSStyleSheet()
        sheet.replaceSync(text)
        return [...sheet.cssRules].filter((r) => r instanceof CSSLayerBlockRule && r.name === 'bark-parts').map((r) => ruleList(r.cssRules))
      },
      [readFileSync(file, 'utf8'), RULES],
    )
    const found = []
    judged.forEach(({ name, rules }, i) => {
      const got = sections[i]
      if (!got) return found.push(`parts/${name}/part.css: the page's barkui.css holds no section for it`)
      const at = Math.max(got.length, rules.length)
      for (let k = 0; k < at; k++) {
        if (got[k] === rules[k]) continue
        const [a, b] = [(got[k] ?? 'missing').trim(), (rules[k] ?? 'missing').trim()]
        let d = 0
        while (a[d] === b[d]) d++
        const near = (x) => JSON.stringify(`${d > 30 ? '…' : ''}${x.slice(Math.max(0, d - 30), d + 50)}`)
        return found.push(`parts/${name}/part.css: the page's barkui.css does not hold what the check read from it alone; at its rule ${k + 1} the page has ${near(a)} where the part alone has ${near(b)}`)
      }
    })
    if (!found.length && sections.length !== judged.length) found.push(`the page's barkui.css holds ${sections.length} part sections for ${judged.length} part(s)`)
    return found
  } finally {
    await context.close()
  }
}
