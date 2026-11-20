import { describe, expect, it } from 'vitest'
import { sheetFindings, textBlocks } from '../check/sheet-text.mjs'

// The rules a part sheet's text writes, so the check can hold them against what the browser read (check/cssom.mjs).
describe("a part sheet's rules as its text writes them", () => {
  it('reads each block with its prelude, nested blocks inside their parent, after declarations too', () => {
    const css = `/* a { b } */ [data-slot="button"] {\n  color: red;\n  &:hover { color: blue; }\n  & > svg { width: 1rem }\n}\n@media (prefers-reduced-motion: no-preference) {\n  [data-slot="button"] { transition: none; }\n}`
    expect(textBlocks(css)).toEqual([
      { prelude: '[data-slot="button"]', blocks: [{ prelude: '&:hover', blocks: [] }, { prelude: '& > svg', blocks: [] }] },
      { prelude: '@media (prefers-reduced-motion: no-preference)', blocks: [{ prelude: '[data-slot="button"]', blocks: [] }] },
    ])
  })

  it('opens nothing on a brace inside a string, an escape or a comment', () => {
    expect(textBlocks('[title="{"] { content: "}"; } a\\{b { gap: 0 } /* } */ c { }').map((b) => b.prelude)).toEqual(['[title="{"]', 'a\\{b', 'c'])
  })

  it('ends a string at an unescaped newline, as the browser does, and runs on past an escaped one', () => {
    expect(textBlocks('a { --x: "b\n; } c { --y: "d\\\n}"; } e { }').map((b) => b.prelude)).toEqual(['a', 'c', 'e'])
  })
})

// The browser's readings are given here as data (check/sheet-text.mjs makes them in the page), so each way the two
// readings can differ is held on its own. Any difference is refused; only full agreement passes.
describe("a part sheet's text held against the browser's readings", () => {
  const block = (prelude, blocks = []) => ({ prelude, blocks })
  const read = (heads, blocks = []) => ({ heads, blocks })
  const rule = (head, rules = []) => ({ head, rules })
  const cannot = /^the check cannot read this sheet the way the browser does: /

  it('passes when every block reads alone as the rule the whole sheet holds in its place, at every level', () => {
    const written = [block('a', [block('&:hover')]), block('@media (max-width: 600px)', [block('b')])]
    const alone = [read(['CSSStyleRule a'], [read(['CSSStyleRule &:hover'])]), read(['CSSMediaRule (max-width: 600px)'], [read(['CSSStyleRule b'])])]
    const whole = [rule('CSSStyleRule a', [rule('CSSStyleRule &:hover')]), rule('CSSMediaRule (max-width: 600px)', [rule('CSSStyleRule b')])]
    expect(sheetFindings([written, { alone, whole }])).toEqual([])
  })

  it('names a block that alone reads as no rule: the browser drops it', () => {
    const found = sheetFindings([[block('a:bark-made-up'), block('a')], { alone: [read([]), read(['CSSStyleRule a'])], whole: [rule('CSSStyleRule a')] }])
    expect(found).toEqual(['a:bark-made-up: the browser drops this rule, so nothing would judge it; part.css holds only selectors and conditions the browser reads'])
  })

  it('refuses a block that alone reads as more than one rule', () => {
    const found = sheetFindings([[block('a')], { alone: [read(['CSSStyleRule a', 'CSSStyleRule b'])], whole: [rule('CSSStyleRule a'), rule('CSSStyleRule b')] }])
    expect(found.some((f) => cannot.test(f) && f.endsWith('at the top of part.css: a reads as 2 rules alone'))).toBe(true)
  })

  it('refuses a block that does not read alone in its place', () => {
    const found = sheetFindings([[block('a', [block('b')])], { alone: [read(['CSSStyleRule a'], [read(null)])], whole: [rule('CSSStyleRule a', [rule('CSSStyleRule b')])] }])
    expect(found.some((f) => cannot.test(f) && f.endsWith('inside a: b does not read alone in its place'))).toBe(true)
  })

  it('refuses rules read alone that the whole sheet holds in another order', () => {
    const found = sheetFindings([[block('a'), block('b')], { alone: [read(['CSSStyleRule a']), read(['CSSStyleRule b'])], whole: [rule('CSSStyleRule b'), rule('CSSStyleRule a')] }])
    expect(found.filter((f) => cannot.test(f))).toHaveLength(2)
    expect(found[0]).toMatch(/at the top of part\.css: rule 1 reads as "CSSStyleRule a" alone and as "CSSStyleRule b" in the whole sheet$/)
  })

  it('refuses a nested rule whose text differs from the whole sheet, the counts being equal', () => {
    const found = sheetFindings([[block('a', [block('&:hover')])], { alone: [read(['CSSStyleRule a'], [read(['CSSStyleRule &:hover'])])], whole: [rule('CSSStyleRule a', [rule('CSSStyleRule &:focus-visible')])] }])
    expect(found).toHaveLength(1)
    expect(found[0]).toMatch(cannot)
    expect(found[0]).toMatch(/inside a: rule 1 reads as "CSSStyleRule &:hover" alone/)
  })

  it('refuses a count that differs from the whole sheet once every block reads alone as one rule', () => {
    const found = sheetFindings([[block('a')], { alone: [read(['CSSStyleRule a'])], whole: [rule('CSSLayerStatementRule x'), rule('CSSStyleRule a')] }])
    expect(found).toEqual(['the check cannot read this sheet the way the browser does: at the top of part.css: part.css writes 1 rule(s) the browser reads alone, and the browser reads 2 from the whole sheet'])
  })
})
