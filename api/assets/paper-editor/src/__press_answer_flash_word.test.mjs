// AN ACTION'S ANSWER IS THE SERVER'S OWN SENTENCE (task-9379e57c6656704c).
//
// Stranger walk (2026-09-30): the press answer named the PRESSED control with a
// navigation/selection verb, which reads right for a row and wrong for an action
// button — "Unpublish" (the row's status moved) said "Selected “Unpublish”.",
// "Duplicate" (navigated to the copy) said "Opened “Duplicate”.", History's
// "Restore" said "Selected “Restore”." — each beside the server's own flash
// ("Unpublished", "Duplicated as …", "Restored from history"). A flash sentence
// that appeared since the press is now the answer, quoted verbatim.
//
// Bodies are EXTRACTED from the layout (same harness as
// __press_answer_fast_reply.test.mjs), so this measures the hook the browser runs.
import assert from "node:assert/strict";
import { test } from "node:test";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const layout = readFileSync(
  new URL("../../../lib/barkpark_web/layouts/root.html.heex", import.meta.url),
  "utf8",
);

function method(name, args) {
  const m = layout.match(
    new RegExp("\\n      " + name + "\\(" + args.replace(/[()]/g, "\\$&") + "\\) \\{([\\s\\S]*?)\\n      \\},"),
  );
  assert.ok(m, `the press answer's ${name}(${args}) must be locatable in root.html.heex`);
  return m[1];
}

const bodies = {
  _paRegion: ["", (layout.match(/\n      _paRegion\(\) \{(.*?)\},\n/) || assert.fail("the live region accessor must be locatable"))[1]],
  _paScopeFor: ["el", method("_paScopeFor", "el")],
  _paSay: ["text", method("_paSay", "text")],
  _paName: ["el", method("_paName", "el")],
  _paCurrentSig: ["root", method("_paCurrentSig", "root")],
  _paPressedWitness: ["el", method("_paPressedWitness", "el")],
  _paPressedChanged: ["witness, root", method("_paPressedChanged", "witness, root")],
  _paDropPending: ["keepFade", method("_paDropPending", "keepFade")],
  _paRelease: ["text", method("_paRelease", "text")],
  _paSettleWord: ["p", method("_paSettleWord", "p")],
  _paT: ["text, vars", method("_paT", "text, vars")],
  _paSettle: ["p", method("_paSettle", "p")],
  _paTick: ["p", method("_paTick", "p")],
  _paNativeDisclosureOnly: ["target, action", method("_paNativeDisclosureOnly", "target, action")],
  _paOnChromeAnchor: ["ev, t", method("_paOnChromeAnchor", "ev, t")],
  _paOnPress: ["ev", method("_paOnPress", "ev")],
};

// The editor header in its served shape: an action button inside #studio-panes
// beside the list row that is aria-current, plus the layout's flash slot.
function fixture({ flashBefore = "" } = {}) {
  const dom = new JSDOM(
    `<div id="flash-slot">${flashBefore ? `<div class="flash flash-info">${flashBefore}</div>` : ""}</div>
     <main id="studio-panes">
       <ul><li aria-current="true" aria-label="Hello, published">Hello</li></ul>
       <button type="button" id="unpublish" phx-click="unpublish" aria-label="Unpublish">U</button>
     </main>
     <p id="bp-press-answer"></p>`,
    { pretendToBeVisual: true, url: "http://localhost/w/default/p/default/d/production/studio/post/hello" },
  );
  const w = dom.window;
  const hook = {
    el: w.document.getElementById("studio-panes"),
    _PA_PROBE: 16, _PA_POLL: 100, _PA_WITNESS_GRACE: 750, _PA_CEILING: 1500, _PA_FADE: 1500,
    _paPending: null, _paPoll: 0, _paProbe: 0, _paCeil: 0, _paFadeT: 0, _paNavAway: false,
  };
  for (const [name, [args, body]] of Object.entries(bodies)) {
    hook[name] = new Function(...args.split(", ").filter(Boolean), body);
  }
  const said = [];
  const region = w.document.getElementById("bp-press-answer");
  new w.MutationObserver(() => said.push(region.textContent)).observe(region, { childList: true, characterData: true, subtree: true });
  const prior = [globalThis.window, globalThis.document, globalThis.location];
  globalThis.window = w;
  globalThis.document = w.document;
  globalThis.location = w.location;
  const leave = () => {
    hook._paDropPending(false);
    globalThis.window = prior[0];
    globalThis.document = prior[1];
    if (prior[2] === undefined) delete globalThis.location;
    else globalThis.location = prior[2];
    w.close();
  };
  const button = () => w.document.getElementById("unpublish");
  const press = () => {
    hook._paOnPress({ target: button(), defaultPrevented: false });
    button().setAttribute("data-phx-ref-src", "phx-probe");
  };
  // The server's reply: the ref drops, the row's status label changes (the
  // selection signature moves), and — when `flash` is given — the flash appears.
  const reply = ({ flash }) => {
    button().removeAttribute("data-phx-ref-src");
    w.document.querySelector("[aria-current]").setAttribute("aria-label", "Hello, draft");
    if (flash) w.document.getElementById("flash-slot").innerHTML = `<div class="flash flash-info">${flash}</div>`;
  };
  const wait = (ms) => new Promise((r) => w.setTimeout(r, ms));
  return { hook, said, region, leave, press, reply, wait };
}

test("an action answered with a server flash is announced with THAT sentence", async () => {
  const f = fixture();
  try {
    f.press();
    await f.wait(40);
    f.reply({ flash: "Unpublished" });
    await f.wait(250);
    assert.equal(f.said.includes("Unpublished"), true, `the server's sentence must be the answer. said: ${JSON.stringify(f.said)}`);
    assert.equal(
      f.said.some((s) => /Selected “Unpublish”/.test(s)),
      false,
      `an action button must never be announced as a selection. said: ${JSON.stringify(f.said)}`,
    );
  } finally {
    f.leave();
  }
});

test("a flash that was ALREADY showing before the press is not this press's answer", async () => {
  const f = fixture({ flashBefore: "Unpublished" });
  try {
    f.press();
    await f.wait(40);
    f.reply({ flash: "" });
    await f.wait(250);
    assert.equal(
      f.said.includes("Unpublished"),
      false,
      `a stale flash must not be quoted as this press's answer. said: ${JSON.stringify(f.said)}`,
    );
  } finally {
    f.leave();
  }
});

// CONTROL — with no flash, the evidence-bound words are unchanged: the selection
// signature moved, so the shipped "Selected …" word still speaks.
test("with no flash the shipped selection word still answers", async () => {
  const f = fixture();
  try {
    f.press();
    await f.wait(40);
    f.reply({ flash: "" });
    await f.wait(250);
    assert.equal(f.said.some((s) => /^Selected/.test(s)), true, `said: ${JSON.stringify(f.said)}`);
  } finally {
    f.leave();
  }
});
