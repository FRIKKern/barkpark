import { describe, expect, it } from 'vitest'
import { textBlocks } from '../check/sheet-text.mjs'

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
})
