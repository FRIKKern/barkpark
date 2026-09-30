import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

// r2b click-to-edit census (task-bbfdcf4c80b8300d): authored text in pipeline,
// lineage, duel, heatmap, chart and form/questionnaire paints was read-only in
// Edit (0/n in place). Each stored string the reader paints now edits where it
// reads; numbers and derived readouts stay panel-edited; reader bytes are kept.
const { window } = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true, url: "http://localhost/" });
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MouseEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: String };
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects = () => [];
window.Range.prototype.getBoundingClientRect = () => ({ top: 0, left: 0, right: 0, bottom: 0 });
await import("../index.js");

function mount(block, html) {
  const host = document.createElement("bp-paper-canvas");
  host.blocks = [block];
  const batches = [];
  host.addEventListener("bp-canvas-ops", e => batches.push(e.detail));
  document.body.appendChild(host);
  const hole = host.querySelector("[data-bp-fleet-body]");
  assert.ok(hole, `${block.type}: mounts as a server-painted fleet block`);
  const event = new CustomEvent("bp-fleet-paint", { detail: { html, sourceBlock: block }, cancelable: true });
  if (hole.dispatchEvent(event)) hole.innerHTML = html;
  return { host, batches, hole };
}
function type(host, el, text) {
  el.focus();
  el.textContent = text;
  el.dispatchEvent(new Event("input", { bubbles: true }));
  host.flushPendingChanges();
  el.blur();
}
const hosts = (host) => [...host.querySelectorAll("[data-bp-fleet-body] [role=textbox]")];
const lastPatch = (batches) => batches.at(-1)?.ops.at(-1)?.patch;

const cases = [
  {
    block: { id: "pl", type: "pipeline", nodes: [
      { detail: "blocks in Studio", kind: "author", source: true, title: "write" },
      { detail: "one atomic document", kind: "publish", title: "commit", extra: 1 },
    ] },
    html: `<div class="bp-pipe-scroll"><div class="bp-pipe"><div class="bp-pnode bp-pnode--src"><div class="bp-pnode__k">author</div><div class="bp-pnode__t">write</div><div class="bp-pnode__d">blocks in Studio</div></div><span class="bp-pipe__arr">→</span><div class="bp-pnode"><div class="bp-pnode__k">publish</div><div class="bp-pnode__t">commit</div><div class="bp-pnode__d">one atomic document</div></div></div></div>`,
    painted: ["author", "write", "blocks in Studio", "publish", "commit", "one atomic document"],
    edit: [4, "commit!"], expect: (b) => { b.nodes[1].title = "commit!"; },
  },
  {
    block: { id: "ln", type: "lineage", nodes: [
      { body: "Et kveldsprosjekt.", overline: "2025", title: "nextgen", unit: "commits", value: "335" },
      { overline: "i dag", title: "Kommandoer", unit: "kommandoer", value: 22 },
    ], sourceDefault: "paper:x" },
    html: `<div class="bp-lineage"><ol class="bp-lineage__nodes"><li class="bp-lineage__node"><div class="bp-lineage__overline">2025</div><div class="bp-lineage__title">nextgen</div><div class="bp-lineage__value">335<span class="bp-lineage__unit">commits</span></div><div class="bp-lineage__body">Et kveldsprosjekt.</div></li><li class="bp-lineage__node"><div class="bp-lineage__overline">i dag</div><div class="bp-lineage__title">Kommandoer</div><div class="bp-lineage__value">22<span class="bp-lineage__unit">kommandoer</span></div></li></ol><p class="bp-kilde"><span class="bp-kilde__word">Kilder</span><span class="bp-kilde__ref">paper:x</span></p></div>`,
    // a numeric value (22) stays panel-edited; the source line is derived
    painted: ["2025", "nextgen", "335", "commits", "Et kveldsprosjekt.", "i dag", "Kommandoer", "kommandoer"],
    edit: [2, "336"], expect: (b) => { b.nodes[0].value = "336"; },
  },
  {
    block: { id: "du", type: "duel", legendA: "Med", legendB: "Uten", rows: [{ delta: "−30 %", label: "add-error", valueA: "1 478", valueB: "2 121" }] },
    html: `<div class="bp-duel"><table class="bp-duel__table"><thead><tr><th class="bp-duel__th"></th><th class="bp-duel__th bp-duel__th--a" scope="col">Med</th><th class="bp-duel__th" scope="col">Uten</th></tr></thead><tbody><tr class="bp-duel__row"><th class="bp-duel__label" scope="row">add-error<span class="bp-duel__delta">−30 %</span></th><td class="bp-duel__val bp-duel__val--a">1 478</td><td class="bp-duel__val">2 121</td></tr></tbody></table></div>`,
    painted: ["Med", "Uten", "add-error", "−30 %", "1 478", "2 121"],
    edit: [0, "Med katalogen"], expect: (b) => { b.legendA = "Med katalogen"; },
  },
  {
    block: { id: "hm", type: "heatmap", cells: [[2, 5], [1, 3]], colLabels: ["Mon", "Tue"], rowLabels: ["reader", "tui"] },
    html: `<div class="bp-heat"><div class="bp-heat__grid"><span class="bp-heat__rl"></span><span class="bp-heat__cl">Mon</span><span class="bp-heat__cl">Tue</span><span class="bp-heat__rl">reader</span><i class="bp-heat__c"></i><i class="bp-heat__c"></i><span class="bp-heat__rl">tui</span><i class="bp-heat__c"></i><i class="bp-heat__c"></i></div></div>`,
    painted: ["Mon", "Tue", "reader", "tui"],
    edit: [3, "print"], expect: (b) => { b.rowLabels = ["reader", "print"]; },
  },
  {
    block: { id: "ch", type: "chart", kind: "line", caption: "Blocks by week", series: [{ label: "renderers", points: [1, 2] }] },
    html: `<div class="bp-chart"><div class="bp-chart__t">Blocks by week</div><div class="bp-chart__scroll"><svg></svg></div><div class="bp-chart__legend"><span class="bp-chart__key"><i class="bp-chart__swatch bp-chart__s0"></i>renderers</span></div></div>`,
    painted: ["Blocks by week", "renderers"],
    edit: [1, "readers"], expect: (b) => { b.series[0].label = "readers"; },
  },
  {
    block: { id: "fm", type: "form", kind: "grill", questions: [
      { id: "q1", prompt: "Which surface?", note: "Steers polish.", type: "single", options: ["reader", "studio"] },
      { id: "q2", prompt: "Ship it?", type: "yesno" },
    ] },
    html: `<section class="bp-form bp-form-questionnaire"><fieldset class="bp-form-question bp-form-q--single"><legend>Which surface?</legend><p class="bp-form-note">Steers polish.</p><div class="bp-form-opts"><label class="bp-form-opt"><input type="radio" name="n1" value="reader"> <span>reader</span></label><label class="bp-form-opt"><input type="radio" name="n1" value="studio"> <span>studio</span></label></div></fieldset><fieldset class="bp-form-question bp-form-q--yesno"><legend>Ship it?</legend><div class="bp-form-opts"><label class="bp-form-opt"><input type="radio" name="n2" value="Yes"> <span>Yes</span></label><label class="bp-form-opt"><input type="radio" name="n2" value="No"> <span>No</span></label></div></fieldset></section>`,
    // yes/no choices are derived from the question type, never stored
    painted: ["Which surface?", "Steers polish.", "reader", "studio", "Ship it?"],
    edit: [3, "studio!"], expect: (b) => { b.questions[0].options = ["reader", "studio!"]; },
  },
];

try {
  for (const c of cases) {
    const { host, batches, hole } = mount(c.block, c.html);
    try {
      const before = hole.textContent;
      const els = hosts(host);
      assert.deepEqual(els.map(el => el.textContent), c.painted, `${c.block.type}: every painted stored string edits in place`);
      assert.equal(hole.textContent, before, `${c.block.type}: decoration keeps the reader's painted text`);
      els[0].focus(); els[0].blur(); host.flushPendingChanges();
      assert.deepEqual(batches, [], `${c.block.type}: focus/blur is not an authored change`);
      type(host, els[c.edit[0]], c.edit[1]);
      const expected = structuredClone(c.block);
      c.expect(expected);
      const { id, type: _t, ...patch } = expected;
      assert.deepEqual(lastPatch(batches), patch, `${c.block.type}: only the edited string changes; every other key stays`);
    } finally { host.remove(); }
  }

  // A click on an option's text places the caret; it never checks the radio.
  const form = cases.at(-1);
  const { host } = mount(form.block, form.html);
  try {
    const span = host.querySelector(".bp-form-opt > span");
    const click = new MouseEvent("click", { bubbles: true, cancelable: true });
    span.dispatchEvent(click);
    assert.equal(click.defaultPrevented, true);
    assert.equal(host.querySelector("input[type=radio]").checked, false);
  } finally { host.remove(); }

  // A paint whose rows do not line up with the stored rows is never decorated.
  const { host: mismatch } = mount(cases[0].block, `<div class="bp-pipe"><div class="bp-pnode"><div class="bp-pnode__t">only</div></div></div>`);
  try { assert.deepEqual(hosts(mismatch), []); } finally { mismatch.remove(); }

  console.log("fleet text inline: pipeline, lineage, duel, heatmap, chart and form strings edit in place; numbers, derived text and mismatched paints refused");
} finally { window.close(); }
