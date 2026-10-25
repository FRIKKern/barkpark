// field-binding.js — contract 1.13.0: a BOUND field block's binding, as LiveView Beta's
// Properties row shows it. On a canvas whose host sets `data-field-caps` (its type's
// Expectation as JSON, `{fieldName: max | null}`), a field block that carries a
// `fieldName` shows the n/max badge (the bound blocks of that name / the layout's max;
// `n` alone when the layout sets no max) and an unbind × that makes it a free block:
// one patch-block {fieldName: null}, after which Barkpark's projection drops the
// orphaned content[fieldName]. Without the attribute nothing shows: D01's Classic
// inputs stay as they are.

import { t } from "../i18n.js";

function hostCaps(dom) {
  const host = dom.closest && dom.closest("bp-paper-canvas");
  const raw = host && host.getAttribute("data-field-caps");
  if (!raw) return null;
  try {
    const caps = JSON.parse(raw);
    return caps && typeof caps === "object" && !Array.isArray(caps) ? caps : null;
  } catch (_) {
    return null;
  }
}

function boundCount(doc, name) {
  let n = 0;
  doc.descendants((node) => {
    if (node.attrs && node.attrs.fieldName === name) n += 1;
    return true;
  });
  return n;
}

/** Mount the binding row on a field block's frame `dom`. Answers { paint(node), destroy() }. */
export function mountFieldBinding(dom, { editor, getPos }) {
  const el = document.createElement("span");
  el.className = "bp-canvas-field-binding";
  el.setAttribute("contenteditable", "false");
  el.hidden = true;
  const badge = document.createElement("span");
  badge.className = "bp-canvas-field-badge";
  const unbind = document.createElement("button");
  unbind.type = "button";
  unbind.className = "bp-canvas-field-unbind";
  unbind.textContent = "×";
  unbind.title = t("Unbind property");
  unbind.setAttribute("aria-label", t("Unbind property"));
  unbind.addEventListener("mousedown", (e) => e.preventDefault());
  el.append(badge, unbind);
  dom.appendChild(el);

  let current = null;
  const paint = (node) => {
    if (node) current = node;
    const name = current && current.attrs ? current.attrs.fieldName : null;
    const caps = hostCaps(dom);
    if (!name || !caps) {
      el.hidden = true;
      dom.classList.remove("bp-canvas-field--bound");
      return;
    }
    el.hidden = false;
    dom.classList.add("bp-canvas-field--bound");
    const count = boundCount(editor.state.doc, name);
    const max = Number.isInteger(caps[name]) ? caps[name] : null;
    badge.hidden = !(name in caps);
    badge.textContent = max != null ? `${count}/${max}` : String(count);
    badge.classList.toggle("is-at-cap", max != null && count >= max);
    unbind.hidden = !editor.isEditable;
  };
  unbind.addEventListener("click", (e) => {
    e.preventDefault();
    if (!editor.isEditable || typeof getPos !== "function") return;
    const pos = getPos();
    const cur = pos == null ? null : editor.state.doc.nodeAt(pos);
    if (!cur || !cur.attrs || !cur.attrs.fieldName) return;
    editor
      .chain()
      .command(({ tr }) => (tr.setNodeMarkup(pos, undefined, { ...cur.attrs, fieldName: null }), true))
      .run();
  });
  // Another block bound or unbound changes this one's count: repaint on every doc change.
  const onUpdate = () => paint(null);
  editor.on("update", onUpdate);
  // The frame is not in the canvas yet while the node view is built: paint once it is.
  queueMicrotask(() => paint(null));
  return {
    paint,
    destroy: () => editor.off("update", onUpdate),
  };
}
