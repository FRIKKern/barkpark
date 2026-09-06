import assert from "node:assert/strict";
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
const pressedChangedHelper = layout.match(/_paPressedChanged\(witness\) \{([\s\S]*?)\n      \},/);
assert.ok(
  pressedChangedHelper,
  "the watchdog must compare only the clicked control's aria-pressed state",
);
const pressedChanged = new Function("witness", pressedChangedHelper[1]);
const settleHelper = layout.match(/_paSettleWord\(p\) \{([\s\S]*?)\n      \},/);
assert.ok(settleHelper, "the watchdog settle classifier must remain present");
const settleWord = new Function("p", settleHelper[1]);
const hook = {
  el: document.getElementById("panes"),
  _paCurrentSig: () => "same-current",
  _paPressedWitness: pressedWitness,
  _paPressedChanged: pressedChanged,
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
  <main id="transition-panes">
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
  el: transitionDocument.getElementById("transition-panes"),
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
    else if (p.sawRef) this._paRelease("Done.");
  },
};
const priorWindow = globalThis.window;
const priorDocument = globalThis.document;
const priorTransitionLocation = globalThis.location;
globalThis.window = transitionDom.window;
globalThis.document = transitionDocument;
globalThis.location = transitionDom.window.location;
try {
  const beta = transitionDocument.querySelector('[data-test-id="editor-mode-beta"]');
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

dom.window.close();
console.log("press answer watchdog: native disclosure and fast mode-reply scenarios passed");
