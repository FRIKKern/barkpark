import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { MISSING, PACK, cli, diffShapes, shapeOf } from "../../../priv/portable_doc/conformance/conformance.mjs";
import { runToTiptap } from "./canvas/run-convert.js";
import { projectMountedTableForReader } from "./canvas/table-node.js";

const { window } = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true, url: "http://localhost/" });
window.Range.prototype.getClientRects = () => [];
window.Range.prototype.getBoundingClientRect = () => ({ top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0 });
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"])
  globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: String };
window.BP_PAPER_EDITOR_NO_INJECT = true;
await import("./index.js");

const fragments = JSON.parse(readFileSync(join(PACK, "fragments.json"), "utf8"));
const PLUMBING_ATTRS = ["contenteditable", "draggable", "spellcheck", "tabindex", "data-bp-id", "data-bp-type", "data-field-type", "data-test-id", "data-bp-conformance-root", "data-bp-fleet-id"];
const CHROME = [
  ".ProseMirror-trailingBreak",
  ".ProseMirror-separator",
  ".ProseMirror-gapcursor",
  ".bp-paper-contextual-controls",
  ".bp-canvas-field-editor",
  ".bp-cols__c > .bp-resting-scaffold",
  ".bp-cols__c > .bp-scaffold-control",
  ".bp-canvas-tabs > .bp-canvas-rows__foot",
  ".bp-canvas-tabs .bp-tabs__panel > .bp-canvas-row__head",
  ".bp-canvas-section > .bp-canvas-section__controls",
  ".bp-canvas-section > [data-test-id=paper-section-title][hidden]",
].join(", ");

function paint(canvas, block) {
  let hostPainted = false;
  for (const hole of canvas.querySelectorAll("[data-bp-fleet-body]")) {
    const html = fragments[block.type];
    if (hole.dispatchEvent(new CustomEvent("bp-fleet-paint", { detail: { html, sourceBlock: block }, cancelable: true }))) {
      hole.innerHTML = html;
      hostPainted = true;
    }
  }
  return hostPainted;
}

function unwrapFleet(root) {
  const atoms = root.matches?.("[data-bp-fleet-id]") ? [root] : root.querySelectorAll("[data-bp-fleet-id]");
  for (const atom of atoms) {
    const body = atom.querySelector("[data-bp-fleet-body]");
    if (!body) continue;
    if (atom === root && atom.hasAttribute("data-bp-conformance-root")) body.replaceWith(...body.childNodes);
    else atom.replaceWith(...body.childNodes);
  }
}

function semanticClone(source, blockType) {
  let root = source.cloneNode(true);
  // Container blocks keep their children mounted as real node views. Normalize
  // each child's own resting contract before comparing the container, so a
  // section of cards inherits card parity instead of growing a second renderer.
  for (const child of [...root.querySelectorAll("[data-bp-conformance-root][data-bp-type]")]) {
    const childType = child.getAttribute("data-bp-type");
    child.replaceWith(semanticClone(child, childType));
  }
  const type = root.getAttribute?.("data-bp-type") || blockType;
  if (type === "code") {
    // The mounted node must already be the reader's semantic <pre>. The
    // comparator may peel away its editing islands, but it must never repair a
    // wrong tag/class/style into a passing reader node.
    if (root.matches("pre.bp-codeblock")) {
      const area = root.querySelector(":scope > textarea.bp-canvas-code-area");
      if (area) root.replaceChildren(document.createTextNode(area.value || ""));
    }
  } else if (type === "expandable") {
    // Keep the real details/summary/body nodes. `open` is edit-canvas state;
    // the summary input is the only editor island normalized to authored text.
    if (root.matches("details.bp-expandable")) {
      const summary = root.querySelector(":scope > summary");
      const body = root.querySelector(":scope > .bp-expandable__body");
      if (summary && body) {
        const input = summary.querySelector(":scope > input.bp-expandable__summary");
        if (input) summary.replaceChildren(document.createTextNode(input.value || ""));
        root.removeAttribute("open");
      }
    }
  } else if (type === "figure") {
    // The figure retains a real reader root/caption alongside its editor
    // controls. Project the node-view's documented group role only from its
    // exact mounted wrapper; never manufacture overflow, caption class or text.
    if (root.matches("figure.bp-canvas-readonly.bp-canvas-figure[role='group']")) {
      root.removeAttribute("role");
      const caption = root.querySelector(":scope > figcaption.bp-figcaption");
      if (caption) {
        caption.querySelector(":scope > input.bp-canvas-figure-caption-input")?.remove();
        const text = caption.querySelector(":scope > span[data-bp-figure-caption-text]");
        if (text) text.replaceWith(...text.childNodes);
      }
    }
  } else if (type === "steps") {
    const rows = root.matches("ol.bp-steps.bp-canvas-rows.bp-canvas-steps")
      ? [...root.children] : [];
    const exactSteps = rows.length > 0 && rows.every((row) => {
      const title = row.querySelector(":scope > .bp-steps__title[role='button']");
      const head = row.querySelector(":scope > .bp-canvas-row__head");
      const body = row.querySelector(":scope > .bp-steps__body");
      return row.matches("li.bp-steps__step.bp-canvas-row") && title && head && body &&
        head.querySelector(":scope > input.bp-canvas-row__title.bp-canvas-row__title-editor") &&
        head.querySelector(":scope > button.bp-canvas-row__remove");
    });
    if (exactSteps) {
      for (const row of rows) {
        const title = row.querySelector(":scope > .bp-steps__title");
        const head = row.querySelector(":scope > .bp-canvas-row__head");
        title.removeAttribute("role");
        head.remove();
        const body = row.querySelector(":scope > .bp-steps__body");
        if (body.childNodes.length === 1 && body.firstElementChild?.tagName === "P" && !body.textContent) {
          body.replaceChildren();
        }
      }
    }
  } else if (type === "table") {
    const projected = projectMountedTableForReader(root);
    if (projected) {
      projected.querySelector(":scope > colgroup")?.remove();
      root = projected;
    }
  } else if (type === "list") {
    // Portable lists intentionally retain ProseMirror's paragraph carrier for
    // caret/selection behavior. Project that documented equivalent only from
    // the exact mounted PM structure; malformed wrappers remain visible diffs.
    const list = root.matches("div.ProseMirror") && root.childElementCount === 1
      ? root.firstElementChild : null;
    const items = list?.matches("ul, ol") ? [...list.children] : [];
    const exactPmList = items.length > 0 && items.every((item) =>
      item.matches("li") && item.childElementCount === 1 &&
      item.firstElementChild?.matches("p:not([role])")
    );
    if (exactPmList) {
      for (const paragraph of list.querySelectorAll(":scope > li > p")) {
        const span = document.createElement("span");
        span.append(...paragraph.childNodes);
        paragraph.replaceWith(span);
      }
    }
  } else if (type === "paragraph") {
    // Native <strong> and safe-link attributes are useful PM semantics. Their
    // reader-equivalent projection is allowed only for the exact one-paragraph
    // mount, never as a generic repair of arbitrary host markup.
    const paragraph = root.matches("div.ProseMirror") && root.childElementCount === 1
      ? root.firstElementChild : null;
    if (paragraph?.matches("p:not([role])")) {
      for (const strong of paragraph.querySelectorAll("strong")) {
        const span = document.createElement("span");
        span.style.fontWeight = "bold";
        span.append(...strong.childNodes);
        strong.replaceWith(span);
      }
      for (const link of paragraph.querySelectorAll("a")) {
        link.removeAttribute("target");
        link.removeAttribute("rel");
      }
    }
  } else if (type === "callout" && root.tagName === "DIV") {
    const titleHost = root.querySelector(":scope > span");
    const title = titleHost?.querySelector(":scope > strong[role='textbox']");
    const body = root.querySelector(":scope > .bp-callout__body");
    const exactCallout = root.matches("div.bp-canvas-callout.bp-callout") &&
      titleHost && title && body && titleHost.nextSibling?.nodeType === Node.TEXT_NODE &&
      titleHost.nextSibling.nextSibling === body;
    if (exactCallout) {
      const inlineBody = document.createElement("span");
      inlineBody.append(...body.childNodes);
      title.removeAttribute("style");
      root.replaceChildren(
        ...(title.textContent ? [title, document.createTextNode(" ")] : []),
        inlineBody,
      );
    }
  } else if (type === "card") {
    if (!root.matches("div.bp-canvas-card.bp-card")) return root;
    root.querySelector(":scope > .bp-canvas-card__controls")?.remove();
    root.querySelector(":scope > .bp-canvas-card__media-paint")?.remove();
    root.querySelectorAll(":scope > bp-media-picker").forEach((el) => el.remove());

    const media = root.querySelector(":scope > img");
    if (media?.style.display === "none") media.remove();
    else media?.style.removeProperty("display");

    const heading = root.querySelector(":scope > h1, :scope > h2, :scope > h3");
    if (heading?.style.display === "none") heading.remove();
    else if (heading) {
      heading.style.removeProperty("display");
      heading.replaceChildren(document.createTextNode(heading.textContent || ""));
    }

    const body = root.querySelector(":scope > p");
    const hasAuthoredBody = body?.querySelector(
      ":scope > :not(.ProseMirror-trailingBreak, .ProseMirror-separator, .ProseMirror-gapcursor)",
    );
    if (body && !body.textContent && !hasAuthoredBody) body.remove();

    const actionLink = root.querySelector(":scope > a.bp-button");
    const actionIsland = root.querySelector(":scope > span > [data-test-id='paper-card-action-label']");
    if (actionLink && actionIsland?.style.display !== "none") {
      actionLink.style.removeProperty("display");
    } else if (actionLink?.style.display === "none") {
      actionLink.remove();
    }
    actionIsland?.parentElement?.remove();
  } else if (type === "stage") {
    // Stage reader cells must be mounted and kept in sync by the node view.
    // Remove only the edit controls; missing/wrong semantic cells remain a
    // visible conformance diff instead of being synthesized from input values.
    if (root.matches("div.bp-pnode")) {
      root.querySelectorAll(":scope > input[class^='bp-canvas-stage__'], :scope > .bp-canvas-stage__src-toggle")
        .forEach((el) => el.remove());
    }
  } else if (type === "terminal") {
    const bar = root.querySelector(":scope > .bp-term__bar");
    const title = bar?.querySelector(":scope > span.bp-term__title");
    if (title) bar.querySelector(":scope > input.bp-canvas-term__title-input")?.remove();
    bar?.querySelector(":scope > .bp-canvas-term__live-toggle")?.remove();

    const footChrome = root.querySelector(":scope > .bp-canvas-term__foot-chrome");
    const foot = footChrome?.querySelector(":scope > .bp-term__foot");
    if (footChrome && foot) {
      foot.querySelector(":scope > .bp-canvas-term__foot-input")?.remove();
      footChrome.replaceWith(foot);
    } else if (footChrome) {
      footChrome.remove();
    }
  }
  return root;
}

function strip(root) {
  root.querySelectorAll(CHROME).forEach((el) => el.remove());
  // The optional note lead's reader separator is a ProseMirror widget so DOM
  // parsing never mistakes it for authored body text. It is the one known host
  // wrapper normalized back to the reader's bare text node for shape comparison.
  for (const separator of root.querySelectorAll("span[data-bp-note-separator]"))
    separator.replaceWith(document.createTextNode(separator.textContent));
  for (const body of root.querySelectorAll(".bp-canvas-tabs .bp-tabs__panel > .bp-canvas-row__body"))
    body.replaceWith(...body.childNodes);
  const semanticRoot = root.nodeType === Node.ELEMENT_NODE && root.hasAttribute("data-bp-conformance-root");
  const elements = root.nodeType === Node.ELEMENT_NODE ? [root, ...root.querySelectorAll("*")] : root.querySelectorAll("*");
  for (const el of elements) {
    if (el.hasAttribute("data-bp-conformance-root")) {
      if (el.style.display === "none") el.style.removeProperty("display");
      if (el.getAttribute("style") === "") el.removeAttribute("style");
      el.removeAttribute("loading");
      el.removeAttribute("aria-hidden");
    }
    if (semanticRoot) {
      el.removeAttribute("data-bp-src");
      if (el.getAttribute("role") === "textbox") el.removeAttribute("role");
      el.removeAttribute("aria-label");
      el.removeAttribute("aria-multiline");
    }
    PLUMBING_ATTRS.forEach((a) => el.removeAttribute(a));
    for (const c of [...el.classList]) if (c.startsWith("ProseMirror") || c.startsWith("bp-canvas-")) el.classList.remove(c);
    if (el.getAttribute("class") === "") el.removeAttribute("class");
  }
}

function fragment(html) {
  const t = document.createElement("template");
  t.innerHTML = html;
  return t.content.childNodes;
}

async function judge(golden) {
  const { content } = runToTiptap([golden.input]);
  if (content.length > 0 && content.every((n) => n.type === "bpOpaque")) return MISSING;
  const block = { ...golden.input, id: "conformance" };
  const canvas = document.createElement("bp-paper-canvas");
  canvas.blocks = [block];
  document.body.append(canvas);
  try {
    await new Promise((r) => setTimeout(r, 0));
    const pm = canvas.querySelector(".ProseMirror");
    if (!pm) return [`canvas mounted no editor for ${golden.type}`];
    const hostPainted = paint(canvas, block);
    await new Promise((r) => setTimeout(r, 0));
    // A container may mount independently conformant children (for example a
    // section of cards). A typed child marker cannot represent a different
    // parent row; untyped preview roots remain valid for island node views.
    const semanticRoot = [...pm.querySelectorAll("[data-bp-conformance-root]")].find((el) => {
      const type = el.getAttribute("data-bp-type");
      return type == null || type === golden.type;
    });
    const normalizeText = ["divider", "list", "paragraph"].includes(golden.type);
    const root = semanticRoot ? semanticClone(semanticRoot, golden.type)
      : normalizeText ? semanticClone(pm, golden.type) : pm.cloneNode(true);
    unwrapFleet(root);
    strip(root);
    const actual = semanticRoot ? [root] : root.childNodes;
    const diff = diffShapes(shapeOf(actual), shapeOf(fragment(golden.expectedHtml)));
    return hostPainted ? { via: "host-paint", diff } : diff;
  } finally {
    canvas.remove();
  }
}

const stripProbe = document.createElement("div");
stripProbe.innerHTML = '<span class="x-bp-canvas-y xProseMirror bp-canvas-z ProseMirror-z"></span><span data-bp-note-separator> </span><span data-other style="display:none"> </span><a data-bp-conformance-root style="display:none"></a>';
strip(stripProbe);
if (stripProbe.firstChild.className !== "x-bp-canvas-y xProseMirror") throw new Error(`strip touched reader classes: ${stripProbe.firstChild.className}`);
if (stripProbe.childNodes[1].nodeType !== Node.TEXT_NODE || stripProbe.childNodes[1].nodeValue !== " ") throw new Error("strip did not unwrap the exact note separator");
if (stripProbe.childNodes[2].tagName !== "SPAN" || stripProbe.childNodes[2].style.display !== "none") throw new Error("strip changed unrelated host markup");
if (stripProbe.lastChild.tagName !== "A" || stripProbe.lastChild.hasAttribute("style")) throw new Error("strip kept semantic-root editor visibility");

const titleOnlySectionProbe = document.createElement("div");
titleOnlySectionProbe.setAttribute("data-bp-type", "section");
titleOnlySectionProbe.setAttribute("data-bp-conformance-root", "");
titleOnlySectionProbe.style.cssText = "display:flex;flex-direction:column";
titleOnlySectionProbe.innerHTML = '<div class="bp-section__cell"><div class="bp-canvas-card bp-card" data-bp-type="card" data-bp-conformance-root><div class="bp-canvas-card__controls"></div><img style="display:none"><button class="bp-canvas-card__media-paint"></button><h2><span data-test-id="paper-card-title">Alpha cell</span></h2><p><br class="ProseMirror-trailingBreak"></p><a class="bp-button" style="display:none"></a><span><span data-test-id="paper-card-action-label" style="display:none"></span></span></div></div>';
const normalizedTitleOnlySection = semanticClone(titleOnlySectionProbe, "section");
strip(normalizedTitleOnlySection);
if (normalizedTitleOnlySection.outerHTML !== '<div style="display: flex; flex-direction: column;"><div class="bp-section__cell"><div class="bp-card"><h2>Alpha cell</h2></div></div></div>') {
  throw new Error(`nested title-only card did not inherit card parity: ${normalizedTitleOnlySection.outerHTML}`);
}

// Planted mutations: a wrong mounted semantic structure must survive
// normalization and therefore fail shape comparison. These are deliberately
// the old blind-repair shapes for the four audited branches.
const semanticMutationProbes = [
  ["code", '<article class="definitely-not-the-reader-code-class" data-bp-type="code" data-bp-conformance-root><textarea class="bp-canvas-code-area">hello</textarea></article>', '<pre class="bp-codeblock">hello</pre>'],
  ["expandable", '<div class="bp-expandable" data-bp-type="expandable" data-bp-conformance-root><input class="bp-expandable__summary" value="Summary"><div class="bp-expandable__body"></div></div>', '<details class="bp-expandable"><summary>Summary</summary><div class="bp-expandable__body"></div></details>'],
  ["stage", '<div class="bp-canvas-stage" data-bp-type="stage" data-bp-conformance-root><input data-test-id="paper-stage-title" value="Review"></div>', '<div class="bp-pnode"><div class="bp-pnode__t">Review</div></div>'],
  ["terminal", '<div class="bp-term" data-bp-type="terminal" data-bp-conformance-root><div class="bp-term__bar"><input class="bp-term__title bp-canvas-term__title-input" value="tasks"></div><div class="bp-canvas-term__foot-chrome"><div class="bp-term__foot"><input class="bp-canvas-term__foot-input" value="quit"></div></div></div>', '<div class="bp-term"><div class="bp-term__bar"><span class="bp-term__title">tasks</span></div><div class="bp-term__foot">quit</div></div>'],
  ["list", '<section class="definitely-not-the-pm-list-wrapper"><ul><li><p>First point</p></li></ul></section>', '<ul><li><span>First point</span></li></ul>'],
  ["paragraph", '<section class="definitely-not-the-pm-paragraph-wrapper"><p>A <strong>bold</strong> <a href="https://example.com" target="_blank" rel="noopener noreferrer">link</a>.</p></section>', '<p>A <span style="font-weight:bold">bold</span> <a href="https://example.com">link</a>.</p>'],
  ["figure", '<figure class="definitely-not-the-reader-figure-class" role="group" data-bp-type="figure" data-bp-conformance-root><figcaption><input class="bp-canvas-figure-caption-input" value="Caption"></figcaption></figure>', '<figure style="overflow-x:auto"><figcaption class="bp-figcaption">Caption</figcaption></figure>'],
  ["steps", '<section class="definitely-not-the-reader-steps-class" data-bp-type="steps" data-bp-conformance-root><li><div class="bp-canvas-row__head"><input value="Claim"></div><div class="bp-steps__body"></div></li></section>', '<ol class="bp-steps"><li class="bp-steps__step"><div class="bp-steps__title">Claim</div><div class="bp-steps__body"></div></li></ol>'],
  ["table", '<table class="bp-table" role="grid" data-bp-type="table" data-bp-conformance-root><tbody><tr><th>Surface</th></tr></tbody></table>', '<table class="bp-table" role="presentation"><thead><tr><th><span>Surface</span></th></tr></thead><tbody></tbody></table>'],
  ["callout", '<div class="definitely-not-the-reader-callout-class" data-bp-type="callout" data-bp-conformance-root><span><strong role="textbox">Heads up</strong></span> <div class="bp-callout__body">Body</div></div>', '<div class="bp-callout"><strong>Heads up</strong> <span>Body</span></div>'],
  ["card", '<article class="definitely-not-the-reader-card-class" data-bp-type="card" data-bp-conformance-root><div class="bp-canvas-card__controls"></div><h2><span>Title</span></h2></article>', '<div class="bp-card"><h2>Title</h2></div>'],
  ["card", '<div class="bp-canvas-card bp-card" data-bp-type="card" data-bp-conformance-root><a class="bp-button" href="https://example.com" style="display:none">MUTATED SEMANTIC LINK</a><span><span data-test-id="paper-card-action-label">Open the board</span></span></div>', '<div class="bp-card"><a class="bp-button" href="https://example.com">Open the board</a></div>'],
  ["diagram", '<figure class="definitely-not-the-reader-diagram-class" data-bp-type="diagram" data-bp-conformance-root style="background:red"><pre class="mermaid">graph TD; A-->B</pre></figure>', '<figure class="bp-diagram" style="border:1px solid"><pre class="mermaid">graph TD; A-->B</pre></figure>'],
  ["divider", '<div class="bp-section-divider" data-bp-type="divider" data-bp-conformance-root><span class="bp-section-divider__mark">§</span></div>', '<div class="bp-section-divider" style="position:relative;text-align:center;margin:2.4rem 0;border-top:1px solid"><span class="bp-section-divider__mark" style="position:relative;top:-0.7rem;display:inline-block;padding:0 0.8rem;font-size:1.1rem">§</span></div>'],
];
for (const [type, html, expectedHtml] of semanticMutationProbes) {
  const probe = document.createElement("template");
  probe.innerHTML = html;
  const normalized = semanticClone(probe.content.firstElementChild, type);
  strip(normalized);
  const diff = diffShapes(shapeOf([normalized]), shapeOf(fragment(expectedHtml)));
  if (diff.length === 0) throw new Error(`${type} semantic mutation was repaired into a false pass: ${normalized.outerHTML}`);
}

await cli({ renderer: "editor-canvas", compare: "dom", judge });
window.close();
