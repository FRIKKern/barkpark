import { cpSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { discoverParts, NOT_COVERED_WORDS, REQUIRED_FILES } from '../build/parts.mjs'

const realParts = join(import.meta.dirname, '..', 'parts')
let dirs = []
const scratch = () => {
  const d = mkdtempSync(join(tmpdir(), 'barkui-parts-'))
  dirs.push(d)
  return d
}
afterEach(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true })
  dirs = []
})

// A folder that is a valid part, written from nothing but its own files.
function plantPart(root, name, skip = [], example) {
  const dir = join(root, name)
  cpSync(join(realParts, 'button'), dir, { recursive: true })
  // The button's ids, moved under this part's own prefix.
  const html = readFileSync(join(dir, 'example.html'), 'utf8').replaceAll('id="button-', `id="${name}-`)
  writeFileSync(join(dir, 'example.html'), example ?? html)
  writeFileSync(
    join(dir, 'part.json'),
    JSON.stringify({ name, family: 'test', element: 'ui-button', imports: ['@ui-sdk/web/button'], summary: 'A planted part.' }),
  )
  for (const f of skip) rmSync(join(dir, f))
  return dir
}

describe('discoverParts', () => {
  it('finds every part folder in the real tree, button among them', () => {
    const names = discoverParts(realParts).map((p) => p.name)
    expect(names).toContain('button')
    expect(names).toEqual(readdirSync(realParts, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name).sort())
  })

  it('finds a new folder with no edit anywhere else', () => {
    const root = scratch()
    cpSync(realParts, root, { recursive: true })
    const before = discoverParts(root).map((p) => p.name)
    plantPart(root, 'zz-planted')
    const after = discoverParts(root).map((p) => p.name)
    // Whatever the real parts are called: the planted one is added, and nothing else changes.
    expect([...after].sort()).toEqual([...before, 'zz-planted'].sort())
    const planted = discoverParts(root).find((p) => p.name === 'zz-planted')
    expect(planted.example).toContain('ui-button')
    expect(planted.json.summary).toBe('A planted part.')
  })

  for (const missing of REQUIRED_FILES) {
    it(`refuses a folder with no ${missing}, naming the folder and the file`, () => {
      const root = scratch()
      plantPart(root, 'half-done', [missing])
      expect(() => discoverParts(root)).toThrow(new RegExp(`half-done.*${missing.replace('.', '\\.')}`))
    })
  }

  it('refuses a part.json whose name is not its folder', () => {
    const root = scratch()
    const dir = plantPart(root, 'one')
    writeFileSync(join(dir, 'part.json'), JSON.stringify({ name: 'two', family: 'x', element: 'ui-button', imports: [], summary: 's' }))
    expect(() => discoverParts(root)).toThrow(/one.*part\.json.*"two"/)
  })

  it('gives each part a content hash that moves when any of its files moves', () => {
    const root = scratch()
    const dir = plantPart(root, 'hashed')
    const a = discoverParts(root)[0].hash
    writeFileSync(join(dir, 'example.html'), '<p>changed</p>')
    expect(discoverParts(root)[0].hash).not.toBe(a)
  })

  it('refuses an example id outside the part\'s own prefix', () => {
    const root = scratch()
    plantPart(root, 'aa', [], '<ui-button><button id="save" data-slot="button">Save</button></ui-button>')
    expect(() => discoverParts(root)).toThrow(/parts\/aa: example\.html id "save" must start with "aa-"/)
  })

  it('refuses two parts that print the same id', () => {
    const root = scratch()
    plantPart(root, 'aa', [], '<ui-button><button id="aa-x-1" data-slot="button">One</button></ui-button>')
    plantPart(root, 'aa-x', [], '<ui-button><button id="aa-x-1" data-slot="button">Two</button></ui-button>')
    expect(() => discoverParts(root)).toThrow(/id "aa-x-1" is printed by both parts\/aa and parts\/aa-x/)
  })

  it('refuses a demo.mjs that is not one function of its part\'s root', () => {
    const root = scratch()
    const dir = plantPart(root, 'aa')
    writeFileSync(join(dir, 'demo.mjs'), "for (const el of document.querySelectorAll('ui-button')) el.remove()\n")
    expect(() => discoverParts(root)).toThrow(/parts\/aa: demo\.mjs must `export default function \(root\)`/)
  })

  for (const [what, line] of [
    ['a <style> element', '<style>button { background-image: linear-gradient(red, red) }</style>'],
    ['a style= attribute', '<ui-button><button id="aa-x" data-slot="button" style="background: #fff">X</button></ui-button>'],
    ['an on*= handler', '<ui-button><button id="aa-x" data-slot="button" onclick="go()">X</button></ui-button>'],
    ['a <script> element', '<script>document.body.remove()</script>'],
    ['a <font> element', '<font color="red">X</font>'],
    ['a bgcolor= attribute', '<table bgcolor="#ff0000"><tr><td>X</td></tr></table>'],
    ['a declared shadow root', '<div><template shadowrootmode="open"><b>Ghost</b></template></div>'],
    ['a <canvas> element', '<canvas width="40" height="10"></canvas>'],
    ['an <iframe> element', '<iframe src="data:text/html,x"></iframe>'],
    ['a <video> element', '<video></video>'],
  ]) {
    it(`refuses an example.html with ${what}, naming the file and line`, () => {
      const root = scratch()
      plantPart(root, 'aa', [], `<p>fine</p>\n${line}\n`)
      expect(() => discoverParts(root)).toThrow(/parts\/aa\/example\.html line 2: /)
    })
  }

  const withDemo = (line, css = '') => {
    const root = scratch()
    const dir = plantPart(root, 'aa')
    writeFileSync(join(dir, 'demo.mjs'), `export default function demo(root) {\n  ${line}\n}\n`)
    if (css) writeFileSync(join(dir, 'part.css'), readFileSync(join(dir, 'part.css'), 'utf8') + css)
    return root
  }
  for (const [what, line] of [
    ['an inline style', "root.querySelector('button').style.color = '#ff0000'"],
    ['a style attribute', "root.querySelector('button').setAttribute('style', 'color: red')"],
    ['cssText', "root.firstElementChild.cssText"],
    ['a typed inline style', "root.querySelector('button').attributeStyleMap.set('color', 'red')"],
    ['a new <style>', "document.head.append(document.createElement('style'))"],
    ['a new <link>', 'document.head.append(document.createElement("link"))'],
    ['markup with a style', "root.insertAdjacentHTML('beforeend', '<b style=\"color:red\">x</b>')"],
    ['insertRule', 'document.styleSheets[0].insertRule("b{}")'],
    ['an adopted sheet', 'document.adoptedStyleSheets = []'],
    ['a constructed sheet', 'new CSSStyleSheet()'],
    ['a script animation', "root.querySelector('button').animate([{ opacity: 0 }], 9)"],
    ['a class part.css never declares', "root.querySelector('button').classList.add('loud')"],
    ['a class set by name', "root.querySelector('button').className = 'aa-x'"],
    ['a class set as an attribute', "root.querySelector('button').setAttribute('class', 'aa-x')"],
    ['a class from a variable', "root.querySelector('button').classList.toggle(name)"],
  ]) {
    it(`refuses a demo.mjs with ${what}, naming the file and line`, () => {
      expect(() => discoverParts(withDemo(line))).toThrow(/parts\/aa\/demo\.mjs line 2: /)
    })
  }

  it('lets a demo add a class that part.css declares', () => {
    expect(() => discoverParts(withDemo("root.querySelector('button').classList.add('aa-open')", '\n.aa-open { gap: 4px; }\n'))).not.toThrow()
  })

  it('refuses a part.json whose textOnly is not a list of selectors', () => {
    const root = scratch()
    const dir = plantPart(root, 'aa')
    const json = JSON.parse(readFileSync(join(dir, 'part.json'), 'utf8'))
    writeFileSync(join(dir, 'part.json'), JSON.stringify({ ...json, textOnly: '[data-variant="ghost"]' }))
    expect(() => discoverParts(root)).toThrow(/parts\/aa: part\.json "textOnly" must be a list of selectors/)
  })

  it('takes a notCovered list of { name, why }, and refuses any other shape, null, or a name given twice in any case', () => {
    const root = scratch()
    const dir = plantPart(root, 'aa')
    const json = JSON.parse(readFileSync(join(dir, 'part.json'), 'utf8'))
    const withList = (notCovered) => {
      writeFileSync(join(dir, 'part.json'), JSON.stringify({ ...json, notCovered }))
      return () => discoverParts(root)
    }
    expect(withList([{ name: 'ui-badge', why: 'Not on the stage.' }])).not.toThrow()
    for (const bad of [null, 'ui-badge', [{ name: 'ui-badge' }], [{ name: 'ui-badge', why: 'x', more: 1 }], [{ name: ' ', why: 'x' }], [{ name: 'ui-badge', why: '' }]])
      expect(withList(bad), JSON.stringify(bad)).toThrow(/parts\/aa: part\.json "notCovered" must be a list of \{ name, why \}/)
    expect(withList([{ name: 'a', why: 'x' }, { name: 'a', why: 'y' }])).toThrow(/part\.json "notCovered" names "a" twice/)
     expect(withList([{ name: 'ui-tabs-indicator', why: 'x' }, { name: 'UI-TABS-INDICATOR', why: 'y' }])).toThrow(/part\.json "notCovered" names "UI-TABS-INDICATOR" twice/)
  })

  it('excuses a sentence by a row only where the row’s name stands in it as whole words, in any case and across a line break', () => {
    const root = scratch()
    const dir = plantPart(root, 'aa')
    const json = JSON.parse(readFileSync(join(dir, 'part.json'), 'utf8'))
    const css = readFileSync(join(dir, 'part.css'), 'utf8')
    const read = (name, note) => {
      writeFileSync(join(dir, 'part.json'), JSON.stringify({ ...json, notCovered: [{ name, why: 'x' }] }))
      writeFileSync(join(dir, 'part.css'), `${css}\n/* ${note} */\n`)
      return () => discoverParts(root)
    }
    expect(read('ui-tabs', 'The ui-tabs-indicator is not styled.')).toThrow(/part\.css's notes says something is not covered/)
    expect(read('rip', 'The ripple is not styled.')).toThrow(/part\.css's notes says something is not covered/)
    expect(read('ui-tabs-indicator', 'The ui-tabs-indicator is not styled.')).not.toThrow()
    expect(read('tabs indicator', 'The Tabs\n   Indicator is not styled.')).not.toThrow()
    // The row's second limit (docs/PARTS.md): the name stands in the sentence; the row does not read what it is about.
    expect(read('the', 'The ripple is not styled.')).not.toThrow()
  })

  it('reads exactly the words of NOT_COVERED_WORDS in the notes, in any case and across a line break, and not a sentence in other words', () => {
    const root = scratch()
    const dir = plantPart(root, 'aa')
    const css = readFileSync(join(dir, 'part.css'), 'utf8')
    const notes = (n) => {
      writeFileSync(join(dir, 'part.css'), `${css}\n/* ${n} */\n`)
      return () => discoverParts(root)
    }
    for (const w of NOT_COVERED_WORDS) expect(notes(`The ripple is ${w}.`), w).toThrow(/part\.css's notes says something is not covered/)
    expect(notes('The ripple is NOT\n   STYLED.')).toThrow(/\("The ripple is NOT STYLED\."\)/)
    // The row's first limit (docs/PARTS.md): other words are not read.
    expect(notes('The ripple is left as UI SDK draws it.')).not.toThrow()
  })

  it('takes a part.json layer with its box and real input, and refuses one without them', () => {
    const root = scratch()
    const dir = plantPart(root, 'aa')
    const json = JSON.parse(readFileSync(join(dir, 'part.json'), 'utf8'))
    const good = { box: '#aa-pop', open: { click: '#aa-open' }, close: { keys: ['Escape'] } }
    writeFileSync(join(dir, 'part.json'), JSON.stringify({ ...json, layers: [good] }))
    expect(() => discoverParts(root)).not.toThrow()
    writeFileSync(join(dir, 'part.json'), JSON.stringify({ ...json, layers: [{ box: '#aa-tip', open: { hover: '#aa-open' }, close: { leave: true } }] }))
    expect(() => discoverParts(root)).not.toThrow()
    for (const layers of [good, [{ ...good, close: { leave: 'yes' } }], [{ ...good, open: { hover: '' } }], [{ ...good, box: '' }], [{ box: '#aa-pop', open: { click: '#aa-open' } }], [{ ...good, open: {} }], [{ ...good, close: { keys: 'Escape' } }], [{ ...good, open: { script: 'x' } }], [{ ...good, pin: 'open' }]]) {
      writeFileSync(join(dir, 'part.json'), JSON.stringify({ ...json, layers }))
      expect(() => discoverParts(root)).toThrow(/parts\/aa: part\.json "layers" must be a list of \{ box, open, close \}/)
    }
  })

  it('refuses a part.json that tries to excuse a property (allow is gone)', () => {
    const root = scratch()
    const dir = plantPart(root, 'aa')
    const json = JSON.parse(readFileSync(join(dir, 'part.json'), 'utf8'))
    for (const allow of [{ filter: 'a reason' }, {}]) {
      writeFileSync(join(dir, 'part.json'), JSON.stringify({ ...json, allow }))
      expect(() => discoverParts(root)).toThrow(/parts\/aa: part\.json "allow" is gone: a part cannot excuse itself/)
    }
  })
})
