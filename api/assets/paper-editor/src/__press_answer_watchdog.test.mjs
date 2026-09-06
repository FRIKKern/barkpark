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

const onPressStart = layout.indexOf("_paOnPress(ev) {");
const onPressEnd = layout.indexOf("\n      mounted()", onPressStart);
const onPress = layout.slice(onPressStart, onPressEnd);

assert.ok(onPressStart >= 0 && onPressEnd > onPressStart, "the press handler must remain present");
assert.ok(
  onPress.includes("if (this._paNativeDisclosureOnly(t, el)) return;"),
  "the press handler must apply the native-summary classification before arming",
);

dom.window.close();
console.log("press answer watchdog: 5 native disclosure/action scenarios passed");
