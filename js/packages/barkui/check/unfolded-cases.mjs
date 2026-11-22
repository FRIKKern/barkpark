// Two selftest cases that outgrew the share of the one limit a case may take (check/capacity.mjs), each unfolded
// into runs: every surface read, and real states held to their pins. A run reads only what its rows need, so each
// is cheaper than the one case was; every row the case held is in exactly one run (tests/unfold.test.mjs).
import { appendFileSync, cpSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { chromium } from 'playwright'
import { partsDir } from '../build/parts.mjs'
import { buildShowroom } from '../build/showroom.mjs'
import { readPartCss } from './cssom.mjs'
import { UNNAMED } from './layers.mjs'
import { open } from './proofs.mjs'
import { stageKinds } from './states.mjs'
import { all, both, drawnOff, DRAWN, each, edit, esc, inCss, inDemo, reasons, says, skinsSay } from './plants.mjs'

// Every surface read, in two runs whose surfaces together are all of them (each also reads base).
// Fields in UI SDK's own look: a placeholder in the waited pair (muted text on the field's background) in an input
// and in a textarea, elements that draw no children, and one on another ground. fjord light's primary is planted
// worse below, so the waited ones are red there by design.
const FIELDS = (d) =>
  edit(join(d, 'example.html'), (s) =>
    `${s}\n<div data-demo-row>\n  <span data-demo-label>Fields</span>\n  <input id="button-ph-waited" data-slot="input" placeholder="Waited">\n  <input id="button-ph-other" data-slot="input" placeholder="Other ground">\n  <textarea id="button-ph-area" data-slot="textarea" placeholder="Waited, in a textarea"></textarea>\n</div>\n`)
const surfaceRows = {
  raised: {
    'a label gone on raised': both(new RegExp(`on raised: .*${DRAWN} at button#button-secondary`)),
  },
  primary: {
    'a second skin short on primary': says('schemes', /evergreen dark on primary: drawn text [\d.]+:1 at span/),
    'the waited pair worse than recorded': says('skins', /fjord light on primary: drawn text [\d.]+:1 at span .*, under the 3\.75:1 its wait on the sheet records/),
    'a placeholder on another ground stays red': says('skins', /on primary: drawn text [\d.]+:1 at input#button-ph-other ""::placeholder/),
    'a placeholder in the waited pair is let through by its wait, in an input and in a textarea': (p) =>
      !['skins', 'schemes'].some((l) => reasons(p, l).some((f) => /at (input#button-ph-waited|textarea#button-ph-area) ""::placeholder/.test(f) && !/fjord light/.test(f))),
    'no reader puts a child into an element it measures': (p) => !['skins', 'schemes'].some((l) => reasons(p, l).some((f) => /a reader put a child into/.test(f))),
  },
}
// Waits on the sheet are bound to their view and pair; everything else is proved on every surface.
export const SURFACE_CASES = [
  {
    name: 'every surface read, raised and sunken: a label gone on raised turns both wide lights off at its control',
    only: ['skins', 'schemes'],
    surfaces: ['raised', 'sunken'],
    css: '.sr-stage[data-surface="raised"] #button-secondary { --bark-button-fg: var(--bark-button-bg); }',
    expect: each(surfaceRows.raised),
  },
  {
    name: 'every surface read, primary and inverse: a second skin short on primary and a waited pair measuring worse turn the lights off; a placeholder is matched to a wait by its own colour',
    only: ['skins', 'schemes'],
    surfaces: ['primary', 'inverse'],
    plant: FIELDS,
    css: [
      'html[data-skin="evergreen"][data-color-scheme="dark"] .sr-stage[data-surface="primary"] [data-demo-label] { color: var(--ui-border); }',
      'html[data-skin="fjord"][data-color-scheme="light"] .sr-stage[data-surface="primary"] { --ui-muted-foreground: var(--ui-border); }',
      '#button-ph-other { background: var(--ui-muted); }',
    ].join('\n'),
    expect: each(surfaceRows.primary),
  },
]

// Real states held to their pins (states.mjs, coverage.mjs), in three runs: what the wide views draw while a state
// holds; what the press steps reach; and the rules nothing reads, which only a run of every light can say.
const PENDING = inCss('[data-slot="button"][data-pending] { --bark-button-fg: var(--bark-button-bg); }')
// A rule that applies to nothing, and a dead branch beside one that applies at every reading.
const DEAD = inCss('[data-slot="button"][data-size="xl"] { gap: 0; }')
const DEAD_BRANCH = inCss('[data-slot="button"], [data-slot="button"][data-variant="huge"] { --bark-button-text: 0.875rem; }')
// The run of every light reads a smaller stage, so it costs less: the button's stage without the controls that only
// repeat a kind another control there already gives. It loses only repeats: what the check reads there, by kind
// (each state drive, each pinned control, each rule at rest), is what it reads on the whole stage, fewer of each (a
// direct case below holds that, with both counts). A line here that the stage no longer has fails the plant.
const REPEATS = [
  /\n  <ui-button><button data-slot="button" type="button">Medium<\/button><\/ui-button>/,
  /\n  <ui-button><button data-slot="button" type="button"><svg[^\n]*New page<\/button><\/ui-button>/,
  /\n  <button data-slot="button"[^>\n]*>Rest<\/button>/g,
]
const SMALLER = (d) =>
  edit(join(d, 'example.html'), (s) =>
    REPEATS.reduce((t, r) => {
      if (!r.test(t)) throw new Error(`the smaller stage drops ${r}, which the button's stage no longer has`)
      r.lastIndex = 0
      return t.replace(r, '')
    }, s),
  )
const stateRows = {
  drawn: {
    'a hover on a second control of its kind': skinsSay(/real hover on button#button-after "Duplicate": .*no pinned row shows this change/),
    'a hover through :nth-child on a later control': skinsSay(/real hover on button "Medium": .*no pinned row shows this change/),
    'the hover, drawn on every control it applies to': skinsSay(/hover held on every live control it applies to, .*: text does not draw at button#button-after "Duplicate"/),
    'the pin unlike the real state on the control itself': skinsSay(/real hover on button#button-destructive "Delete": .* where the control pinned /),
    'pending held at rest, in every view': drawnOff('button "Saving"'),
    'a hover that only dark shows': skinsSay(/hover held on every live control it applies to, \w+ dark on base: .*at button#button-save "Save changes"/),
    'an uppercase :HOVER the pin never shows': skinsSay(/real hover on button#button-primary "Publish": .*no pinned row shows this change/),
    'a hover on the host': skinsSay(/real hover on button#button-destructive "Delete": .*no pinned row shows this change/),
    // Held only by the look after the state drive's own input.
    'a tooltip open only while a driven state holds, named by no layer': skinsSay(new RegExp(`^real hover on button#button-after "Duplicate": ${esc(UNNAMED('div#button-hover-tip "Shown on hover"'))}$`)),
  },
  steps: {
    // The other side of the rule the unread rows hold: a run without every light names no rule unread, not even
    // one that applies to nothing.
    'a run without every light names no rule unread': (p) => !p.parts.button.unread,
    'pending reached by the steps': (p) => (p.parts.button.steps ?? []).some((st) => /drawn after this step, .*at button#button-save "Save changes"/.test(st.detail)),
    // Held only by the look after the press step's own input: its result is the sentence alone; a reading after
    // the step would say "drawn after this step, …" first.
    'a box open only after a press step, named by no layer': (p) => (p.parts.button.steps ?? []).some((st) => st.name === 'Space activates it' && st.detail === UNNAMED('div#button-press-tip "Shown on Space"')),
  },
  unread: {
    'a rule nothing reads': (p) => (p.parts.button.unread ?? []).some((u) => u.startsWith('a rule nothing read: [data-slot="button"][data-size="xl"]')),
    'a branch nothing reads, beside one that is read': (p) => (p.parts.button.unread ?? []).some((u) => u.startsWith('a branch nothing read: [data-slot="button"][data-variant="huge"], of ')),
    // The smaller stage leaves the run as it was: no light goes off and no page errs (the part fails first for its
    // first unread line, check.mjs), every press step passes, and nothing but the two planted rules goes unread.
    'every light passes on the smaller stage': (p) => p.parts.button.failed === p.parts.button.unread?.[0] && p.parts.button.steps?.length > 0 && p.parts.button.steps.every((s) => s.pass),
    'nothing else is unread': (p) => (p.parts.button.unread ?? []).length === 2,
  },
}
export const STATE_CASES = [
  {
    name: 'states, as drawn: a state on any control of its kind, pending held at rest, and a box open only while a driven state holds each fail by name',
    only: ['skins', 'schemes'],
    states: true,
    plant: all(
      // The review's: a second control of the secondary kind, and pending.
      inCss('#button-after:hover { --bark-button-hover-fg: var(--bark-button-hover-bg); --bark-button-hover-edge: var(--bark-button-hover-bg); }'),
      PENDING,
      // A later control reached by structure alone.
      inCss('[data-demo-row]:nth-child(4) > ui-button:nth-child(3) > [data-slot="button"]:hover { --bark-button-hover-fg: var(--bark-button-hover-bg); }'),
      // The round-10 review's: a token colour on hover that computes like the pin in light and draws about 2:1 in dark.
      inCss('#button-save:hover { color: var(--bark-success-foreground); }'),
      // A box no layer names, open only while the pointer is on the Duplicate button (a driven state).
      (d) => appendFileSync(join(d, 'example.html'), '\n<div data-demo-row><div id="button-hover-tip" popover="manual">Shown on hover</div></div>\n'),
      (d) => inDemo(d, "{ const b = root.querySelector('#button-after'), t = root.querySelector('#button-hover-tip'); b.addEventListener('mouseenter', () => t.showPopover()); b.addEventListener('mouseleave', () => t.hidePopover()) }"),
    ),
    css: [
      // Beyond the walls (this sheet is the selftest's own, and never pinned): the round-8 review's two hover rules,
      // the first kept off the save button, which the dark-only plant above needs proven and held.
      '[data-slot="button"][data-variant="solid"]:HOVER:not([data-disabled], #button-save) { --bark-button-hover-fg: var(--bark-button-hover-bg); }',
      'ui-button:hover > #button-destructive { --bark-button-hover-fg: var(--bark-button-hover-bg); --bark-button-hover-edge: var(--bark-button-hover-bg); }',
    ].join('\n'),
    expect: each(stateRows.drawn),
  },
  {
    name: 'states, by the press steps: pending reached by the steps, and a box open only after a press step, each fail by name',
    only: ['pressed'],
    states: true,
    plant: all(
      PENDING,
      DEAD,
      // A box no layer names, open from Space on the primary button until the next key (a press step).
      (d) => appendFileSync(join(d, 'example.html'), '\n<div data-demo-row><div id="button-press-tip" popover="manual">Shown on Space</div></div>\n'),
      (d) => inDemo(d, "{ const b = root.querySelector('#button-primary'), t = root.querySelector('#button-press-tip'); b.addEventListener('keydown', (e) => (e.key === ' ' ? t.matches(':popover-open') || t.showPopover() : t.matches(':popover-open') && t.hidePopover())) }"),
    ),
    expect: each(stateRows.steps),
  },
  {
    name: 'states, once every light has read: a rule nothing reads, and a branch nothing reads beside one that is read, each fail by name',
    only: ['pressed', 'skins', 'schemes', 'phone', 'noscript'],
    states: true,
    plant: all(SMALLER, DEAD, DEAD_BRANCH),
    expect: each(stateRows.unread),
  },
  {
    name: 'the run of every light reads a smaller stage that loses only repeats: every kind of state drive the whole stage has, fewer of each',
    direct: smallerLosesOnlyRepeats,
  },
]

/** The kinds of state drive the check plans on the whole button stage and on the smaller one, with the run's own
    rules planted in both: the same kinds, and fewer drives on the smaller. Prints both counts. */
async function smallerLosesOnlyRepeats() {
  const scratch = mkdtempSync(join(tmpdir(), 'barkui-selftest-'))
  const browser = await chromium.launch()
  try {
    const plan = {}
    for (const [side, plants] of [['whole', all(DEAD, DEAD_BRANCH)], ['smaller', all(SMALLER, DEAD, DEAD_BRANCH)]]) {
      const dir = join(scratch, side, 'parts')
      cpSync(join(partsDir, 'button'), join(dir, 'button'), { recursive: true })
      plants(join(dir, 'button'))
      const built = await buildShowroom({ dir, out: join(scratch, side, 'out'), proof: join(scratch, side, 'proof.json'), quiet: true })
      const part = built.parts.find((x) => x.name === 'button')
      const { entries } = await readPartCss(browser, part.css)
      const page = await open({ browser, url: pathToFileURL(built.file).href, part: part.name, errors: [] })
      plan[side] = await stageKinds(page, part.name, entries)
      await page.context().close()
    }
    const { whole, smaller } = plan
    const lost = whole.kinds.filter((k) => !smaller.kinds.includes(k))
    const gained = smaller.kinds.filter((k) => !whole.kinds.includes(k))
    const say = (p) => `${p.kinds.length} kinds, ${p.drives} state drives, ${p.pins} pinned controls`
    console.log(`    the whole stage: ${say(whole)}; the smaller: ${say(smaller)}`)
    if (lost.length || gained.length) console.log(`    kinds lost: ${lost.join('; ') || 'none'}; kinds gained: ${gained.join('; ') || 'none'}`)
    return whole.kinds.length > 0 && !lost.length && !gained.length && smaller.drives + smaller.pins < whole.drives + whole.pins
  } finally {
    await browser.close()
    rmSync(scratch, { recursive: true, force: true })
  }
}

/** The rows of each unfolded case, by run, as the runs hold them. */
export const UNFOLDED_ROWS = {
  surfaces: Object.fromEntries(Object.entries(surfaceRows).map(([k, rows]) => [k, Object.keys(rows)])),
  states: Object.fromEntries(Object.entries(stateRows).map(([k, rows]) => [k, Object.keys(rows)])),
}
