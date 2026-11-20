// A part sheet's rules as its text writes them, before any browser reads it. The check judges the rules the
// browser parsed (check/cssom.mjs), so it first holds the two side by side: a rule the text writes and the browser
// drops whole (a selector or condition it does not know) would ship with nothing judging it, and is refused by name;
// a sheet the check cannot read rule for rule the way the browser does is refused too.

/** The blocks of a sheet's text, in order: `{ prelude, blocks }`, each prelude as written with comments taken out
    and spaces collapsed, each block's own nested blocks inside it. Strings, escapes and comments are skipped, so a
    brace inside them opens nothing; a string ends at an unescaped newline, where the browser ends it too. */
export function textBlocks(css) {
  const root = { prelude: null, blocks: [] }
  const stack = [root]
  let from = 0
  for (let i = 0; i < css.length; i++) {
    const c = css[i]
    if (c === '/' && css[i + 1] === '*') {
      const end = css.indexOf('*/', i + 2)
      i = end < 0 ? css.length : end + 1
    } else if (c === '\\') i++
    else if (c === '"' || c === "'") {
      for (i++; i < css.length && css[i] !== c && css[i] !== '\n'; i++) if (css[i] === '\\') i++
    } else if (c === '{') {
      const block = { prelude: clean(css.slice(from, i)), blocks: [] }
      stack.at(-1).blocks.push(block)
      stack.push(block)
      from = i + 1
    } else if (c === '}') {
      if (stack.length > 1) stack.pop()
      from = i + 1
    } else if (c === ';') from = i + 1
  }
  return root.blocks
}

const clean = (text) => text.replace(/\/\*[^]*?\*\//g, ' ').replace(/\s+/g, ' ').trim()

/** Runs in the page, so it holds no outside name: the browser's two readings of a part sheet. `alone` mirrors
    `written` (textBlocks): each block given to the browser alone, in its place inside the blocks it is written in,
    as the heads of the rules that come back (null when the place itself does not come back as one rule each), with
    its own blocks read the same way when it came back as exactly one. `whole` is `rules`, the rules the browser made
    from the whole sheet, as heads with the rules inside each. Declarations that follow nested rules
    (CSSNestedDeclarations) are no rule of the text. */
export function browserReadings([written, rules]) {
  const isRule = (r) => !(typeof CSSNestedDeclarations === 'function' && r instanceof CSSNestedDeclarations)
  const head = (r) =>
    `${r.constructor.name} ${r.selectorText ?? r.conditionText ?? r.media?.mediaText ?? r.keyText ?? r.name ?? r.nameList?.join(', ') ?? ''}`.trim()
  const tree = (list) => [...list].filter(isRule).map((r) => ({ head: head(r), rules: r.cssRules ? tree(r.cssRules) : [] }))
  const parseIn = (chain, prelude) => {
    const sheet = new CSSStyleSheet()
    try {
      sheet.replaceSync(chain.reduceRight((inner, outer) => `${outer} { ${inner} }`, `${prelude} {}`))
    } catch {
      return null
    }
    let list = [...sheet.cssRules].filter(isRule)
    for (let depth = 0; depth < chain.length; depth++) {
      if (list.length !== 1 || !list[0].cssRules) return null
      list = [...list[0].cssRules].filter(isRule)
    }
    return list.map(head)
  }
  const alone = (blocks, chain) =>
    blocks.map((b) => {
      const heads = parseIn(chain, b.prelude)
      return { heads, blocks: heads?.length === 1 ? alone(b.blocks, [...chain, b.prelude]) : [] }
    })
  return { alone: alone(written, []), whole: tree(rules) }
}

/** The findings, in plain words, from holding the sheet's text (textBlocks) against the browser's readings
    (browserReadings), level by level. A block that alone comes back as no rule is a rule the browser drops, refused
    by name. Any other disagreement fails closed, whatever its cause: a block that alone comes back as more than one
    rule, or not in its place, and the rules read alone against the rules of the whole sheet in a different number,
    order or text. The text reader need not be a whole CSS parser, since where it and the browser differ the sheet
    is refused, not passed. Runs in the page as well, so it holds no outside name. */
export function sheetFindings([written, { alone, whole }]) {
  const found = []
  const cannot = (where, what) => found.push(`the check cannot read this sheet the way the browser does: ${where}: ${what}`)
  const compare = (blocks, readings, rules, path) => {
    const where = path.length ? `inside ${path.join(' { ')}` : 'at the top of part.css'
    const kept = []
    blocks.forEach((b, i) => {
      const { heads, blocks: inner } = readings[i]
      if (heads === null) cannot(where, `${b.prelude} does not read alone in its place`)
      else if (heads.length === 0) found.push(`${b.prelude}: the browser drops this rule, so nothing would judge it; part.css holds only selectors and conditions the browser reads`)
      else if (heads.length > 1) cannot(where, `${b.prelude} reads as ${heads.length} rules alone`)
      else kept.push({ b, head: heads[0], inner })
    })
    if (kept.length !== rules.length)
      return cannot(where, `part.css writes ${kept.length} rule(s) the browser reads alone, and the browser reads ${rules.length} from the whole sheet`)
    kept.forEach(({ b, head, inner }, k) => {
      if (head !== rules[k].head) cannot(where, `rule ${k + 1} reads as "${head}" alone and as "${rules[k].head}" in the whole sheet`)
      else compare(b.blocks, inner, rules[k].rules, [...path, b.prelude])
    })
  }
  compare(written, alone, whole, [])
  return found
}
