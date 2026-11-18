// part.css may only read the skin: colours come from --ui-* and --bark-*
// variables, never from a literal. Returns one message per finding.
const NAMED = `aliceblue antiquewhite aqua aquamarine azure beige bisque black blanchedalmond blue blueviolet brown burlywood
cadetblue chartreuse chocolate coral cornflowerblue cornsilk crimson cyan darkblue darkcyan darkgoldenrod darkgray darkgreen
darkgrey darkkhaki darkmagenta darkolivegreen darkorange darkorchid darkred darksalmon darkseagreen darkslateblue darkslategray
darkslategrey darkturquoise darkviolet deeppink deepskyblue dimgray dimgrey dodgerblue firebrick floralwhite forestgreen fuchsia
gainsboro ghostwhite gold goldenrod gray green greenyellow grey honeydew hotpink indianred indigo ivory khaki lavender
lavenderblush lawngreen lemonchiffon lightblue lightcoral lightcyan lightgoldenrodyellow lightgray lightgreen lightgrey lightpink
lightsalmon lightseagreen lightskyblue lightslategray lightslategrey lightsteelblue lightyellow lime limegreen linen magenta maroon
mediumaquamarine mediumblue mediumorchid mediumpurple mediumseagreen mediumslateblue mediumspringgreen mediumturquoise
mediumvioletred midnightblue mintcream mistyrose moccasin navajowhite navy oldlace olive olivedrab orange orangered orchid
palegoldenrod palegreen paleturquoise palevioletred papayawhip peachpuff peru pink plum powderblue purple rebeccapurple red
rosybrown royalblue saddlebrown salmon sandybrown seagreen seashell sienna silver skyblue slateblue slategray slategrey snow
springgreen steelblue tan teal thistle tomato turquoise violet wheat white whitesmoke yellow yellowgreen
canvas canvastext linktext visitedtext activetext buttonface buttontext buttonborder field fieldtext highlight highlighttext
selecteditem selecteditemtext mark marktext graytext accentcolor accentcolortext`.split(/\s+/)
const NAMED_RE = new RegExp(`(^|[\\s,(])(${NAMED.join('|')})(?=$|[\\s,);!])`, 'i')
const FUNC_RE = /\b(rgba?|hsla?|hwb|lab|lch|oklab|oklch|color|light-dark)\s*\(/i
const HEX_RE = /#[0-9a-f]{3,8}\b/i

// A part never branches on skin or scheme, and never draws its own focus ring
// (base.css draws one ring for every part) or mixes its own state tints (base.css
// computes them once from the skin).
const SELECTOR_RULES = [
  [/\[\s*data-(skin|bp-theme|color-scheme|theme)\b/i, (m) => `a [data-${m[1]}] rule: parts never branch on skin or scheme`],
  [/prefers-color-scheme/i, () => 'a prefers-color-scheme query: parts never branch on scheme'],
  [/:focus(-visible|-within)?\b/i, (m) => `a :focus${m[1] ?? ''} rule: the focus ring is drawn once, in base.css`],
]

export function lintPartCss(css) {
  const found = []
  const text = css.replace(/\/\*[\s\S]*?\*\//g, (c) => c.replace(/[^\n]/g, ' '))
  const lineOf = (i) => text.slice(0, i).split('\n').length
  for (const [re, say] of SELECTOR_RULES) {
    for (const m of text.matchAll(new RegExp(re.source, 'gi'))) found.push(`line ${lineOf(m.index)}: ${say(m)}`)
  }
  // Declarations: `prop: value` ending at ; or }. Property names are case-insensitive.
  const decl = /(^|[{;\s])(--?[\w-]+|[a-z-]+)\s*:\s*([^;{}]+)(?=[;}])/gi
  for (let m; (m = decl.exec(text)); ) {
    const [, , rawProp, raw] = m
    const prop = rawProp.startsWith('--') ? rawProp : rawProp.toLowerCase()
    const value = raw.trim()
    if (!value) continue
    const at = `line ${lineOf(m.index + m[1].length)}`
    if (HEX_RE.test(value) || /%23[0-9a-f]{3,8}\b/i.test(value)) found.push(`${at}: ${prop} uses a hex colour (${value})`)
    const fn = value.match(FUNC_RE)
    if (fn) found.push(`${at}: ${prop} uses ${fn[1]}() (${value})`)
    for (const u of value.matchAll(/url\(\s*(?:"([^"]*)"|'([^']*)'|([^)]*))\s*\)/gi)) {
      const src = decodeURIComponent((u[1] ?? u[2] ?? u[3]).replace(/%(?![0-9a-f]{2})/gi, '%25'))
      const own = /\b(fill|stroke|stop-color|flood-color|color)\s*=\s*['"]?(?!currentColor|none)[\w#]/i.test(src)
      if (!/^data:image\/svg\+xml/i.test(src)) found.push(`${at}: ${prop} loads an image; only a data: SVG drawn in currentColor is allowed`)
      else if (own || !/currentColor/i.test(src)) found.push(`${at}: ${prop} has an SVG with its own colour; draw it in currentColor`)
    }
    if (/color-mix\s*\(/i.test(value)) found.push(`${at}: ${prop} mixes a tint; state tints are computed once in base.css`)
    if (/^outline/.test(prop)) found.push(`${at}: ${prop}: the focus ring is drawn once, in base.css`)
    const named = value.match(NAMED_RE)
    if (named) found.push(`${at}: ${prop} uses the named colour "${named[2]}"`)
    for (const v of value.matchAll(/var\(\s*(--[\w-]+)\s*(,[^)]*)?\)/g)) {
      if (!/^--(ui|bark)-/.test(v[1])) found.push(`${at}: ${prop} reads ${v[1]}; only --ui-* and --bark-* are allowed`)
      if (v[2]) found.push(`${at}: ${prop} gives ${v[1]} a fallback; the sheet sets every variable`)
    }
  }
  return found
}
