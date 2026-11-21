// Selectors as the browser hands them back (CSSStyleRule.selectorText): lowercase pseudo-class names, one space
// around combinators, strings in double quotes. The browser gives no structure, only that text, so this reads its
// grammar: compounds split by combinators at the top level, and every pseudo-class and pseudo-element with how
// deep it sits inside functional pseudo-classes. Then it holds a part's selectors to an allow-list.

// The states the showroom pins with data-pin (build/showroom.mjs pinStates). One may appear only on the element
// the selector styles (its last compound, not inside :not(), :has() and the like), so data-pin on that element
// shows it; never on a host, ancestor or sibling, where no pin can reach. The check drives each one with real
// input (check/states.mjs): the pointer for hover and active, a click for checked.
export const PINNED = ['hover', 'active', 'focus-visible', 'checked']
// Every other pseudo-class part.css may use, anywhere: structure and the element's own attributes, nothing that a
// person's pointer, keys, typing or history sets. Anything else (:focus, :target, :placeholder-shown, ...) is
// refused until it joins PINNED with a way for the check to drive it: here when the browser reads the rule, and by
// check/sheet-text.mjs when the browser drops the whole rule for a name it does not know. tests/selectors.test.mjs
// pins this list whole, each name with its reason, so a name added or taken out is red until that reason is written
// beside it.
export const STATIC = ['not', 'is', 'where', 'has', 'defined', 'first-child', 'last-child', 'only-child', 'nth-child', 'nth-last-child', 'first-of-type', 'last-of-type', 'only-of-type', 'nth-of-type', 'nth-last-of-type']
// The pseudo-elements the check reads (docs/PARTS.md "Read").
export const PSEUDO_ELEMENTS = ['before', 'after', 'marker', 'placeholder']

/** One selector list read into complex selectors, each a list of compounds: { nest, pseudos: [{ name, element, depth }] }. */
export function readSelectorList(text) {
  const list = []
  let compounds = [{ nest: false, nestInside: false, pseudos: [] }]
  let depth = 0
  let bracket = 0
  const last = () => compounds[compounds.length - 1]
  const cut = () => last().pseudos.length || last().nest || last().text ? compounds.push({ nest: false, nestInside: false, pseudos: [] }) : null
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (c === '\\') {
      last().text = true
      i++
      continue
    }
    if (c === '"' || c === "'") {
      for (i++; i < text.length && text[i] !== c; i++) if (text[i] === '\\') i++
      last().text = true
      continue
    }
    if (c === '[') bracket++
    else if (c === ']') bracket--
    if (bracket) {
      last().text = true
      continue
    }
    if (c === '(') depth++
    else if (c === ')') depth--
    else if (depth === 0 && c === ',') {
      list.push(compounds.filter((x) => x.pseudos.length || x.nest || x.text))
      compounds = [{ nest: false, nestInside: false, pseudos: [] }]
    } else if (depth === 0 && /[\s>+~]/.test(c)) cut()
    else if (c === '&') depth === 0 ? (last().nest = true) : (last().nestInside = true)
    else if (c === ':') {
      const element = text[i + 1] === ':'
      const m = text.slice(i + (element ? 2 : 1)).match(/^-?[\w-]+/)
      if (m) last().pseudos.push({ name: m[0].toLowerCase(), element, depth })
      i += (element ? 1 : 0) + (m ? m[0].length : 0)
      last().text = true
    } else last().text = true
  }
  list.push(compounds.filter((x) => x.pseudos.length || x.nest || x.text))
  return list
}

/** Whether a selector, read as above, pins a state on the element it styles (directly, or through & from its parent's). */
export function statesOnSubject(text, parentHas = false) {
  return readSelectorList(text).some((compounds) => {
    const subject = compounds[compounds.length - 1] ?? { pseudos: [] }
    return subject.pseudos.some((p) => !p.element && p.depth === 0 && PINNED.includes(p.name)) || (parentHas && subject.nest)
  })
}

/** What part.css may not hold in one selector. `parentHas`: the rule it is nested in pins a state on its own element. */
export function selectorFindings(text, parentHas = false) {
  const found = []
  for (const compounds of readSelectorList(text)) {
    compounds.forEach((c, i) => {
      const subject = i === compounds.length - 1
      for (const p of c.pseudos) {
        if (p.element) {
          if (!PSEUDO_ELEMENTS.includes(p.name)) found.push(`::${p.name} is not a pseudo-element the check reads (${PSEUDO_ELEMENTS.map((n) => `::${n}`).join(', ')})`)
        } else if (PINNED.includes(p.name)) {
          if (!subject || p.depth > 0) found.push(`:${p.name} is on a host, ancestor or sibling, or inside another pseudo-class, where no data-pin reaches; a state may stand only on the element the rule styles`)
        } else if (!STATIC.includes(p.name)) found.push(`:${p.name} is not a pseudo-class part.css may use (states on the styled element: ${PINNED.map((n) => `:${n}`).join(', ')}; and ${STATIC.map((n) => `:${n}`).join(', ')})`)
      }
      // The parent pins a state on its own element; here & stands for it, and it must stay the element styled.
      if (parentHas && (c.nestInside || (c.nest && !subject))) found.push(`the rule it is nested in pins a state, and & here is a host, ancestor or sibling of what this rule styles`)
    })
    const subject = compounds[compounds.length - 1]
    if (parentHas && subject && !subject.nest && !subject.nestInside && !compounds.some((c) => c.nest || c.nestInside))
      found.push(`the rule it is nested in pins a state, and this rule styles a descendant of that element`)
  }
  return [...new Set(found)]
}

/** The states of a pinned sheet that the pin did not reach: each must read `:is(:x, [data-pin~="x"])`. */
export function unpinned(text) {
  let rest = text
  for (const s of PINNED) rest = rest.split(`:is(:${s}, [data-pin~="${s}"])`).join('')
  return [...new Set(readSelectorList(rest).flatMap((cs) => cs.flatMap((c) => c.pseudos.filter((p) => !p.element && PINNED.includes(p.name)).map((p) => `:${p.name}`))))]
}

/** Walks a selector's text as the browser wrote it, calling `at(i, depth)` for each character outside strings,
    escapes and attribute brackets; `at` returns how many characters to skip, or nothing. */
function scan(text, at) {
  let depth = 0
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (c === '\\') {
      i++
      continue
    }
    if (c === '"' || c === "'") {
      for (i++; i < text.length && text[i] !== c; i++) if (text[i] === '\\') i++
      continue
    }
    if (c === '[') {
      for (i++; i < text.length && text[i] !== ']'; i++) if (text[i] === '"' || text[i] === "'") for (const q = text[i++]; i < text.length && text[i] !== q; i++) if (text[i] === '\\') i++
      continue
    }
    if (c === '(') depth++
    else if (c === ')') depth--
    i += at(i, depth, c) ?? 0
  }
}

/** A selector list split at its top-level commas. */
export function splitList(text) {
  const out = []
  let from = 0
  scan(text, (i, depth, c) => {
    if (c === ',' && depth === 0) {
      out.push(text.slice(from, i).trim())
      from = i + 1
    }
  })
  out.push(text.slice(from).trim())
  return out
}

/** A nested rule's selector made absolute: each & stands for its parent's selector. */
export function resolve(text, parent) {
  if (!parent) return text
  let out = ''
  let from = 0
  scan(text, (i, depth, c) => {
    if (c === '&') {
      out += `${text.slice(from, i)}:is(${parent})`
      from = i + 1
    }
  })
  return out + text.slice(from)
}

/** A selector with its pinned states (top level of a compound) and pseudo-elements taken out, so an element can be
    asked whether it matches the rest; plus the states taken out. */
export function strip(text) {
  const states = new Set()
  const parts = splitList(text).map((item) => {
    let out = ''
    let from = 0
    scan(item, (i, depth, c) => {
      if (c !== ':') return
      const element = item[i + 1] === ':'
      const m = item.slice(i + (element ? 2 : 1)).match(/^-?[\w-]+/)
      if (!m) return
      const name = m[0].toLowerCase()
      const len = (element ? 2 : 1) + m[0].length
      if (element || (depth === 0 && PINNED.includes(name))) {
        if (!element) states.add(name)
        // A compound left empty (`:hover` alone, `a > ::before`) is any element.
        const lone = (i === 0 || /[\s>+~(,]/.test(item[i - 1])) && (i + len >= item.length || /[\s>+~),]/.test(item[i + len]))
        out += item.slice(from, i) + (lone ? '*' : '')
        from = i + len
      }
      return len - 1
    })
    return (out + item.slice(from)).trim()
  })
  return { selector: parts.join(', '), states: [...states] }
}
