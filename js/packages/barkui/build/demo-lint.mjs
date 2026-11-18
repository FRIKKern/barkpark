// demo.mjs wires behaviour and never a look: only part.css and the base styles
// may style what a person sees in a part's stage. This lint names the first line
// that reaches for a style; the check's run-time guard (check/guard.mjs) catches
// whatever gets past it, since text can always be spelled to dodge a pattern.

const STYLING = [
  [/\.style\b|\[\s*['"`]style['"`]\s*\]/, 'sets an inline style'],
  [/setAttribute\s*\(\s*['"`]style['"`]/, 'sets a style attribute'],
  [/\bcssText\b|\battributeStyleMap\b|\bsetProperty\s*\(/, 'sets an inline style'],
  [/createElement(NS)?\s*\([^)]*['"`](style|link)['"`]/, 'creates a <style> or <link>'],
  [/<style\b|<link\b|\sstyle\s*=/i, 'writes markup that carries a style'],
  [/\b(insertRule|deleteRule|replaceSync|addRule|removeRule)\b|\.replace\s*\(\s*['"`][^'"`]*\{/, 'edits a stylesheet'],
  [/\badoptedStyleSheets\b|\bCSSStyleSheet\b|\bstyleSheets\b/, 'touches the stylesheets'],
  [/\.animate\s*\(|\bnew\s+Animation\b|\bKeyframeEffect\b/, 'runs a script animation'],
  [/\bclassName\b|setAttribute\s*\(\s*['"`]class['"`]|toggleAttribute\s*\(\s*['"`]class/, 'sets classes wholesale; use classList with classes part.css declares'],
  [/__barkCheck|\bprototype\b|\bdefineProperty\b|\bgetComputedStyle\b|\bReflect\b|\bProxy\b/, 'reaches into the page or the check'],
]

/** Classes part.css declares (`.name` in a selector). */
const declared = (css) => new Set([...css.replace(/\/\*[^]*?\*\//g, '').matchAll(/\.(-?[_a-zA-Z][\w-]*)/g)].map((m) => m[1]))

/** Blank out comments, keeping line numbers. */
const code = (js) => js.replace(/\/\*[^]*?\*\//g, (c) => c.replace(/[^\n]/g, ' ')).replace(/(^|[^:\\])\/\/.*$/gm, '$1')

/** The first line of a demo that styles, or null. */
export function lintDemo(js, partCss) {
  const classes = declared(partCss)
  const lines = code(js).split('\n')
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    for (const [re, why] of STYLING) if (re.test(line)) return { line: i + 1, why: `${why}; the look belongs in part.css` }
    for (const m of line.matchAll(/classList\s*\.\s*(\w+)\s*\(([^)]*)\)/g)) {
      if (!/^(add|remove|toggle|replace)$/.test(m[1])) continue
      const args = m[2].split(',').map((a) => a.trim()).filter((a, n) => !(m[1] === 'toggle' && n === 1))
      for (const a of args) {
        const name = a.match(/^['"`]([\w-]+)['"`]$/)?.[1]
        if (!name) return { line: i + 1, why: `classList.${m[1]} takes a class from a value; name a class part.css declares` }
        if (!classes.has(name)) return { line: i + 1, why: `classList.${m[1]} uses "${name}", which part.css never declares` }
      }
    }
  }
  return null
}
