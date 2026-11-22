// A part sheet's rules as its text writes them, before any browser reads it. The check judges the rules the
// browser parsed (check/cssom.mjs), so it first holds the two side by side: a rule the text writes and the browser
// drops whole (a selector or condition it does not know) would ship with nothing judging it, and is refused by name.
// The text lint has already refused a sheet outside the part-sheet forms (sheetForms in build/css-lint.mjs).

import { choiceLists, splitList } from './selectors.mjs'

/** The blocks of a sheet's text, in order: `{ prelude, body, blocks }`, each prelude as written with comments taken
    out and spaces collapsed, each body the text between the block's braces as written, each block's own nested
    blocks inside it. Strings, escapes and comments are skipped, so a
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
      const block = { prelude: clean(css.slice(from, i)), body: null, blocks: [], open: i + 1 }
      stack.at(-1).blocks.push(block)
      stack.push(block)
      from = i + 1
    } else if (c === '}') {
      if (stack.length > 1) {
        const block = stack.pop()
        block.body = css.slice(block.open, i)
      }
      from = i + 1
    } else if (c === ';') from = i + 1
  }
  // A block the text never closes runs to its end, as the browser reads it.
  for (const block of stack.slice(1)) block.body = css.slice(block.open)
  const bare = (blocks) => blocks.map(({ prelude, body, blocks: inner }) => ({ prelude, body, blocks: bare(inner) }))
  return bare(root.blocks)
}

/** The arms each style block's text writes, for the browser to read one by one (browserReadings): every arm of its
    own selector list, and the one selector inside each :is() and :where(), where the browser drops an arm it does
    not know and keeps the rule. A list inside :is(), :where() or :has() is refused here, from the text: an arm in
    there is a choice coverage cannot see (docs/PARTS.md "every branch"). Returns the blocks with their arms, and the
    findings. */
export function textArms(blocks) {
  const found = []
  const walk = (list) =>
    list.map((b) => {
      if (b.prelude.startsWith('@')) return { ...b, arms: [], blocks: walk(b.blocks) }
      const lists = choiceLists(b.prelude)
      for (const c of lists)
        if (c.arms.length > 1)
          found.push(`${b.prelude}: :${c.name}(${c.arms.join(', ')}) holds a list of ${c.arms.length}; coverage reads a rule branch by branch, and an arm inside :${c.name}() is not a branch, so one that applies would hide one that never does; write each arm as a branch of the rule's own list`)
      const choices = lists.filter((c) => c.name !== 'has')
      const inner = choices.flatMap((c) => c.arms)
      // Each call's own prelude with that call emptied: the browser reads the arm in its real place beside it.
      const within = choices.flatMap((c) =>
        c.arms.map((arm) => ({ name: c.name, arm, emptied: b.prelude.slice(0, c.at[0]) + b.prelude.slice(c.at[1]) })),
      )
      return { ...b, arms: [...new Set([...splitList(b.prelude), ...inner])], within, blocks: walk(b.blocks) }
    })
  return { written: walk(blocks), found }
}

const clean = (text) => text.replace(/\/\*[^]*?\*\//g, ' ').replace(/\s+/g, ' ').trim()

/** Runs in the page, so it holds no outside name: the browser's two readings of a part sheet. `alone` mirrors
    `written` (textBlocks): each block, with the body its text gives it, given to the browser alone in its place
    inside the blocks it is written in, as the text (cssText) of each rule that comes back (null when the place itself
    does not come back as one rule each); when it came back as exactly one, the arms of it (textArms) that the
    browser drops when each is read alone in the same place, or, for the one inside :is() or :where(), in the rule's
    own prelude beside that prelude with the call emptied, and its own blocks read the same way.
    `whole` is `rules`, the rules the browser made from the whole sheet, as their text with the rules inside each.
    Declarations that follow nested rules (CSSNestedDeclarations) are no rule of the text. */
export function browserReadings([written, rules]) {
  const isRule = (r) => !(typeof CSSNestedDeclarations === 'function' && r instanceof CSSNestedDeclarations)
  const tree = (list) => [...list].filter(isRule).map((r) => ({ text: r.cssText, rules: r.cssRules ? tree(r.cssRules) : [] }))
  const parseIn = (chain, block) => {
    const sheet = new CSSStyleSheet()
    try {
      sheet.replaceSync(chain.reduceRight((inner, outer) => `${outer} { ${inner} }`, `${block.prelude} {${block.body}}`))
    } catch {
      return null
    }
    let list = [...sheet.cssRules].filter(isRule)
    for (let depth = 0; depth < chain.length; depth++) {
      if (list.length !== 1 || !list[0].cssRules) return null
      list = [...list[0].cssRules].filter(isRule)
    }
    return list.map((r) => r.cssText)
  }
  const alone = (blocks, chain) =>
    blocks.map((b) => {
      const texts = parseIn(chain, b)
      if (texts?.length !== 1) return { texts, dropped: [], blocks: [] }
      const dropped = (b.arms ?? []).filter((arm) => parseIn(chain, { prelude: arm, body: '' })?.length !== 1)
      // An arm can read alone and still be one :is() or :where() drops where it stands: the rule's own prelude as
      // written is read beside the same prelude with that one call emptied, in the same blocks. The same text back
      // means the browser dropped the arm; a reading that is not one rule cannot tell, and refuses the arm too.
      const unclear = []
      for (const { name, arm, emptied } of b.within ?? []) {
        const kept = parseIn(chain, { prelude: b.prelude, body: '' })
        const none = parseIn(chain, { prelude: emptied, body: '' })
        if (kept?.length !== 1 || none?.length !== 1) unclear.push({ name, arm })
        else if (kept[0] === none[0] && !dropped.includes(arm)) dropped.push(arm)
      }
      return { texts, dropped, unclear, blocks: alone(b.blocks, [...chain, b.prelude]) }
    })
  return { alone: alone(written, []), whole: tree(rules) }
}

/** The findings, in plain words, from holding the sheet's text (textBlocks) against the browser's readings
    (browserReadings), level by level. The text lint (build/css-lint.mjs) has already refused a sheet outside the
    part-sheet forms; inside them, a block that alone comes back as no rule is a rule the browser drops, refused by
    name, and so is an arm the browser drops. Each other block must come back alone as exactly one rule, in its place, whose text is the text of the rule
    the whole sheet holds there, at every level; anything else refuses the sheet, naming the block. Runs in the page
    as well, so it holds no outside name. */
export function sheetFindings([written, { alone, whole }]) {
  const found = []
  const cannot = (where, what) => found.push(`the check cannot read this sheet the way the browser does: ${where}: ${what}`)
  const compare = (blocks, readings, rules, path) => {
    const where = path.length ? `inside ${path.join(' { ')}` : 'at the top of part.css'
    const kept = []
    blocks.forEach((b, i) => {
      const { texts, blocks: inner } = readings[i]
      if (texts === null) cannot(where, `${b.prelude} does not read alone in its place`)
      else if (texts.length === 0) found.push(`${b.prelude}: the browser drops this rule, so nothing would judge it; part.css holds only selectors and conditions the browser reads`)
      else if (texts.length > 1) cannot(where, `${b.prelude} reads as ${texts.length} rules alone`)
      else {
        kept.push({ b, text: texts[0], inner })
        for (const arm of readings[i].dropped ?? [])
          found.push(`${b.prelude}: the arm ${arm} is one the browser drops, so the rule would ship with an arm nothing judges; part.css holds only selectors the browser reads`)
        for (const { name, arm } of readings[i].unclear ?? [])
          cannot(where, `${b.prelude}: the arm ${arm} does not read as one rule inside :${name}() in its place`)
      }
    })
    if (kept.length !== rules.length)
      return cannot(where, `part.css writes ${kept.length} rule(s) the browser reads alone, and the browser reads ${rules.length} from the whole sheet`)
    kept.forEach(({ b, text, inner }, k) => {
      if (text !== rules[k].text) cannot(where, `rule ${k + 1}, ${b.prelude}, reads alone as other text than the rule the whole sheet holds in its place`)
      else compare(b.blocks, inner, rules[k].rules, [...path, b.prelude])
    })
  }
  compare(written, alone, whole, [])
  return found
}
