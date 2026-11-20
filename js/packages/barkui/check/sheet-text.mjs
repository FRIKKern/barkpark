// A part sheet's rules as its text writes them, before any browser reads it. The check judges the rules the
// browser parsed (check/cssom.mjs), so it first holds the two side by side: a rule the text writes and the browser
// drops (a selector or condition it does not know) would ship with nothing judging it, and is refused by name.

/** The blocks of a sheet's text, in order: `{ prelude, blocks }`, each prelude as written with comments taken out
    and spaces collapsed, each block's own nested blocks inside it. Strings, escapes and comments are skipped, so a
    brace inside them opens nothing. */
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
      for (i++; i < css.length && css[i] !== c; i++) if (css[i] === '\\') i++
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

/** Runs in the page: the blocks of `written` (textBlocks) that the browser did not read into `rules`, container by
    container, as plain-word findings. Where the counts differ, each block is parsed alone in the same place (inside
    a style rule when it is nested), and each one the browser drops is named; a count that differs with no block to
    name is said as counts. Declarations that follow nested rules (CSSNestedDeclarations) are no rule of the text. */
export function unreadRules([written, rules]) {
  const found = []
  const isRule = (r) => !(typeof CSSNestedDeclarations === 'function' && r instanceof CSSNestedDeclarations)
  const reads = (b, nested) => {
    const sheet = new CSSStyleSheet()
    sheet.replaceSync(nested ? `:root { ${b.prelude} {} }` : `${b.prelude} {}`)
    const got = nested ? sheet.cssRules[0]?.cssRules : sheet.cssRules
    return [...(got ?? [])].filter(isRule).length === 1
  }
  const compare = (blocks, list, nested) => {
    const parsed = [...list].filter(isRule)
    let kept = blocks
    if (blocks.length !== parsed.length) {
      const lost = blocks.filter((b) => !reads(b, nested))
      for (const b of lost) found.push(`${b.prelude}: the browser drops this rule, so nothing would judge it; part.css holds only selectors and conditions the browser reads`)
      if (!lost.length) found.push(`the browser reads ${parsed.length} rule(s) where part.css writes ${blocks.length}, and none of them alone is dropped`)
      kept = blocks.filter((b) => !lost.includes(b))
    }
    if (kept.length === parsed.length) kept.forEach((b, k) => parsed[k].cssRules && compare(b.blocks, parsed[k].cssRules, nested || parsed[k] instanceof CSSStyleRule))
  }
  compare(written, rules, false)
  return found
}
