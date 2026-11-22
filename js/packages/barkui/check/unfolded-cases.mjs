// Two selftest cases that outgrew the share of the one limit a case may take (check/capacity.mjs), each unfolded
// into runs: every surface read, and real states held to their pins. A run reads only what its rows need, so each
// is cheaper than the one case was; every row the case held is in exactly one run (tests/unfold.test.mjs).
import { appendFileSync } from 'node:fs'
import { join } from 'node:path'
import { UNNAMED } from './layers.mjs'
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
    'pending reached by the steps': (p) => (p.parts.button.steps ?? []).some((st) => /drawn after this step, .*at button#button-save "Save changes"/.test(st.detail)),
    // Held only by the look after the press step's own input: its result is the sentence alone; a reading after
    // the step would say "drawn after this step, …" first.
    'a box open only after a press step, named by no layer': (p) => (p.parts.button.steps ?? []).some((st) => st.name === 'Space activates it' && st.detail === UNNAMED('div#button-press-tip "Shown on Space"')),
  },
  unread: {
    'a rule nothing reads': (p) => (p.parts.button.unread ?? []).some((u) => u.startsWith('a rule nothing read: [data-slot="button"][data-size="xl"]')),
    'a branch nothing reads, beside one that is read': (p) => (p.parts.button.unread ?? []).some((u) => u.startsWith('a branch nothing read: [data-slot="button"][data-variant="huge"], of ')),
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
    plant: all(
      // A rule that applies to nothing, and a dead branch beside one that applies at every reading.
      inCss('[data-slot="button"][data-size="xl"] { gap: 0; }'),
      inCss('[data-slot="button"], [data-slot="button"][data-variant="huge"] { --bark-button-text: 0.875rem; }'),
    ),
    expect: each(stateRows.unread),
  },
]

/** The rows of each unfolded case, by run, as the runs hold them. */
export const UNFOLDED_ROWS = {
  surfaces: Object.fromEntries(Object.entries(surfaceRows).map(([k, rows]) => [k, Object.keys(rows)])),
  states: Object.fromEntries(Object.entries(stateRows).map(([k, rows]) => [k, Object.keys(rows)])),
}
