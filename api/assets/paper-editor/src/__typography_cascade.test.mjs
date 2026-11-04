// The editor stylesheet loads before TipTap constructs an Editor. TipTap then
// injects its own bare `.ProseMirror` rule at the end of <head>, disabling
// ligatures. The PortableDoc reading surface deliberately restores normal
// ligatures plus old-style figures, so the restore must out-rank that real,
// late runtime rule without disabling TipTap's CSS injection.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "document", "DOMParser", "Element", "Event", "EventTarget",
  "HTMLElement", "KeyboardEvent", "MutationObserver", "Node", "NodeFilter",
  "Selection", "Text",
]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: String };
window.Range.prototype.getClientRects = () => [];
window.Range.prototype.getBoundingClientRect = () => ({ top: 0, left: 0, right: 0, bottom: 0 });

const editorStyle = document.createElement("style");
editorStyle.dataset.portableDocEditorStyle = "";
editorStyle.textContent = readFileSync(new URL("./styles.css", import.meta.url), "utf8");
document.head.appendChild(editorStyle);

// Import after installing the DOM: @tiptap/core decides whether CSS can be
// injected from the actual runtime globals.
const [{ Editor }, { default: StarterKit }] = await Promise.all([
  import("@tiptap/core"),
  import("@tiptap/starter-kit"),
]);

const root = document.createElement("div");
root.className = "bp-paper-editor-body";
document.body.appendChild(root);

const editor = new Editor({
  element: root,
  extensions: [StarterKit.configure({ trailingNode: false })],
  content: "<p>office 1234567890</p>",
});
const mount = root.querySelector(":scope > .ProseMirror");
assert.ok(mount, "TipTap did not mount a direct .ProseMirror child under the shared editor root");

function specificity(selector) {
  const ids = (selector.match(/#[\w-]+/g) || []).length;
  const classes = (selector.match(/\.[\w-]+|\[[^\]]+\]|:(?!:)[\w-]+(?:\([^)]*\))?/g) || []).length;
  const stripped = selector
    .replace(/#[\w-]+|\.[\w-]+|\[[^\]]+\]|::?[\w-]+(?:\([^)]*\))?/g, " ")
    .replace(/[>+~*]/g, " ");
  const types = (stripped.match(/\b[a-zA-Z][\w-]*\b/g) || []).length;
  return [ids, classes, types];
}

function compareSpecificity(a, b) {
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] - b[i];
  return 0;
}

// jsdom exposes the real CSSOM and selector matching but does not implement
// these two font properties in getComputedStyle. Resolve just their authored
// cascade from the live stylesheets so this test still covers the actual
// TipTap-injected rule, its late source order, and the mounted element.
function cascadedValue(element, property) {
  let winner = null;
  let order = 0;
  for (const sheet of document.styleSheets) {
    for (const rule of sheet.cssRules) {
      if (!rule.selectorText || !rule.style) continue;
      const value = rule.style.getPropertyValue(property);
      if (!value) continue;
      for (const selector of rule.selectorText.split(",")) {
        const trimmed = selector.trim();
        let matches = false;
        try { matches = element.matches(trimmed); } catch { continue; }
        if (!matches) continue;
        const candidate = {
          value: value.trim(),
          important: rule.style.getPropertyPriority(property) === "important",
          specificity: specificity(trimmed),
          order: order++,
          selector: trimmed,
        };
        if (
          !winner ||
          Number(candidate.important) > Number(winner.important) ||
          (candidate.important === winner.important && compareSpecificity(candidate.specificity, winner.specificity) > 0) ||
          (candidate.important === winner.important && compareSpecificity(candidate.specificity, winner.specificity) === 0 && candidate.order > winner.order)
        ) winner = candidate;
      }
    }
  }
  assert.ok(winner, `no matching declaration for ${property}`);
  return winner;
}

try {
  const tiptapStyle = document.head.querySelector("style[data-tiptap-style]");
  assert.ok(tiptapStyle, "TipTap's real runtime stylesheet was not injected");
  assert.ok(
    editorStyle.compareDocumentPosition(tiptapStyle) & Node.DOCUMENT_POSITION_FOLLOWING,
    "the regression requires TipTap's runtime stylesheet to load after styles.css",
  );
  assert.match(tiptapStyle.textContent, /font-variant-ligatures:\s*none/);
  assert.match(tiptapStyle.textContent, /font-feature-settings:\s*"liga" 0/);

  const ligatures = cascadedValue(mount, "font-variant-ligatures");
  const features = cascadedValue(mount, "font-feature-settings");
  assert.equal(
    ligatures.value,
    "normal",
    `late TipTap CSS won font-variant-ligatures via ${ligatures.selector}: ${ligatures.value}`,
  );
  assert.equal(
    features.value,
    '"kern", "liga", "onum"',
    `late TipTap CSS won font-feature-settings via ${features.selector}: ${features.value}`,
  );
} finally {
  editor.destroy();
  root.remove();
  dom.window.close();
}

console.log("typography cascade: scoped PortableDoc restore wins over real late TipTap CSS");
