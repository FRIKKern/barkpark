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
      <button id="classic-mode" phx-click="editor-set-mode" aria-pressed="true">Classic</button>
      <button data-test-id="editor-mode-beta" phx-click="editor-set-mode" aria-pressed="false">Beta</button>
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

dom.window.close();
console.log("press answer watchdog: native disclosure and fast mode-reply scenarios passed");
