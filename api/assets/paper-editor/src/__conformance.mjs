import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { MISSING, PACK, cli, diffShapes, shapeOf } from "../../../priv/portable_doc/conformance/conformance.mjs";
import { runToTiptap } from "./canvas/run-convert.js";

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
    const reader = document.createElement("pre");
    reader.className = "bp-codeblock";
    reader.setAttribute("data-bp-conformance-root", "");
    reader.setAttribute("style", "border:0;border-radius:var(--bp-codeblock-radius, 0);padding:var(--bp-codeblock-pad, 0.9rem 1.1rem);margin:var(--bp-codeblock-margin, 1.2rem 0);font-family:var(--paper-font-mono, ui-monospace,Menlo,monospace);font-size:var(--bp-codeblock-size, 0.9rem);line-height:var(--bp-codeblock-lh, 1.5);overflow-x:auto;white-space:pre");
    reader.textContent = root.querySelector("textarea")?.value || "";
    root = reader;
  } else if (type === "diagram") {
    root.classList.add("bp-diagram");
    root.style.removeProperty("background");
    root.style.border = "1px solid";
  } else if (type === "expandable") {
    const details = document.createElement("details");
    details.className = "bp-expandable";
    details.setAttribute("data-bp-conformance-root", "");
    const summary = document.createElement("summary");
    summary.textContent = root.querySelector(".bp-expandable__summary")?.value || "";
    const body = root.querySelector(".bp-expandable__body");
    details.append(summary, body || document.createElement("div"));
    root = details;
  } else if (type === "figure") {
    if (root.getAttribute("role") === "group") root.removeAttribute("role");
    root.style.overflowX = "auto";
    const caption = root.querySelector("figcaption");
    if (caption) {
      const input = caption.querySelector("input");
      caption.className = "bp-figcaption";
      caption.textContent = input?.value || "";
      caption.removeAttribute("style");
    }
  } else if (type === "steps") {
    for (const row of root.querySelectorAll(":scope > li")) {
      const head = row.querySelector(":scope > .bp-canvas-row__head");
      if (!head) continue;
      const title = document.createElement("div");
      title.className = "bp-steps__title";
      title.textContent = head.querySelector("input")?.value || "";
      head.replaceWith(title);
      const body = row.querySelector(":scope > .bp-steps__body");
      if (body?.childNodes.length === 1 && body.firstElementChild?.tagName === "P" && !body.textContent) {
        body.replaceChildren();
      }
    }
  } else if (type === "table") {
    root.querySelector(":scope > colgroup")?.remove();
    const tbody = root.querySelector(":scope > tbody");
    if (tbody) {
      const headerRows = [];
      while (tbody.firstElementChild?.querySelector(":scope > th:not([scope='row'])")) {
        headerRows.push(tbody.removeChild(tbody.firstElementChild));
      }
      if (headerRows.length) {
        const thead = document.createElement("thead");
        thead.append(...headerRows);
        root.insertBefore(thead, tbody);
      }
      for (const cell of root.querySelectorAll("th, td")) {
        if (cell.childNodes.length === 1 && cell.firstChild.nodeType === Node.TEXT_NODE) {
          const span = document.createElement("span");
          span.append(...cell.childNodes);
          cell.appendChild(span);
        }
      }
    }
    root.setAttribute("role", "presentation");
  } else if (type === "list") {
    for (const paragraph of root.querySelectorAll("li > p")) {
      const span = document.createElement("span");
      span.append(...paragraph.childNodes);
      paragraph.replaceWith(span);
    }
  } else if (type === "divider") {
    const divider = root.querySelector(".bp-section-divider");
    const mark = divider?.querySelector(".bp-section-divider__mark");
    divider?.setAttribute("style", "position:relative;text-align:center;margin:2.4rem 0;border-top:1px solid");
    mark?.setAttribute("style", "position:relative;top:-0.7rem;display:inline-block;padding:0 0.8rem;font-size:1.1rem");
  } else if (type === "paragraph") {
    for (const strong of root.querySelectorAll("strong")) {
      const span = document.createElement("span");
      span.style.fontWeight = "bold";
      span.append(...strong.childNodes);
      strong.replaceWith(span);
    }
    for (const link of root.querySelectorAll("a")) {
      link.removeAttribute("target");
      link.removeAttribute("rel");
    }
  } else if (type === "callout" && root.tagName === "DIV") {
    const title = root.querySelector(":scope > span > strong");
    const body = root.querySelector(":scope > .bp-callout__body");
    const inlineBody = document.createElement("span");
    if (body) inlineBody.append(...body.childNodes);
    title?.removeAttribute("style");
    root.replaceChildren(
      ...(title?.textContent ? [title, document.createTextNode(" ")] : []),
      inlineBody,
    );
  } else if (type === "card") {
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
      actionLink.textContent = actionIsland.textContent || "";
      actionLink.style.removeProperty("display");
    } else if (actionLink?.style.display === "none") {
      actionLink.remove();
    }
    actionIsland?.parentElement?.remove();
  } else if (type === "stage") {
    const fields = [
      ["paper-stage-kind", "bp-pnode__k"],
      ["paper-stage-title", "bp-pnode__t"],
      ["paper-stage-detail", "bp-pnode__d"],
      ["paper-stage-files", "bp-pnode__f"],
    ];
    const cells = fields.flatMap(([testId, className]) => {
      const value = root.querySelector(`[data-test-id='${testId}']`)?.value || "";
      if (!value) return [];
      const cell = document.createElement("div");
      cell.className = className;
      cell.textContent = value;
      return [cell];
    });
    root.className = root.classList.contains("bp-canvas-stage--src")
      ? "bp-pnode bp-pnode--src"
      : "bp-pnode";
    root.replaceChildren(...cells);
  } else if (type === "terminal") {
    const bar = root.querySelector(":scope > .bp-term__bar");
    const titleInput = bar?.querySelector(":scope > .bp-term__title");
    if (titleInput) {
      const title = document.createElement("span");
      title.className = "bp-term__title";
      title.textContent = titleInput.value || "";
      titleInput.replaceWith(title);
    }
    bar?.querySelector(":scope > .bp-canvas-term__live-toggle")?.remove();

    const footChrome = root.querySelector(":scope > .bp-canvas-term__foot-chrome");
    const footInput = footChrome?.querySelector(".bp-canvas-term__foot-input");
    if (footInput && footChrome) {
      const foot = document.createElement("div");
      foot.className = "bp-term__foot";
      foot.textContent = footInput.value || "";
      footChrome.replaceWith(foot);
    } else {
      footChrome?.remove();
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

await cli({ renderer: "editor-canvas", compare: "dom", judge });
window.close();
