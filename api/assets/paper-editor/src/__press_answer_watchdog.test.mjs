import assert from "node:assert/strict";
import { test } from "node:test";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const layout = readFileSync(
  new URL("../../../lib/barkpark_web/layouts/root.html.heex", import.meta.url),
  "utf8",
);

const helper = layout.match(
  /_paNativeDisclosureOnly\(target, action\) \{([\s\S]*?)\n      \},/,
);

assert.ok(helper, "the press watchdog must classify native disclosure-only summary clicks");

const nativeDisclosureOnly = new Function("target", "action", helper[1]);
const dom = new JSDOM(`
  <main id="panes" phx-click="select-block">
    <div role="group" aria-label="Editor mode">
      <button id="classic-mode" phx-click="editor-set-mode" aria-pressed="">Classic</button>
      <button data-test-id="editor-mode-beta" phx-click="editor-set-mode">Beta</button>
    </div>
    <button id="unrelated-toggle" aria-pressed="false">Unrelated</button>
    <button class="unstable-toggle" aria-pressed="false">Unstable</button>
    <details id="plain-details">
      <summary id="plain-summary"><span id="plain-label">Configure tabs</span></summary>
      <button id="body-action" phx-click="save-block">Save</button>
    </details>
    <details id="server-details">
      <summary id="server-summary" phx-click="toggle-server">Server toggle</summary>
    </details>
    <details id="descendant-details">
      <summary id="descendant-summary">
        <button id="summary-action" phx-click="inspect-block">Inspect</button>
      </summary>
    </details>
  </main>
`);

const { document } = dom.window;

function classify(id) {
  const target = document.getElementById(id);
  return nativeDisclosureOnly(target, target.closest("[phx-click]"));
}

assert.equal(
  classify("plain-summary"),
  true,
  "a plain summary must not inherit an ancestor phx-click and arm the server watchdog",
);
assert.equal(
  classify("plain-label"),
  true,
  "a clicked descendant of a plain summary is the same native disclosure-only toggle",
);
assert.equal(
  classify("server-summary"),
  false,
  "a summary with its own phx-click remains watchdog-protected",
);
assert.equal(
  classify("summary-action"),
  false,
  "an explicit server action inside a summary remains watchdog-protected",
);
assert.equal(
  classify("body-action"),
  false,
  "a real server button in the details body remains watchdog-protected",
);

const pressedWitnessHelper = layout.match(/_paPressedWitness\(el\) \{([\s\S]*?)\n      \},/);
assert.ok(
  pressedWitnessHelper,
  "the watchdog must capture the exact clicked control's aria-pressed state",
);
const pressedWitness = new Function("el", pressedWitnessHelper[1]);
// `root` — spd-w19-press-answer-outside-panes. The witness is computed over the
// press's OWN surface; the fixtures below pass it undefined, which falls back to
// `this.el` and is exactly the scope this harness measured before.
const pressedChangedHelper = layout.match(
  /_paPressedChanged\(witness, root\) \{([\s\S]*?)\n      \},/,
);
assert.ok(
  pressedChangedHelper,
  "the watchdog must compare only the clicked control's aria-pressed state",
);
const pressedChanged = new Function("witness", "root", pressedChangedHelper[1]);

// THE CHROME SCOPE. `_paOnPress` now asks which surface a press landed on, so
// the handler cannot be exercised at all without it — extracted from the layout
// rather than restated, so a change to the real resolver reaches this harness.
const scopeForHelper = layout.match(/_paScopeFor\(el\) \{([\s\S]*?)\n      \},/);
assert.ok(scopeForHelper, "the press answer must resolve the surface a press landed on");
const scopeFor = new Function("el", scopeForHelper[1]);

const chromeAnchorHelper = layout.match(/_paOnChromeAnchor\(ev, t\) \{([\s\S]*?)\n      \},/);
assert.ok(chromeAnchorHelper, "the tab strip is plain anchors; it needs a navigation shape");
const chromeAnchor = new Function("ev", "t", chromeAnchorHelper[1]);
const settleHelper = layout.match(/_paSettleWord\(p\) \{([\s\S]*?)\n      \},/);
assert.ok(settleHelper, "the watchdog settle classifier must remain present");
const settleWord = new Function("p", settleHelper[1]);

// THE SETTLE ITSELF, extracted rather than mirrored (task-ce909110bce2fddf).
// A hand-written copy of this branch in the transition fixture below is how
// `"Done."` outlived the source: the fixture said it whether or not the hook
// did. Everything that settles a press now runs the SHIPPED body.
const settleHookHelper = layout.match(/\n      _paSettle\(p\) \{([\s\S]*?)\n      \},/);
assert.ok(settleHookHelper, "the press watchdog must have a settle path");
const settle = new Function("p", settleHookHelper[1]);
const hook = {
  el: document.getElementById("panes"),
  _paCurrentSig: () => "same-current",
  _paPressedWitness: pressedWitness,
  _paPressedChanged: pressedChanged,
  _paScopeFor: scopeFor,
};
const betaMode = document.querySelector('[data-test-id="editor-mode-beta"]');
const betaPressed = hook._paPressedWitness(betaMode);
assert.ok(
  betaPressed,
  "an inactive exact-identity button in a segmented group must witness omitted-to-present aria-pressed",
);
assert.equal(
  hook._paPressedWitness(document.getElementById("body-action")),
  null,
  "a clicked control without aria-pressed must not invent a selection witness",
);

const previousLocation = globalThis.location;
globalThis.location = { href: "http://localhost/studio/forms" };
try {
  document.getElementById("unrelated-toggle").setAttribute("aria-pressed", "true");
  assert.equal(
    settleWord.call(hook, {
      url: globalThis.location.href,
      sig: "same-current",
      pressed: betaPressed,
      name: "Beta",
    }),
    null,
    "an unrelated aria-pressed change must not waive a failed Beta press",
  );

  betaMode.setAttribute("aria-pressed", "true");
  assert.equal(
    settleWord.call(hook, {
      url: globalThis.location.href,
      sig: "same-current",
      pressed: betaPressed,
      name: "Beta",
    }),
    "Selected “Beta”.",
    "a fast successful Beta mode reply must settle from its aria-pressed change, not false-alarm",
  );

  betaMode.outerHTML =
    '<button data-test-id="editor-mode-beta" phx-click="editor-set-mode" aria-pressed="true">Beta</button>';
  assert.equal(
    settleWord.call(hook, {
      url: globalThis.location.href,
      sig: "same-current",
      pressed: betaPressed,
      name: "Beta",
    }),
    "Selected “Beta”.",
    "a LiveView replacement with the same stable identity must retain the exact-control witness",
  );

  document.getElementById("panes").insertAdjacentHTML(
    "beforeend",
    '<button data-test-id="editor-mode-beta" aria-pressed="false">Duplicate Beta identity</button>',
  );
  assert.equal(
    settleWord.call(hook, {
      url: globalThis.location.href,
      sig: "same-current",
      pressed: betaPressed,
      name: "Beta",
    }),
    null,
    "an ambiguous replacement identity must fail closed",
  );
  document.querySelectorAll('[data-test-id="editor-mode-beta"]')[1].remove();

  const unstable = document.querySelector(".unstable-toggle");
  const unstablePressed = hook._paPressedWitness(unstable);
  unstable.remove();
  document.getElementById("panes").insertAdjacentHTML(
    "beforeend",
    '<button class="unstable-toggle" aria-pressed="true">Unstable</button>',
  );
  assert.equal(
    settleWord.call(hook, {
      url: globalThis.location.href,
      sig: "same-current",
      pressed: unstablePressed,
      name: "Unstable",
    }),
    null,
    "a replaced control without stable identity must fail closed",
  );
} finally {
  if (previousLocation === undefined) delete globalThis.location;
  else globalThis.location = previousLocation;
}

const onPressStart = layout.indexOf("_paOnPress(ev) {");
const onPressEnd = layout.indexOf("\n      mounted()", onPressStart);
const onPress = layout.slice(onPressStart, onPressEnd);

assert.ok(onPressStart >= 0 && onPressEnd > onPressStart, "the press handler must remain present");
assert.ok(
  onPress.includes("if (this._paNativeDisclosureOnly(t, el)) return;"),
  "the press handler must apply the native-summary classification before arming",
);
assert.ok(
  onPress.includes("pressed: this._paPressedWitness(el)"),
  "the pending press must capture the exact clicked control's pre-click aria-pressed state",
);

// Exercise the real Classic/Beta component shape and timing: LiveView can replace
// the whole segmented control after the 16ms ref probe, while the successful reply
// flips the stable Beta button only a little later. That transition must settle as
// selected instead of emitting a premature lost-press warning.
const transitionDom = new JSDOM(`
  <main id="studio-panes">
    <div class="editor-mode-toggle" role="group" aria-label="Editor mode" data-test-id="editor-mode-toggle">
      <button type="button" class="btn btn-sm btn-primary" phx-click="editor-set-mode" phx-value-mode="classic" aria-pressed="" data-test-id="editor-mode-classic">Classic</button>
      <button type="button" class="btn btn-sm btn-ghost" phx-click="editor-set-mode" phx-value-mode="beta" data-test-id="editor-mode-beta">Beta</button>
    </div>
    <p id="bp-press-answer" role="status"></p>
  </main>
`, { pretendToBeVisual: true, url: "http://localhost/studio/papers/mode-fixture" });
const transitionDocument = transitionDom.window.document;
const transitionMessages = [];
const onPressBody = onPress.slice(onPress.indexOf("{") + 1, onPress.lastIndexOf("\n      },"));
const runOnPress = new Function("ev", onPressBody);
const transitionHook = {
  el: transitionDocument.getElementById("studio-panes"),
  _PA_PROBE: 16,
  _PA_POLL: 20,
  _PA_CEILING: 500,
  _PA_FADE: 500,
  _PA_WITNESS_GRACE: 200,
  _paPending: null,
  _paPoll: 0,
  _paProbe: 0,
  _paCeil: 0,
  _paFadeT: 0,
  _paName(el) { return (el.textContent || "").trim() || null; },
  _paCurrentSig() { return "same-current"; },
  _paPressedWitness: pressedWitness,
  _paPressedChanged: pressedChanged,
  _paNativeDisclosureOnly: nativeDisclosureOnly,
  _paScopeFor: scopeFor,
  _paOnChromeAnchor: chromeAnchor,
  _paSettleWord: settleWord,
  _paSay(text) {
    transitionMessages.push(text);
    transitionDocument.getElementById("bp-press-answer").textContent = text;
  },
  _paRelease(text) {
    if (this._paPoll) transitionDom.window.clearInterval(this._paPoll);
    if (this._paProbe) transitionDom.window.clearTimeout(this._paProbe);
    if (this._paCeil) transitionDom.window.clearTimeout(this._paCeil);
    this._paPoll = this._paProbe = this._paCeil = 0;
    this._paPending = null;
    this._paSay(text || "");
  },
  _paTick(p) {
    if (this._paPending !== p) return;
    if (transitionDocument.contains(p.el) && p.el.hasAttribute("data-phx-ref-src")) {
      p.sawRef = true;
      return;
    }
    const word = this._paSettleWord(p);
    if (word) this._paRelease(word);
    else if (p.sawRef) this._paSettle(p);
  },
  _paSettle: settle,
};
const priorWindow = globalThis.window;
const priorDocument = globalThis.document;
const priorTransitionLocation = globalThis.location;
globalThis.window = transitionDom.window;
globalThis.document = transitionDocument;
globalThis.location = transitionDom.window.location;
try {
  const beta = transitionDocument.querySelector('[data-test-id="editor-mode-beta"]');
  // PRECONDITION, not an afterthought: `_paOnPress` drops any press whose
  // surface does not resolve, so without this the whole transition leg below
  // would pass by never arming at all.
  assert.ok(
    transitionHook._paScopeFor(beta),
    "the fixture control must sit on a surface the press answer covers, or every assertion below is vacuous",
  );
  runOnPress.call(transitionHook, { target: beta });
  transitionDom.window.setTimeout(() => {
    transitionDocument.querySelector('[data-test-id="editor-mode-toggle"]').outerHTML = `
      <div class="editor-mode-toggle" role="group" aria-label="Editor mode" data-test-id="editor-mode-toggle">
        <button type="button" class="btn btn-sm btn-ghost" phx-click="editor-set-mode" phx-value-mode="classic" data-test-id="editor-mode-classic">Classic</button>
        <button type="button" class="btn btn-sm btn-primary" phx-click="editor-set-mode" phx-value-mode="beta" aria-pressed="" data-test-id="editor-mode-beta">Beta</button>
      </div>`;
  }, 40);
  await new Promise((resolve) => transitionDom.window.setTimeout(resolve, 120));
  assert.equal(
    transitionMessages.includes("That press did not reach the server — press it again."),
    false,
    "a successful delayed Classic-to-Beta rerender must not trigger the lost-press warning",
  );
  assert.equal(transitionMessages.includes("Selected “Beta”."), true);

  transitionMessages.length = 0;
  const classic = transitionDocument.querySelector('[data-test-id="editor-mode-classic"]');
  runOnPress.call(transitionHook, { target: classic });
  await new Promise((resolve) => transitionDom.window.setTimeout(resolve, 230));
  assert.equal(
    transitionMessages.includes("That press did not reach the server — press it again."),
    true,
    "a genuinely unanswered stable mode press must still fail after the bounded witness grace",
  );
} finally {
  transitionHook._paRelease("");
  globalThis.window = priorWindow;
  globalThis.document = priorDocument;
  if (priorTransitionLocation === undefined) delete globalThis.location;
  else globalThis.location = priorTransitionLocation;
  transitionDom.window.close();
}

// ── THE CHROME SURFACES (spd-w19-press-answer-outside-panes) ────────────────
// The studio-tab strip carries NO phx-click: every `.studio-tab` is a plain
// `<a href>`, so `_paOnPress` finds no binding and hands the press to the
// navigation shape. Measured on the deployed desk, the shipped hook left the
// region empty on exactly this press.
const chromeDom = new JSDOM(`
  <div class="studio-bar">
    <div class="studio-bar-tabs">
      <a id="tab-here" href="/w/default/studio" aria-current="page" aria-label="Structure"></a>
      <a id="tab-away" href="/w/default/studio/media" aria-label="Media"></a>
      <a id="tab-blank" href="/elsewhere" target="_blank" aria-label="Elsewhere"></a>
    </div>
    <button id="bar-action" phx-click="shares-open" aria-label="Network shares"></button>
  </div>
  <main id="studio-panes"><button id="row" phx-click="select" aria-label="Row"></button></main>
  <div id="outside"><a id="stray" href="/somewhere" aria-label="Stray"></a></div>
  <p id="bp-press-answer"></p>
`, { pretendToBeVisual: true, url: "http://localhost/w/default/studio" });
const chromeDocument = chromeDom.window.document;
const said = [];
const chromeHook = {
  el: chromeDocument.getElementById("studio-panes"),
  _PA_FADE: 500,
  _paPending: null,
  _paPoll: 0, _paProbe: 0, _paCeil: 0, _paFadeT: 0,
  _paScopeFor: scopeFor,
  _paOnChromeAnchor: chromeAnchor,
  _paName(el) { return el.getAttribute("aria-label") || null; },
  _paSay(text) { said.push(text); },
  _paRelease(text) { this._paPending = null; this._paSay(text || ""); },
};
const priorChromeWindow = globalThis.window;
const priorChromeDocument = globalThis.document;
const priorChromeLocation = globalThis.location;
globalThis.window = chromeDom.window;
globalThis.document = chromeDocument;
globalThis.location = chromeDom.window.location;
try {
  const press = (id) => {
    said.length = 0;
    const t = chromeDocument.getElementById(id);
    chromeHook._paOnChromeAnchor.call(chromeHook, { defaultPrevented: false, target: t }, t);
    return said.slice();
  };

  // THE SCOPE, both directions — the claim is symmetric, so both arms run.
  assert.ok(chromeHook._paScopeFor(chromeDocument.getElementById("bar-action")),
    "a top-bar control must resolve to the chrome surface");
  assert.ok(chromeHook._paScopeFor(chromeDocument.getElementById("tab-away")),
    "a studio-tab strip control must resolve to the chrome surface");
  assert.ok(chromeHook._paScopeFor(chromeDocument.getElementById("row")),
    "a pane row must still resolve, exactly as before");
  assert.equal(chromeHook._paScopeFor(chromeDocument.getElementById("stray")), null,
    "a surface this hook does not answer for must resolve to null and be left alone");

  assert.deepEqual(press("tab-away"), ["Opening “Media”…"],
    "a tab-strip press must say a named state, not the nothing the shipped build says");

  // THE HONESTY RULE. The active tab's href IS this page: it answers and
  // changes nothing, so it CLEARS the region and never says "Opening" — and,
  // since task-ce909110bce2fddf, never says "Done." either. "Done." was
  // defended as neutral; it is the word an interface uses for a COMPLETED
  // action, so it read as a success on a press that moved nothing.
  assert.deepEqual(press("tab-here"), [""],
    "the active tab answers and changes nothing — naming it Opening, or Done., announces a move that did not happen");

  // A CLEAR IS NOT THE SAME AS NEVER SPEAKING, and the difference is
  // load-bearing: this branch must wipe whatever the previous press left on
  // screen, where `tab-blank` below must not touch the region at all.
  assert.notDeepEqual(press("tab-here"), [],
    "the active tab must RELEASE (clearing any in-flight word), not silently return");

  // CONTROL — a check that cannot say no is not a check.
  assert.notDeepEqual(press("tab-here"), press("tab-away"),
    "the neutral clear and the named opening must be distinguishable, or neither assertion above measures anything");

  assert.deepEqual(press("tab-blank"), [],
    "a new-tab anchor changes nothing on THIS page and must not be announced");
  assert.deepEqual(press("stray"), [],
    "an anchor outside both surfaces must stay silent");

  said.length = 0;
  const away = chromeDocument.getElementById("tab-away");
  chromeHook._paOnChromeAnchor.call(chromeHook, { defaultPrevented: true, target: away }, away);
  assert.deepEqual(said, [],
    "a press something else already claimed must not be announced as a navigation");
} finally {
  globalThis.window = priorChromeWindow;
  globalThis.document = priorChromeDocument;
  if (priorChromeLocation === undefined) delete globalThis.location;
  else globalThis.location = priorChromeLocation;
  chromeDom.window.close();
}

dom.window.close();
console.log("press answer watchdog: native disclosure, fast mode-reply, and chrome-surface scenarios passed");

// ── THE TEARDOWN (spd-w19 follow-up, task-3f18da89b058b886) ────────────────
// THE ARMS ABOVE CANNOT SEE THIS DEFECT AND WERE NEVER GOING TO. They call
// `_paOnChromeAnchor` directly on a synthetic hook that has no `destroyed()`,
// a `_paSay` that pushes into an array instead of writing the DOM, and a
// `_paRelease` stub that arms no fade timer. Every assertion in them is true
// and none of them runs the path the press actually takes: on the deployed
// desk the SAME synchronous click dispatch ran the anchor branch at dt=0.4ms
// and `LiveSocket.destroyAllViews -> View.destroy -> destroyHook ->
// destroyed() -> _paRelease("")` at dt=0.9ms, and the first rAF read EMPTY.
//
// So these arms run the REAL bodies — `_paSay`, `_paRelease`,
// `_paDropPending`, the `pagehide` closure and the `destroyed()` body, all
// extracted from the layout — against a REAL region element, in the real
// order. They are not a restatement of the fix: run this file against the
// layout as it shipped and arms 1 and 2 fail on the empty region.
const teardownBody = layout.match(
  /window\.addEventListener\("pagehide", this\._paOnPageHide\);\n      \},\n      destroyed\(\) \{([\s\S]*?)\n      \}/,
);
assert.ok(
  teardownBody,
  "the press-answer hook's own destroyed() must be locatable, or this harness is measuring some other hook",
);
// DELIBERATELY SHAPE-AGNOSTIC. This harness runs whatever the layout's own
// teardown does — one line or twenty — so its verdict is about BEHAVIOUR and
// not about whether a particular helper name is present. Point it at the
// layout as it shipped and it still runs; arms 1 and 2 then fail on an empty
// region, which is the defect, rather than on a missing symbol.
const pageHideSource = layout.match(/this\._paOnPageHide = ([\s\S]*?);\n        window/);
assert.ok(pageHideSource, "the pagehide handler must be locatable");
const regionHelper = layout.match(/_paRegion\(\) \{(.*?)\},\n/);
assert.ok(regionHelper, "the live region accessor must be locatable");
const sayHelper = layout.match(/_paSay\(text\) \{([\s\S]*?)\n      \},/);
assert.ok(sayHelper, "the live region writer must be locatable");
// Optional by design (see above): absent from the shipped layout.
const dropHelper = layout.match(/_paDropPending\(keepFade\) \{([\s\S]*?)\n      \},/);
const releaseHelper = layout.match(/_paRelease\(text\) \{([\s\S]*?)\n      \},/);
assert.ok(releaseHelper, "the single release path must be locatable");
// Optional by design: absent from the shipped layout.
const keepHelper = layout.match(/_paKeepWordThroughTeardown\(\) \{([\s\S]*?)\n      \},/);
const nameHelper = layout.match(/_paName\(el\) \{([\s\S]*?)\n      \},/);
assert.ok(nameHelper, "the accessible-name helper must be locatable");

// A fresh document + a hook wired from the real bodies. `fade` is the only
// thing shortened: the shipped 6000ms would make arm 4 a six-second test.
function teardownFixture(fade) {
  const tdom = new JSDOM(
    `<div class="studio-bar"><div class="studio-bar-tabs">` +
      `<a id="tab-away" href="/w/default/studio/media" aria-label="Media"></a>` +
      `</div></div>` +
      `<main id="studio-panes"><button id="row" phx-click="select" aria-label="Row"></button></main>` +
      `<p id="bp-press-answer"></p>`,
    { pretendToBeVisual: true, url: "http://localhost/w/default/studio" },
  );
  const hook = {
    el: tdom.window.document.getElementById("studio-panes"),
    _PA_FADE: fade,
    _raf: 0,
    _onResize() {},
    _paPending: null,
    _paPoll: 0,
    _paProbe: 0,
    _paCeil: 0,
    _paFadeT: 0,
    _paNavAway: false,
    _paScopeFor: scopeFor,
    _paOnChromeAnchor: chromeAnchor,
    _paName: new Function("el", nameHelper[1]),
    _paRegion: new Function(regionHelper[1]),
    _paSay: new Function("text", sayHelper[1]),
    _paRelease: new Function("text", releaseHelper[1]),
  };
  if (dropHelper) hook._paDropPending = new Function("keepFade", dropHelper[1]);
  if (keepHelper) hook._paKeepWordThroughTeardown = new Function(keepHelper[1]);
  hook._paOnClick = () => {};
  hook._paOnPageHide = new Function("return (" + pageHideSource[1] + ")").call(hook);
  const destroyed = new Function(teardownBody[1]);
  const region = () => tdom.window.document.getElementById("bp-press-answer").textContent;
  const enter = () => {
    const prior = [globalThis.window, globalThis.document, globalThis.location];
    globalThis.window = tdom.window;
    globalThis.document = tdom.window.document;
    globalThis.location = tdom.window.location;
    return () => {
      globalThis.window = prior[0];
      globalThis.document = prior[1];
      if (prior[2] === undefined) delete globalThis.location;
      else globalThis.location = prior[2];
    };
  };
  const pressTabAway = () => {
    const a = tdom.window.document.getElementById("tab-away");
    hook._paOnChromeAnchor.call(hook, { defaultPrevented: false, target: a }, a);
  };
  return { tdom, hook, destroyed, region, enter, pressTabAway };
}

test("a tab-strip press keeps its word through the teardown that same click causes", () => {
  const f = teardownFixture(4000);
  const leave = f.enter();
  try {
    f.pressTabAway();
    assert.equal(
      f.region(),
      "Opening “Media”…",
      "the anchor branch must put the word IN THE REGION, not merely call _paSay",
    );
    // THE STACK, in the order the deployed build ran it, inside one dispatch.
    f.destroyed.call(f.hook);
    assert.equal(
      f.region(),
      "Opening “Media”…",
      "destroyed() wiped the navigation word before a frame could be painted — the shipped defect",
    );
    assert.equal(f.hook._paPending, null, "the teardown must still drop the pending press");
    assert.ok(f.hook._paFadeT, "the fade timer must survive, or the word is stranded forever");
  } finally {
    leave();
    f.tdom.window.close();
  }
});

test("pagehide does not wipe the word either — it fires while the old document is still on screen", () => {
  const f = teardownFixture(4000);
  const leave = f.enter();
  try {
    f.pressTabAway();
    f.hook._paOnPageHide();
    assert.equal(
      f.region(),
      "Opening “Media”…",
      "pagehide runs before the incoming document paints; clearing there loses the word just as destroyed() did",
    );
  } finally {
    leave();
    f.tdom.window.close();
  }
});

// THE CONTROL. "Never clear on teardown" is not the fix and would strand a
// word on a desk that is still here. A teardown with no navigation in flight —
// a pane re-render dropping #studio-panes — must clear exactly as before. If
// this arm cannot fail, the two above only prove the clear was deleted.
test("a teardown with NO navigation in flight still clears the region", () => {
  const f = teardownFixture(4000);
  const leave = f.enter();
  try {
    f.hook._paRelease("Selected “Row”.");
    assert.equal(f.region(), "Selected “Row”.", "the fixture must start from a word actually on screen");
    assert.ok(!f.hook._paNavAway, "no anchor press happened, so nothing is navigating");
    f.destroyed.call(f.hook);
    assert.equal(
      f.region(),
      "",
      "a hook that is going away with the page still here must take its own word with it",
    );
  } finally {
    leave();
    f.tdom.window.close();
  }
});

// THE BOUND. The kept word is not permanent: the fade the anchor branch armed
// is what finally clears it, and it outlives the hook on purpose.
test("the surviving fade clears the kept word, so nothing is stranded", async () => {
  const f = teardownFixture(60);
  const leave = f.enter();
  try {
    f.pressTabAway();
    f.destroyed.call(f.hook);
    assert.equal(f.region(), "Opening “Media”…");
    await new Promise((r) => f.tdom.window.setTimeout(r, 160));
    assert.equal(
      f.region(),
      "",
      "the fade timer must survive the teardown AND still fire, or a kept word is a stranded one",
    );
  } finally {
    leave();
    f.tdom.window.close();
  }
});


// ── THE SETTLE WORD FOR A PRESS THE SERVER REFUSED (task-ce909110bce2fddf) ──
// `_paSettle` runs when the round trip finished and NEITHER witness moved: no
// URL patch, no `aria-current` move, no `aria-pressed` move. Every Studio
// handler that answers a `phx-click` with an unchanged socket lands here —
// `Scope.switch_workspace/2` on a workspace the principal cannot reach, a
// `publish` with no document open — and it used to be told "Done.".
//
// That is not neutral to the person hearing it. A user who saw nothing presses
// again; a user told "Done." walks away from a press that never ran. The word
// belongs to the server, which knows the reason and flashes it.
//
// This runs the SHIPPED `_paSettle` body, so it reds on a revert rather than
// on a comment.
function settleFixture(currentSig, pressedMoved) {
  const sdom = new JSDOM("<p id=\"bp-press-answer\"></p>", {
    url: "http://localhost/w/default/p/blog/d/production/studio",
  });
  const words = [];
  const hook = {
    _PA_FADE: 500,
    _paPending: null,
    _paFadeT: 0,
    _paSettleWord: settleWord,
    _paSettle: settle,
    _paCurrentSig() { return currentSig; },
    _paPressedChanged() { return pressedMoved; },
    _paSay(t) { words.push(t); },
    _paRelease(t) { this._paPending = null; this._paSay(t || ""); },
  };
  const prior = { w: globalThis.window, d: globalThis.document, l: globalThis.location };
  globalThis.window = sdom.window;
  globalThis.document = sdom.window.document;
  globalThis.location = sdom.window.location;
  const press = {
    el: sdom.window.document.getElementById("bp-press-answer"),
    root: sdom.window.document.getElementById("bp-press-answer"),
    name: "Publish",
    url: sdom.window.location.href,
    sig: "sig-at-press",
    pressed: null,
  };
  return {
    words,
    run() { hook._paSettle(press); return words.slice(); },
    done() {
      globalThis.window = prior.w;
      globalThis.document = prior.d;
      if (prior.l === undefined) delete globalThis.location; else globalThis.location = prior.l;
      sdom.window.close();
    },
  };
}

test("a settled press with NO witness says nothing, rather than claiming it is Done", () => {
  // The refusal shape: the URL is the press's own URL and the aria-current
  // signature is the one taken at press time, so `_paSettleWord` is null and
  // the fallback is the whole answer.
  const f = settleFixture("sig-at-press", false);
  try {
    const said = f.run();

    assert.deepEqual(said, [""],
      "the region answers a REFUSED press with a word the hook has no evidence for");

    for (const w of ["Done", "Saved", "Complete", "Finished", "Success", "Published"]) {
      assert.ok(!said.join(" ").includes(w),
        `the region announced the completion word "${w}" for a press that changed nothing`);
    }
  } finally {
    f.done();
  }
});

test("CONTROL — a settled press WITH a witness still gets its word", () => {
  // Same body, same fixture, one thing different: the aria-current signature
  // moved. If this arm did not speak, the assertion above would be passing on
  // a settle path that says nothing to anybody.
  const f = settleFixture("sig-after-the-press", false);
  try {
    assert.deepEqual(f.run(), ["Selected “Publish”."],
      "the settle path went silent for a press that DID move a witness — the fix was over-corrected");
  } finally {
    f.done();
  }
});
