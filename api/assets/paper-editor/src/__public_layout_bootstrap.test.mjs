import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const layout = readFileSync(
  new URL("../../../lib/barkpark_web/layouts/bulldocs.html.heex", import.meta.url),
  "utf8",
);
const match = layout.match(
  /<script[^>]*data-bp-paper-editor-loader[^>]*>([\s\S]*?)<\/script>/,
);
assert.ok(match, "public reader layout must ship its editor bootstrap");
const bootstrap = match[1];

const editorScripts = [
  "/assets/bp-paper-editor.bundle.js",
  "/assets/bp-media-picker.js",
  "/assets/bp-reference-picker.js",
  "/assets/bp-rich-text-editor.js",
  "/assets/bp-paper-editor-hooks.js",
];
const editorStyle = "/assets/bp-paper-editor-shell.css";

function installDefinitions(window, { elements = true } = {}) {
  window.BarkparkPaperEditorHooks = Object.fromEntries([
    "BarkparkPaperEditToggle", "BarkparkPaperEditor", "BarkparkPaperCanvas",
    "BarkparkFieldBlockBridge", "BarkparkFieldBridge",
    "BarkparkPaperSortable", "BarkparkPaperContextMenu", "BarkparkPaperAutoSize",
  ].map((name) => [name, { mounted() {} }]));
  if (elements) {
    for (const name of [
      "bp-paper-editor", "bp-paper-canvas", "bp-media-picker",
      "bp-reference-picker", "bp-rich-text-editor",
    ]) window.customElements.define(name, class extends window.HTMLElement {});
  }
}

function setup({ editable }) {
  const body = editable
    ? '<main><div id="paper-edit-bar"><button phx-hook="BarkparkPaperEditToggle">Edit</button></div></main>'
    : "<main><article>Readable paper</article></main>";
  const dom = new JSDOM(
    `<!doctype html><html><head><meta name="csrf-token" content="test-token"></head><body>${body}</body></html>`,
    {
      runScripts: "outside-only",
      url: "http://localhost/papers/bootstrap-test",
    },
  );
  const { window } = dom;
  const requested = [];
  const connections = [];
  const errors = [];
  const originalAppend = window.Element.prototype.appendChild;

  window.Element.prototype.appendChild = function appendChild(node) {
    if (node.tagName === "SCRIPT" || node.tagName === "LINK") requested.push(node);
    return originalAppend.call(this, node);
  };
  window.Phoenix = { Socket: class Socket {} };
  window.console.error = (...args) => errors.push(args);
  window.LiveView = {
    LiveSocket: class LiveSocket {
      constructor(_path, _socket, options) {
        this.options = options;
        connections.push(this);
      }

      connect() {
        this.connected = true;
      }
    },
  };

  window.eval(bootstrap);
  return { dom, window, requested, connections, errors };
}

function pathOf(node) {
  return new URL(node.src || node.href).pathname;
}

async function tick() {
  await new Promise((resolve) => setTimeout(resolve, 0));
}

{
  const { dom, requested, connections } = setup({ editable: false });
  await tick();

  assert.equal(requested.length, 0, "anonymous readers must request no editor assets");
  assert.equal(connections.length, 1, "anonymous readers still connect their one LiveSocket");
  assert.equal(connections[0].connected, true);
  assert.equal(
    typeof connections[0].options.dom?.onBeforeElUpdated,
    "function",
    "the LiveSocket always installs the Terminal-safe DOM update boundary",
  );
  dom.window.close();
}

{
  const { dom, window, requested, connections } = setup({ editable: false });
  await tick();

  const toggle = window.document.createElement("button");
  toggle.id = "paper-edit-toggle";
  toggle.setAttribute("phx-hook", "BarkparkPaperEditToggle");
  window.document.querySelector("main").prepend(toggle);

  const lazyToggle = connections[0].options.hooks.BarkparkPaperEditToggle;
  assert.equal(
    typeof lazyToggle?.mounted,
    "function",
    "the initial hook map must recognize an Edit toggle introduced by the connected mount",
  );
  let boundaryCalls = 0;
  connections[0].options.dom.onBeforeElUpdated({}, {});
  window.BarkparkPaperEditorBeforeElUpdated = () => { boundaryCalls += 1; };
  connections[0].options.dom.onBeforeElUpdated({}, {});
  assert.equal(
    boundaryCalls,
    1,
    "an already-connected reader socket late-binds the editor DOM boundary after lazy assets load",
  );

  const firstHook = { el: toggle };
  lazyToggle.mounted.call(firstHook);
  await tick();

  assert.deepEqual(requested.map(pathOf), [editorStyle, editorScripts[0]]);
  assert.equal(connections.length, 1, "connected-only authorization must keep the original socket");
  assert.equal(toggle.disabled, true, "Edit stays inert until every editor dependency is ready");

  toggle.disabled = false;
  toggle.removeAttribute("aria-busy");
  lazyToggle.updated.call(firstHook);
  assert.equal(toggle.disabled, true, "a pending LiveView patch cannot make Edit clickable");
  assert.equal(toggle.getAttribute("aria-busy"), "true");

  lazyToggle.destroyed.call(firstHook);
  toggle.remove();
  const replacement = window.document.createElement("button");
  replacement.id = "paper-edit-toggle-reconnected";
  replacement.setAttribute("phx-hook", "BarkparkPaperEditToggle");
  window.document.querySelector("main").prepend(replacement);
  const replacementHook = { el: replacement };
  lazyToggle.mounted.call(replacementHook);
  await tick();
  assert.equal(requested.length, 2, "a reconnect must share the in-flight asset load");

  for (let index = 0; index < editorScripts.length; index += 1) {
    const script = requested.find((node) => pathOf(node) === editorScripts[index]);
    assert.ok(script, `lazy loader must request ${editorScripts[index]} in order`);
    if (index === editorScripts.length - 1) {
      installDefinitions(window);
      window.BarkparkPaperEditorHooks.BarkparkPaperEditToggle.mounted = function mounted() {
        window.lazyToggleMounted = (window.lazyToggleMounted || 0) + 1;
      };
    }
    script.dispatchEvent(new window.Event("load"));
    await tick();
  }

  requested.find((node) => pathOf(node) === editorStyle).dispatchEvent(new window.Event("load"));
  await tick();

  assert.equal(window.lazyToggleMounted, 1, "the authorized toggle must activate after lazy load");
  assert.equal(toggle.disabled, true, "a destroyed hook must never mount stale editor handlers");
  assert.equal(replacement.disabled, false);
  lazyToggle.updated.call(replacementHook);
  assert.equal(
    replacement.disabled,
    false,
    "an installed real toggle with no updated callback must remain usable after a LiveView patch",
  );
  assert.equal(
    connections[0].options.hooks.BarkparkPaperCanvas,
    window.BarkparkPaperEditorHooks.BarkparkPaperCanvas,
    "later editor nodes must resolve against the loaded hook definitions",
  );
  dom.window.close();
}

{
  const { dom, window, requested, connections } = setup({ editable: false });
  await tick();

  const toggle = window.document.createElement("button");
  toggle.id = "paper-edit-toggle-lazy-failure";
  toggle.setAttribute("phx-hook", "BarkparkPaperEditToggle");
  window.document.querySelector("main").prepend(toggle);
  const lazyToggle = connections[0].options.hooks.BarkparkPaperEditToggle;
  const hook = { el: toggle };
  lazyToggle.mounted.call(hook);
  await tick();
  requested.find((node) => pathOf(node) === editorScripts[0]).dispatchEvent(new window.Event("error"));
  await tick();

  toggle.disabled = false;
  toggle.removeAttribute("aria-disabled");
  toggle.removeAttribute("title");
  lazyToggle.updated.call(hook);

  assert.equal(toggle.disabled, true, "a patch after lazy-load failure must keep Edit inert");
  assert.equal(toggle.getAttribute("aria-disabled"), "true");
  assert.match(toggle.title, /Reload the page/);
  dom.window.close();
}

{
  const { dom, window, requested, connections } = setup({ editable: true });
  await tick();

  assert.deepEqual(requested.map(pathOf), [editorStyle, editorScripts[0]]);
  assert.equal(connections.length, 0, "LiveSocket must wait for editor dependencies");

  for (let index = 0; index < editorScripts.length; index += 1) {
    const script = requested.find((node) => pathOf(node) === editorScripts[index]);
    assert.ok(script, `loader must request ${editorScripts[index]} in order`);
    assert.equal(script.async, false);
    if (index === editorScripts.length - 1) {
      installDefinitions(window);
    }
    script.dispatchEvent(new window.Event("load"));
    await tick();
  }

  assert.equal(connections.length, 0, "LiveSocket must also wait for editor CSS");
  requested.find((node) => pathOf(node) === editorStyle).dispatchEvent(new window.Event("load"));
  await tick();

  assert.equal(connections.length, 1);
  assert.equal(connections[0].connected, true);
  assert.equal(
    connections[0].options.hooks.BarkparkPaperCanvas,
    window.BarkparkPaperEditorHooks.BarkparkPaperCanvas,
    "editor hooks must be registered when the LiveSocket is constructed",
  );
  dom.window.close();
}

for (const failingAsset of [editorScripts[0], editorStyle]) {
  const { dom, window, requested, connections, errors } = setup({ editable: true });
  await tick();

  requested.find((node) => pathOf(node) === failingAsset).dispatchEvent(new window.Event("error"));
  await tick();

  const toggle = window.document.querySelector('[phx-hook="BarkparkPaperEditToggle"]');
  const alert = window.document.querySelector('[role="alert"]');
  assert.equal(connections.length, 0, "a partial editor must never bind the LiveSocket");
  assert.equal(toggle.disabled, true);
  assert.match(toggle.title, /Reload the page/);
  assert.match(alert.textContent, /still readable; reload to try editing again/);
  assert.equal(errors.length, 1);
  dom.window.close();
}

for (const missing of ["hooks", "elements"]) {
  const { dom, window, requested, connections } = setup({ editable: true });
  if (missing === "elements") installDefinitions(window, { elements: false });
  for (const asset of editorScripts) {
    await tick();
    requested.find((node) => pathOf(node) === asset).dispatchEvent(new window.Event("load"));
  }
  requested.find((node) => pathOf(node) === editorStyle).dispatchEvent(new window.Event("load"));
  await tick();
  assert.equal(connections.length, 0, "loaded files without editor definitions must not connect");
  assert.equal(window.document.querySelector("button").disabled, true);
  assert.ok(window.document.querySelector('[role="alert"]'));
  dom.window.close();
}

console.log("public layout editor bootstrap: 8 scenarios passed");
