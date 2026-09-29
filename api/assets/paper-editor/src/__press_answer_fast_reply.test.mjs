// THE FAST ANSWER IS NOT A LOST PRESS (task-bd7f6c26b182d9c0).
//
// The press answer's 16ms probe used to read "no `data-phx-ref-src` on the
// pressed control" as "LiveView never put this press on the wire" and announce
// "That press did not reach the server — press it again." The absence has two
// causes and the probe could see only one of them:
//
//   * the press was never pushed — no ref was ever stamped (the real lost press);
//   * the press was pushed AND ANSWERED inside 16ms — LiveView stamped the ref
//     synchronously in the click dispatch and removed it again when the reply
//     landed, before the probe looked.
//
// The second is an ordinary successful press on a fast link (a local server
// answers in low single-digit milliseconds). Unless the answer also moved one
// of the hook's success witnesses — URL, aria-current, aria-pressed — the
// shipped probe told the user a press that worked did not arrive. The Studio
// panel controls are exactly that shape: the document-panel toggle and the
// section toggles report their effect through `aria-expanded`, which is not a
// witness.
//
// Every body below is EXTRACTED from the layout, not restated, so this file
// measures the hook the browser runs. A hand-written mirror of `_paTick` is how
// the neighbouring transition fixture in __press_answer_watchdog.test.mjs can
// pass whatever the real one does; this file refuses that shortcut.
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

const LOST = "That press did not reach the server — press it again.";

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
  _paSettle: ["p", method("_paSettle", "p")],
  _paTick: ["p", method("_paTick", "p")],
  _paNativeDisclosureOnly: ["target, action", method("_paNativeDisclosureOnly", "target, action")],
  _paOnChromeAnchor: ["ev, t", method("_paOnChromeAnchor", "ev, t")],
  _paOnPress: ["ev", method("_paOnPress", "ev")],
};

// The production panel control, in its served shape: a phx-click button whose
// only observable success is `aria-expanded` (components.ex, the
// `bp-doc-sidebar-toggle` button), inside #studio-panes.
function fixture() {
  const dom = new JSDOM(
    `<main id="studio-panes">
       <aside>
         <button type="button" id="bp-doc-sidebar-toggle" phx-click="sidebar-toggle-panel"
           aria-expanded="false" title="Expand document panel"
           data-test-id="sidebar-toggle-panel">&gt;</button>
       </aside>
     </main>
     <p id="bp-press-answer"></p>`,
    { pretendToBeVisual: true, url: "http://localhost/w/default/studio/paper/probe" },
  );
  const w = dom.window;
  const hook = {
    el: w.document.getElementById("studio-panes"),
    // The shipped probe and poll; only the ceiling and fade are shortened so a
    // stuck press is visible inside the test instead of after 8 seconds.
    _PA_PROBE: 16,
    _PA_POLL: 100,
    _PA_WITNESS_GRACE: 750,
    _PA_CEILING: 1500,
    _PA_FADE: 1500,
    _paPending: null,
    _paPoll: 0,
    _paProbe: 0,
    _paCeil: 0,
    _paFadeT: 0,
    _paNavAway: false,
  };
  for (const [name, [args, body]] of Object.entries(bodies)) {
    hook[name] = new Function(...args.split(", ").filter(Boolean), body);
  }
  const said = [];
  const region = w.document.getElementById("bp-press-answer");
  new w.MutationObserver(() => said.push(region.textContent)).observe(region, {
    childList: true,
    characterData: true,
    subtree: true,
  });
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
  const toggle = () => w.document.getElementById("bp-doc-sidebar-toggle");
  // The press as the browser dispatches it: the hook's document listener runs
  // FIRST (bubble on document), then LiveView's window listener, which — when
  // it pushes — stamps the ref synchronously in the same dispatch.
  const press = ({ pushed }) => {
    const el = toggle();
    hook._paOnPress({ target: el, defaultPrevented: false });
    if (pushed) el.setAttribute("data-phx-ref-src", "phx-probe");
  };
  // The reply: LiveView drops the ref and patches the control's state.
  const reply = () => {
    const el = toggle();
    el.removeAttribute("data-phx-ref-src");
    el.setAttribute("aria-expanded", el.getAttribute("aria-expanded") === "true" ? "false" : "true");
  };
  const wait = (ms) => new Promise((r) => w.setTimeout(r, ms));
  return { w, hook, said, region, leave, press, reply, wait, toggle };
}

test("a press answered BEFORE the 16ms probe is not announced as lost", async () => {
  const f = fixture();
  try {
    f.press({ pushed: true });
    assert.match(f.region.textContent, /^Working on/,
      "the press must be armed and say its working word, or nothing below measures anything");
    // A local server answers well inside the probe window.
    await f.wait(4);
    f.reply();
    await f.wait(250);
    assert.equal(f.toggle().getAttribute("aria-expanded"), "true", "the fixture's effect must have landed");
    assert.equal(
      f.said.includes(LOST),
      false,
      `a press whose ref was stamped and dropped inside 16ms was ANSWERED; announcing it lost is false. said: ${JSON.stringify(f.said)}`,
    );
    assert.equal(f.hook._paPending, null, "the answered press must settle, not hang until the ceiling");
    assert.equal(f.toggle().hasAttribute("aria-busy"), false, "the settled row must not stay busy");
  } finally {
    f.leave();
  }
});

// CONTROL 1 — the lost-press line is the hook's reason to exist. A press that
// LiveView never pushed (no ref, ever) must still be told so; if this arm
// cannot fail, the arm above only proves the warning was deleted.
test("a press that was never pushed is still announced as lost", async () => {
  const f = fixture();
  try {
    f.press({ pushed: false });
    await f.wait(120);
    assert.equal(f.said.includes(LOST), true, `a press with no ref ever stamped must still warn. said: ${JSON.stringify(f.said)}`);
  } finally {
    f.leave();
  }
});

// CONTROL 2 — the ordinary slow path is untouched: the probe sees the ref,
// the poll sees it drop, the press settles without a warning.
test("a press answered after the probe settles exactly as before", async () => {
  const f = fixture();
  try {
    f.press({ pushed: true });
    await f.wait(40);
    assert.equal(f.hook._paPending !== null, true, "the press must still be in flight when the probe has looked");
    f.reply();
    await f.wait(250);
    assert.equal(f.said.includes(LOST), false, `a normally answered press must not warn. said: ${JSON.stringify(f.said)}`);
    assert.equal(f.hook._paPending, null, "the normally answered press must settle");
  } finally {
    f.leave();
  }
});

// CONTROL 3 — the discard branch. A second press while the first ref is still
// stamped is dropped by LiveView's bindClick and must keep saying so.
test("a press discarded behind an in-flight ref still says it was not sent", async () => {
  const f = fixture();
  try {
    f.press({ pushed: true });
    f.hook._paOnPress({ target: f.toggle(), defaultPrevented: false });
    await f.wait(1);
    assert.equal(
      f.said.includes("Still working on your last press — that one was not sent."),
      true,
      `a discarded second press must be named. said: ${JSON.stringify(f.said)}`,
    );
  } finally {
    f.leave();
  }
});
