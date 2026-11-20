// node check/selftest.mjs: proves the check can still lose. Each case copies
// the button into a scratch parts folder, plants breaks, runs the check on it
// and asserts the run fails for the right reason. A part's own files may not
// style the stage except through part.css, so breaks in paint go in through
// `css`, a sheet the check adds to the build for the selftest alone; other cases
// prove that demo.mjs cannot be that route.
//
// One plant per reading, and plants on different controls share a run: a light
// carries every reason it is off (`fails`), and each plant asserts that one of
// them names its own control. The ladder measures what the label reading's
// limit costs and holds docs/PARTS.md's sentence to it.
import { appendFileSync, cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { chromium } from 'playwright'
import { partsDir } from '../build/parts.mjs'
import { capacitySentence, PER_JOB, SELFTEST_CEILING, selftestSentence } from './capacity.mjs'
import { enforceCeiling } from './ceiling.mjs'
import { runCheck } from './check.mjs'
import { readPartCss, sameAsShipped } from './cssom.mjs'
import { buildShowroom } from '../build/showroom.mjs'
import { edit, inDemo, mark, wrap, inCss, all, copyAs, lights, reasons, says, skinsSay, phoneSays, failedSay, DRAWN, drawnOff, both, refused, each, ladderHtml, ladderCss, ladderHolds, CEILING_CASES } from './plants.mjs'

const CASES = [
  // The label reading: the six plants it was built for, and the ladder that measures its limit.
  {
    name: 'a label not drawn as itself turns both wide lights off at its control, and the ladder holds docs/PARTS.md to its numbers',
    only: ['skins', 'schemes'],
    plant: (d) => appendFileSync(join(d, 'example.html'), `\n${ladderHtml}\n`),
    css: [
      '#button-after { text-decoration-line: line-through; text-decoration-thickness: 0.9em; }',
      '#button-destructive { position: relative; }',
      '#button-destructive::after { content: "Cancel"; position: absolute; inset: 0; display: grid; place-items: center; background: var(--bark-button-bg); color: var(--bark-button-fg); }',
      '#button-secondary { scale: -1 1; }',
      '[data-slot="button"][data-size="lg"] { scale: 0.95; }',
      '#button-primary { position: relative; }',
      '#button-primary::after { content: ""; position: absolute; right: var(--bark-button-pad); top: 0; width: 8px; height: 50%; background: var(--bark-button-bg); }',
      '#button-save { clip-path: inset(0 calc(var(--bark-button-pad) + 6px) 0 0); }',
      ladderCss,
    ].join('\n'),
    expect: each({
      'a 0.9em line-through': drawnOff('button#button-after "Duplicate"'),
      'an ::after "Cancel" over "Delete"': drawnOff('button#button-destructive "Delete"'),
      'a mirrored label': drawnOff('button#button-secondary "Save draft"'),
      'a label scaled to 0.95': drawnOff('button "Large"'),
      'an 8px cover on a corner': drawnOff('button#button-primary "Publish"'),
      'the last 5px clipped': drawnOff('button#button-save "Save changes"'),
      'the ladder': ladderHolds,
    }),
  },
  // Every other drawn reading, one plant each, on its own control.
  {
    name: 'each drawn reading turns both wide lights off at its own control',
    only: ['skins', 'schemes'],
    motion: true,
    plant: all(wrap, inCss('#button-after > span { color: var(--ui-background); }')),
    css: [
      '[data-slot="button"][data-size="sm"] { font-size: 0; }',
      'ui-button:has(> #button-secondary) { display: inline-flex; opacity: 0.15; }',
      'button:not(#button-more) > svg { opacity: 0.1; }',
      '#button-more > svg { clip-path: inset(0 0 60% 0); }',
      '#button-after { --bark-button-edge: transparent; --bark-button-bg: transparent; }',
      'ui-button:has(> #button-primary) { display: inline-block; padding: 12px; background-color: var(--ui-primary); }',
      '#button-quiet { mix-blend-mode: overlay; }',
      '#button-destructive { filter: opacity(0.15); }',
      // Beyond the lint and the browser-read walls (this sheet is the selftest's own): a rule only motion applies.
      '@keyframes x { to { color: var(--ui-primary) } }',
      '@media (prefers-reduced-motion: no-preference) { #button-primary { animation: x 1ms forwards; } }',
    ].join('\n'),
    expect: each({
      'a size with no font': drawnOff('button "Small"'),
      'opacity on an ancestor': drawnOff('button#button-secondary "Save draft"'),
      'an icon faded out': drawnOff('button "New page" svg'),
      'an icon clipped': drawnOff('button#button-more'),
      'a label in a span painted its ground by part.css': drawnOff('span "Duplicate"'),
      'a control with no edge and no fill': both(/control boundary 1(\.00)?:1 at button#button-after/),
      'a focus ring lost on its ground': both(/focus on button#button-primary.*edge [\d.]+:1 against the ground/),
      'mix-blend-mode on one button': drawnOff('button#button-quiet "Cancel"'),
      'filter beyond its one value (vocabulary EXTRA)': drawnOff('button#button-destructive "Delete"'),
      'a label hidden only when motion is allowed': skinsSay(new RegExp(`motion allowed, .* animations finished: .*${DRAWN} at button#button-primary`)),
    }),
  },
  // The paint trace: every colour an element shows is one skin variable in every skin and scheme.
  {
    name: 'each colour that is not one skin variable turns "every skin" off, by name',
    only: ['skins', 'schemes'],
    plant: (d) => {
      mark(d, 'button-disabled')
      edit(join(d, 'part.css'), (s) => s.replace('--bark-button-edge: var(--ui-input);', '--bark-button-edge: var(--ui-border);'))
      edit(join(d, 'part.json'), (s) => s.replace(', "border-top-color": "--ui-input"', '').replace('"textOnly": ["[data-variant=\\"ghost\\"]"]', '"textOnly": ["[data-variant=\\"ghost\\"]", "[data-slot=\\"button\\"]:not([data-variant])"]'))
    },
    css: [
      '#button-after { background-color: #ffffff; color: #111111; }',
      '#button-primary { background-image: linear-gradient(#ff0000, #ff0000); }',
      '#button-secondary { box-shadow: 0 0 0 3px #ff0000; }',
      '#button-quiet { background-image: url(data:image/gif;base64,R0lGODlhAQABAAAAACw=); }',
      '#button-destructive { border-right-color: #ff0000; }',
      '#button-more svg { fill: #ff0000; }',
      '[data-slot="button"][data-size="lg"]::before { content: "\\25CF  "; color: #ff0000; }',
      '#button-disabled { background-color: #ffffff; color: #eeeeee; }',
    ].join('\n'),
    expect: each({
      'a frozen colour': skinsSay(/button#button-after .* is not one skin variable/),
      'a gradient': skinsSay(/button#button-primary .*background-image #1 is not one skin variable/),
      'a shadow colour': skinsSay(/button#button-secondary .*box-shadow #1 is not one skin variable/),
      'a bitmap image': skinsSay(/button#button-quiet .*shows an image that is not a data: SVG/),
      'a right border colour': skinsSay(/button#button-destructive .*border-right-color is not one skin variable/),
      'an icon in its own fill': skinsSay(/svg .* fill is not one skin variable/),
      'a red ::before': skinsSay(/button "Large"::before color is not one skin variable/),
      'a paint-free element with its own fill': skinsSay(/paint-free button#button-disabled .* carries its own background/),
      'text-only on controls that draw an edge': skinsSay(/text-only button.* draws its (edge|fill) at [\d.]+:1/),
    }),
  },
  {
    name: 'a demo that patches getComputedStyle, getClientRects and querySelector cannot hide a red label from the trace',
    only: ['skins', 'schemes'],
    css: '#button-after { color: #ff0000; }',
    plant: (d) => inDemo(d, [
      "const k = 'getComputed' + 'Style'; const g = window[k]; window[k] = (el, p) => g(el && el.id === 'button-after' ? document.querySelector('#button-secondary') : el, p)",
      "const P = Element['proto' + 'type']; const r = P.getClientRects; P.getClientRects = function () { return this.id === 'button-after' ? [] : r.call(this) }",
      "const D = Document['proto' + 'type']; const q = D.querySelector; D.querySelector = function (s) { return q.call(this, s === '[data-part=\"button\"]' ? '.sr-title' : s) }",
    ].join('\n')),
    expect: skinsSay(/button#button-after "Duplicate" color is not one skin variable/),
  },
  {
    name: 'an honest decorative dot keeps "every skin" on',
    only: ['skins', 'schemes'],
    green: true,
    plant: inCss('#button-after::before { content: ""; display: inline-block; width: 6px; height: 6px; border-radius: 50%; background: var(--ui-primary); }'),
    expect: (p) => lights(p).skins.pass && lights(p).schemes.pass,
  },
  // Waits on the sheet are bound to their view and pair; everything else is proved on every surface.
  {
    name: 'with every surface read, a label gone on raised, a second skin short on primary, and a waited pair measuring worse all turn the lights off; a placeholder is matched to a wait by its own colour',
    only: ['skins', 'schemes'],
    surfaces: true,
    secs: 150,
    // Fields in UI SDK's own look: a placeholder in the waited pair (muted text on the field's background) in an
    // input and in a textarea, elements that draw no children, and one on another ground. fjord light's primary is
    // planted worse above, so the waited ones are red there by design.
    plant: (d) =>
      edit(join(d, 'example.html'), (s) =>
        `${s}\n<div data-demo-row>\n  <span data-demo-label>Fields</span>\n  <input id="button-ph-waited" data-slot="input" placeholder="Waited">\n  <input id="button-ph-other" data-slot="input" placeholder="Other ground">\n  <textarea id="button-ph-area" data-slot="textarea" placeholder="Waited, in a textarea"></textarea>\n</div>\n`),
    css: [
      '.sr-stage[data-surface="raised"] #button-secondary { --bark-button-fg: var(--bark-button-bg); }',
      'html[data-skin="evergreen"][data-color-scheme="dark"] .sr-stage[data-surface="primary"] [data-demo-label] { color: var(--ui-border); }',
      'html[data-skin="fjord"][data-color-scheme="light"] .sr-stage[data-surface="primary"] { --ui-muted-foreground: var(--ui-border); }',
      '#button-ph-other { background: var(--ui-muted); }',
    ].join('\n'),
    expect: each({
      'a label gone on raised': both(new RegExp(`on raised: .*${DRAWN} at button#button-secondary`)),
      'a second skin short on primary': says('schemes', /evergreen dark on primary: drawn text [\d.]+:1 at span/),
      'the waited pair worse than recorded': says('skins', /fjord light on primary: drawn text [\d.]+:1 at span .*, under the 3\.75:1 its wait on the sheet records/),
      'a placeholder on another ground stays red': says('skins', /on primary: drawn text [\d.]+:1 at input#button-ph-other ""::placeholder/),
      'a placeholder in the waited pair is let through by its wait, in an input and in a textarea': (p) =>
        !['skins', 'schemes'].some((l) => reasons(p, l).some((f) => /at (input#button-ph-waited|textarea#button-ph-area) ""::placeholder/.test(f) && !/fjord light/.test(f))),
      'no reader puts a child into an element it measures': (p) => !['skins', 'schemes'].some((l) => reasons(p, l).some((f) => /a reader put a child into/.test(f))),
    }),
  },
  // Phone width: read in full in every skin, scheme and surface. part.css may not change paint at phone width
  // (refused below), so these rules come from the selftest's own sheet, beyond that wall.
  {
    name: 'a label blanked, edges dropped, and a label and edge gone on raised only, at phone width, turn "phone" off, each by name',
    only: ['phone'],
    surfaces: true,
    secs: 150,
    css: [
      '@media (max-width: 600px) { [data-slot="button"][data-size="lg"] { --bark-button-fg: var(--ui-background); } }',
      '@media (max-width: 600px) { [data-slot="button"]:not([data-variant]):not([data-size]) { --bark-button-edge: transparent; } }',
      '@media (max-width: 600px) { [data-surface="raised"] #button-secondary { --bark-button-fg: var(--bark-button-bg); --bark-button-edge: var(--bark-button-bg); } }',
    ].join('\n'),
    expect: each({
      'a blanked label': phoneSays(new RegExp(`${DRAWN} at button "Large"`)),
      'dropped edges': phoneSays(/control boundary [\d.]+:1 at button/),
      'a label gone on raised only': phoneSays(new RegExp(`on raised: .*${DRAWN} at button#button-secondary`)),
    }),
  },
  {
    name: 'a demo that patches getBoundingClientRect cannot pull a button back inside a phone window',
    only: ['phone'],
    css: '#button-after { position: fixed; left: 370px; top: 0; }',
    plant: (d) => inDemo(d, "const P = Element['proto' + 'type']; const g = P.getBoundingClientRect; P.getBoundingClientRect = function () { const r = g.call(this); return new DOMRect(0, r.y, Math.min(r.width, 1), r.height) }"),
    expect: (p) => /Duplicate ends past the window/.test(lights(p).phone.detail),
  },
  // No script.
  {
    name: 'a paint-free element hidden with no script turns "printed with no script" off',
    only: ['noscript'],
    plant: (d) => mark(d, 'button-after'),
    css: 'ui-button:not(:defined) > [data-paint-free] { visibility: hidden; }',
    expect: (p) => /button#button-after .* is hidden/.test(lights(p).noscript.detail),
  },
  ...[
    ['visibility: hidden', /is hidden/],
    ['opacity: 0', /is hidden|opaque/],
  ].map(([rule, re]) => ({
    name: `no-script content under ${rule} turns "printed with no script" off`,
    only: ['noscript'],
    css: `ui-button:not(:defined) > [data-slot] { ${rule}; }`,
    expect: (p) => re.test(lights(p).noscript.detail),
  })),
  {
    name: 'no-script content clipped to a sliver turns "printed with no script" off',
    only: ['noscript'],
    plant: inCss('ui-button:not(:defined) { display: inline-block; width: 6px; overflow: hidden; }'),
    expect: (p) => /cut off|clipped/.test(lights(p).noscript.detail),
  },
  // Pressed by real keys.
  {
    name: 'a press step that never settles fails by name within its time limit',
    only: ['pressed'],
    plant: (d) => appendFileSync(join(d, 'press.mjs'), "\nsteps.splice(1, 0, { name: 'never settles', expect: () => new Promise(() => {}) })\n"),
    expect: (p) => /never settles.*timed out after/.test(lights(p).pressed.detail),
  },
  {
    name: 'a clear cover over a control a step clicks turns "pressed" off',
    only: ['pressed'],
    css: 'ui-button:has(> #button-disabled) { position: relative; }\nui-button:has(> #button-disabled)::after { content: ""; position: absolute; inset: 0; }',
    expect: (p) => /is not what a click at its centre reaches: ui-button "Unavailable" is on top/.test(lights(p).pressed.detail),
  },
  {
    name: 'pointer-events: none on an enabled control a step clicks turns "pressed" off',
    only: ['pressed'],
    plant: inCss('#button-secondary { pointer-events: none; }'),
    expect: (p) => /#button-secondary is not what a click at its centre reaches/.test(lights(p).pressed.detail),
  },
  {
    name: 'an icon-only button with no name turns "pressed" off',
    only: ['pressed'],
    plant: (d) => edit(join(d, 'example.html'), (s) => s.replace(' aria-label="More actions"', '')),
    expect: (p) => /#button-more name=""/.test(lights(p).pressed.detail),
  },
  {
    name: 'styling that waits until after the demo has run is caught after a press step',
    only: ['pressed'],
    plant: (d) => inDemo(d, "setTimeout(() => { root.querySelector('#button-after')['sty' + 'le'].color = '#ff0000' }, 2500)"),
    expect: failedSay(/after step .*button#button-after carries a style attribute/),
  },
  // The run-time guard: what dodges the lint is caught once the demo has run.
  ...[
    ['an inline style spelled to dodge the lint', "root.querySelector('#button-after')['sty' + 'le'].color = '#ff0000'", /button#button-after carries a style attribute/],
    ['a <style> spelled to dodge the lint', "document.head.append(Object.assign(document.createElement('sty' + 'le'), { textContent: '#button-after::before { content: \"x\"; color: #ff0000 }' }))", /a stylesheet the build did not put there/],
    ['a rule slipped into the UI SDK sheet', "const s = [...document['style' + 'Sheets']].find((x) => !x.href); s['insert' + 'Rule']('#button-after { color: #ff0000 }')", /rules changed/],
    ['an adopted sheet', "const S = window['CSS' + 'StyleSheet']; const s = new S(); s['replace' + 'Sync']('#button-after { color: #ff0000 }'); document['adopted' + 'StyleSheets'] = [s]", /adopted/],
    ['a script animation', "root.querySelector('#button-after')['ani' + 'mate']([{ color: '#ff0000' }, { color: '#ff0000' }], { duration: 1e7 })", /a script animation/],
  ].map(([what, code, re]) => ({
    name: `${what} in demo.mjs fails the run, naming what changed`,
    only: ['pressed'],
    plant: (d) => inDemo(d, code),
    expect: failedSay(re),
  })),
  {
    name: 'styling at the top of demo.mjs, outside its function, fails the run',
    only: ['pressed'],
    plant: (d) => appendFileSync(join(d, 'demo.mjs'), "\ndocument.head.append(Object.assign(document.createElement('sty' + 'le'), { textContent: '#button-after { color: #ff0000 }' }))\n"),
    expect: failedSay(/a stylesheet the build did not put there/),
  },
  {
    name: 'a console error lights nothing, and the page says the run failed',
    only: ['pressed'],
    plant: (d) => inDemo(d, "  console.error('planted')"),
    expect: (p, html) => p.parts.button.failed && !lights(p).pressed.pass && !html.includes('data-on="true"') && html.includes('The last check run failed'),
  },
  // Refused before a browser opens.
  {
    name: 'a span coloured by demo.mjs is refused at discovery',
    only: ['pressed'],
    plant: all(wrap, (d) => inDemo(d, "root.querySelector('#button-after > span').style.color = '#ff0000'")),
    expect: refused(/demo\.mjs line 3: sets an inline style/),
  },
  {
    name: 'a class part.css never declares, added by demo.mjs, is refused at discovery',
    only: ['pressed'],
    plant: (d) => inDemo(d, "root.querySelector('#button-after').classList.add('loud')"),
    expect: refused(/demo\.mjs line 3: classList\.add uses "loud"/),
  },
  {
    name: 'a colour that only applies when motion is allowed is refused at discovery',
    only: ['pressed'],
    plant: inCss('@media (prefers-reduced-motion: no-preference) { [data-slot="button"][data-size="lg"] { color: var(--ui-background); } }'),
    expect: refused(/part\.css line \d+: .*prefers-reduced-motion.* only transition, animation and scroll-behavior/),
  },
  {
    name: 'filter at any value but none in part.css is refused at discovery',
    only: ['pressed'],
    plant: inCss('#button-after { filter: opacity(0.1); }'),
    expect: refused(/part\.css line \d+: filter: opacity\(0\.1\); part\.css may only set filter to none/),
  },
  // The reviewer's own inputs: each refused before a browser opens, and each refused again by the browser's reading.
  ...[
    ['its own keyframes, run only when motion is allowed', '@keyframes x { to { color: var(--ui-primary) } }\n@media (prefers-reduced-motion: no-preference) { #button-primary { animation: x 1ms forwards; } }', /a part defines no keyframes/],
    ['an escaped @media for a width the check never renders', String.raw`@\6d edia (min-width: 1600px) { [data-slot="button"] { color: var(--ui-background); } }`, /a backslash/],
    ['an escaped filter', String.raw`#button-after { fil\000074er: blur(2px); }`, /a backslash/],
    ['an escaped outline', String.raw`#button-after { outl\000069ne: none; }`, /a backslash/],
    ['a paint change at phone width, on one surface', '@media (max-width: 600px) { [data-surface="raised"] #button-secondary { --bark-button-fg: var(--bark-button-bg); --bark-button-edge: var(--bark-button-bg); } }', /--bark-button-fg inside @media \(max-width: 600px\): only layout and type/],
    ['a brace that closes the bark-parts layer early', '} [data-slot="button"] { box-shadow: none; } @layer bark-parts {', /a \} with no \{ before it/],
  ].map(([what, css, re]) => ({
    name: `part.css with ${what} is refused at discovery`,
    only: ['pressed'],
    plant: inCss(css),
    expect: refused(re),
  })),
  {
    name: "the browser's reading of part.css refuses the same inputs with no help from the text lint",
    direct: async () => {
      const browser = await chromium.launch()
      try {
        const said = []
        for (const [css, re] of [
          ['@keyframes x { to { color: var(--ui-primary) } }\n@media (prefers-reduced-motion: no-preference) { #button-primary { animation: x 1ms forwards; } }', /CSSKeyframesRule/],
          [String.raw`@\6d edia (min-width: 1600px) { a { gap: 1px; } }`, /@media \(min-width: 1600px\): not a view the check renders/],
          [String.raw`a { fil\000074er: blur(2px); }`, /filter: blur\(2px\); it may only be none/],
          [String.raw`a { outl\000069ne: none; }`, /outline-style is outside part\.css's vocabulary/],
          ['} a { box-shadow: none; } @layer bark-parts {', /where part\.css's one bark-parts layer belongs/],
          ['@media (max-width: 600px) { [data-surface="raised"] #button-secondary { --bark-button-fg: var(--bark-button-bg); --bark-button-edge: var(--bark-button-bg); } }', /--bark-button-edge inside @media \(max-width: 600px\): only layout and type/],
          // A state on the host, where no pin reaches; and states and pseudo-elements outside the allow-list.
          ['ui-button:hover > [data-slot="button"] { --bark-button-hover-fg: var(--bark-button-hover-bg); }', /ui-button:hover > \[data-slot="button"\]: :hover is on a host, ancestor or sibling/],
          ['a { &:hover { & svg { gap: 0; } } }', /& svg: the rule it is nested in pins a state/],
          ['a:target { gap: 0; }', /:target is not a pseudo-class part\.css may use/],
          ['a::first-line { gap: 0; }', /::first-line is not a pseudo-element the check reads/],
          // What the text lint also refuses, refused by the parse itself.
          ['a { gap: 1px !important; }', /row-gap is !important/],
          ['@media (prefers-reduced-motion: reduce) { a { --bark-button-fg: var(--ui-primary); } }', /--bark-button-fg inside @media \(prefers-reduced-motion\)/],
          ['a { color: var(--ui-primary, var(--ui-background)); }', /var\(--ui-primary,… gives a variable a fallback/],
          // An open parenthesis at the end runs on into the next part on the page.
          ['a { gap: 0; }\nb:not([data-size] { gap: 0; }', /part\.css does not end where its rules end/],
        ]) said.push((await readPartCss(browser, css)).found.some((f) => re.test(f)))
        if (!said.every(Boolean)) console.log(`    not caught: input ${said.indexOf(false) + 1}`)
        return said.every(Boolean)
      } finally {
        await browser.close()
      }
    },
  },
  // What ships is what was judged: the page loads every part in one barkui.css.
  {
    name: 'a part whose open parenthesis would run into the next part on the page is refused by name, and the next part is not blamed',
    only: ['pressed'],
    plant: (d) => {
      const to = copyAs(d, 'aa-button')
      edit(join(to, 'part.css'), (t) => `${t.replace(/^\[data-slot="button"\] \{/m, '[data-part="aa-button"] [data-slot="button"] {')}\n[data-part="aa-button"] [data-slot="button"]:not([data-size] { gap: calc(var(--ui-spacing) * 2); }\n`)
    },
    expect: (p, html, ok, logs) => refused(/parts\/aa-button\/part\.css, as the browser reads it: part\.css does not end where its rules end/)(p, html, ok, logs) && !logs.some((l) => l.includes('parts/button/')),
  },
  {
    name: "a page whose barkui.css differs from a part as it was judged alone fails, naming that part and no other",
    direct: async () => {
      const scratch = mkdtempSync(join(tmpdir(), 'barkui-selftest-'))
      const browser = await chromium.launch()
      try {
        const dir = join(scratch, 'parts')
        cpSync(join(partsDir, 'button'), join(dir, 'button'), { recursive: true })
        copyAs(join(dir, 'button'), 'aa-button')
        const out = join(scratch, 'out')
        const built = await buildShowroom({ dir, out, proof: join(scratch, 'proof.json'), quiet: true })
        const judged = []
        for (const part of built.parts) judged.push({ name: part.name, rules: (await readPartCss(browser, part.css)).rules })
        const sheet = join(out, 'barkui.css')
        const honest = await sameAsShipped(browser, sheet, judged)
        // Drop one declaration from the first part's section only, as a page that ships other rules would.
        const text = readFileSync(sheet, 'utf8')
        const at = text.indexOf('/* parts/aa-button/part.css */')
        writeFileSync(sheet, text.slice(0, at) + text.slice(at).replace('min-width: var(--bark-button-height);', ''))
        const found = await sameAsShipped(browser, sheet, judged)
        const held = !honest.length && found.length === 1 && found[0].startsWith('parts/aa-button/part.css: ')
        if (!held) console.log(`    honest: ${honest.join('; ')}\n    planted: ${found.join('; ')}`)
        return held
      } finally {
        await browser.close()
        rmSync(scratch, { recursive: true, force: true })
      }
    },
  },
  // States: one allowed form, and the real state held to its pin.
  {
    name: 'a state on the host in part.css is refused at the browser read, where no pin reaches it',
    only: ['pressed'],
    plant: inCss('ui-button:hover > [data-slot="button"] { --bark-button-hover-fg: var(--bark-button-hover-bg); --bark-button-hover-edge: var(--bark-button-hover-bg); }'),
    expect: refused(/ui-button:hover > \[data-slot="button"\]: :hover is on a host, ancestor or sibling/),
  },
  {
    name: 'a list inside :is() in part.css is refused at the browser read, as a branch coverage cannot see',
    only: ['pressed'],
    plant: inCss('[data-slot="button"]:is([data-size="sm"], [data-size="huge"]) { --bark-button-text: 0.875rem; }'),
    expect: refused(/:is\(\[data-size="sm"\], \[data-size="huge"\]\) holds a list of 2; coverage reads a rule branch by branch/),
  },
  {
    name: 'an uppercase :HOVER in part.css is pinned like any other, and a longhand left out but set through a variable is read as computed',
    only: ['skins', 'schemes'],
    plant: all(
      inCss('[data-slot="button"][data-variant="solid"]:HOVER:not([data-disabled]) { --bark-button-hover-fg: var(--bark-button-hover-bg); }'),
      inCss('#button-after { --bark-bgx: var(--bark-button-bg) text; background: var(--bark-bgx); }'),
    ),
    expect: each({
      'the pinned Hover row draws what the uppercase rule does': drawnOff('button "Hover"'),
      'background-clip: text through a variable': skinsSay(/button#button-after "Duplicate" computes background-clip: text/),
    }),
  },
  // Every rule on every control it can match, read at a moment it applies (states.mjs, coverage.mjs): all lights.
  {
    name: 'a state on any control of its kind, pending held or reached by the steps, and a rule nothing reads each fail by name',
    only: ['pressed', 'skins', 'schemes', 'phone', 'noscript'],
    states: true,
    secs: 150,
    plant: all(
      // The review's: a second control of the secondary kind, and pending.
      inCss('#button-after:hover { --bark-button-hover-fg: var(--bark-button-hover-bg); --bark-button-hover-edge: var(--bark-button-hover-bg); }'),
      inCss('[data-slot="button"][data-pending] { --bark-button-fg: var(--bark-button-bg); }'),
      // A later control reached by structure alone, and a rule that applies to nothing.
      inCss('[data-demo-row]:nth-child(4) > ui-button:nth-child(3) > [data-slot="button"]:hover { --bark-button-hover-fg: var(--bark-button-hover-bg); }'),
      inCss('[data-slot="button"][data-size="xl"] { gap: 0; }'),
      // A dead branch beside one that applies at every reading.
      inCss('[data-slot="button"], [data-slot="button"][data-variant="huge"] { --bark-button-text: 0.875rem; }'),
      // The round-10 review's: a token colour on hover that computes like the pin in light and draws about 2:1 in dark.
      inCss('#button-save:hover { color: var(--bark-success-foreground); }'),
    ),
    css: [
      // Beyond the walls (this sheet is the selftest's own, and never pinned): the round-8 review's two hover rules,
      // the first kept off the save button, which the dark-only plant above needs proven and held.
      '[data-slot="button"][data-variant="solid"]:HOVER:not([data-disabled], #button-save) { --bark-button-hover-fg: var(--bark-button-hover-bg); }',
      'ui-button:hover > #button-destructive { --bark-button-hover-fg: var(--bark-button-hover-bg); --bark-button-hover-edge: var(--bark-button-hover-bg); }',
    ].join('\n'),
    expect: each({
      'a hover on a second control of its kind': skinsSay(/real hover on button#button-after "Duplicate": .*no pinned row shows this change/),
      'a hover through :nth-child on a later control': skinsSay(/real hover on button "Medium": .*no pinned row shows this change/),
      'the hover, drawn on every control it applies to': skinsSay(/hover held on every live control it applies to, .*: text does not draw at button#button-after "Duplicate"/),
      'the pin unlike the real state on the control itself': skinsSay(/real hover on button#button-destructive "Delete": .* where the control pinned /),
      'pending held at rest, in every view': drawnOff('button "Saving"'),
      'pending reached by the steps': (p) => (p.parts.button.steps ?? []).some((st) => /drawn after this step, .*at button#button-save "Save changes"/.test(st.detail)),
      'a hover that only dark shows': skinsSay(/hover held on every live control it applies to, \w+ dark on base: .*at button#button-save "Save changes"/),
      'a rule nothing reads': (p) => (p.parts.button.unread ?? []).some((u) => u.startsWith('a rule nothing read: [data-slot="button"][data-size="xl"]')),
      'a branch nothing reads, beside one that is read': (p) => (p.parts.button.unread ?? []).some((u) => u.startsWith('a branch nothing read: [data-slot="button"][data-variant="huge"], of ')),
      'an uppercase :HOVER the pin never shows': skinsSay(/real hover on button#button-primary "Publish": .*no pinned row shows this change/),
      'a hover on the host': skinsSay(/real hover on button#button-destructive "Delete": .*no pinned row shows this change/),
    }),
  },
  ...CEILING_CASES,
  {
    name: 'one part more than one CI job holds is refused, with the sentence that says how many it holds',
    plant: (d) => {
      for (let i = 0; i < PER_JOB; i++) copyAs(d, `held${String.fromCharCode(97 + i)}-button`)
    },
    expect: (p, html, ok, logs) => !ok && p === null && logs.some((l) => l.includes(`${PER_JOB + 1} parts in one job, more than one CI job holds. ${capacitySentence()}`)),
  },
  {
    name: 'a part.json that names a property to allow is refused at discovery',
    only: ['pressed'],
    plant: (d) => edit(join(d, 'part.json'), (s) => JSON.stringify({ ...JSON.parse(s), allow: { 'mix-blend-mode': 'a reason' } })),
    expect: refused(/part\.json "allow" is gone/),
  },
  {
    name: 'a <style> in example.html fails the run',
    only: ['pressed'],
    plant: (d) => edit(join(d, 'example.html'), (s) => `<style>button { background-image: linear-gradient(#ff0000, #ff0000) }</style>\n${s}`),
    expect: (p, html, ok) => !ok && p === null,
  },
  {
    name: 'a part folder without press.mjs fails the run',
    only: ['pressed'],
    plant: (d) => rmSync(join(d, 'press.mjs')),
    expect: (p, html, ok) => !ok && p === null,
  },
]

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  let failures = 0
  // node check/selftest.mjs <words>: only the cases whose name holds those words.
  const pick = process.argv.slice(2).join(' ')
  const run = CASES.filter((c) => c.name.includes(pick))
  const start = Date.now()
  let now = ''
  enforceCeiling(SELFTEST_CEILING, (s) => `FAIL the selftest passed its ceiling of ${s} s while "${now}" ran. ${selftestSentence()} Read it again on CI's runner and put the reading in check/capacity.mjs, or split the selftest across jobs.`)
  for (const c of run) {
    now = c.name
    if (c.direct) {
      const t0 = Date.now()
      const held = await c.direct()
      if (!held) failures++
      console.log(`${held ? 'pass' : 'FAIL'} ${c.name} (${((Date.now() - t0) / 1000).toFixed(1)}s)`)
      continue
    }
    const scratch = mkdtempSync(join(tmpdir(), 'barkui-selftest-'))
    try {
      const dir = join(scratch, 'parts')
      const out = join(scratch, 'out')
      cpSync(join(partsDir, 'button'), join(dir, 'button'), { recursive: true })
      c.plant?.(join(dir, 'button'))
      const t0 = Date.now()
      const logs = []
      const { ok, proof } = await runCheck({ dir, out, proofFile: join(scratch, 'proof.json'), only: c.only, surfaces: !!c.surfaces, motion: !!c.motion, states: !!c.states, plantCss: c.css, log: (l) => logs.push(l) })
      const secs = (Date.now() - t0) / 1000
      let html = ''
      try {
        html = readFileSync(join(out, 'index.html'), 'utf8')
      } catch {}
      const held = (c.green ? ok : !ok) && (await c.expect(proof, html, ok, logs, out)) && secs < (c.secs ?? 60)
      if (!held) failures++
      console.log(`${held ? 'pass' : 'FAIL'} ${c.name} (${secs.toFixed(1)}s)`)
      if (!held) console.log(logs.map((l) => `    ${l}`).join('\n'))
    } finally {
      rmSync(scratch, { recursive: true, force: true })
    }
  }
  console.log(`selftest: ${run.length - failures} of ${run.length} cases held, in ${Math.round((Date.now() - start) / 1000)}s`)
  process.exit(failures ? 1 : 0)
}
