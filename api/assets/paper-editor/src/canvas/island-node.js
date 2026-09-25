// island-node.js — the "data + island" atoms: equation, footnote, toc, video.
//
// Each of these blocks is a small bag of author DATA the reader renders on its own
// (compose.ex: Math.equation_html, footnote_row_html, the toc outline, Figures.video_html)
// and that no continuous-canvas node could hold as prose. They mounted as bpOpaque
// chips. One factory makes each a self-painting ATOM (the image/diagram shape): the
// editable keys ride typed attrs, every other key rides `bpRest` verbatim, a preview
// paints from the attrs in the reader's own classes, and a fields island (inputs,
// textareas, checkboxes — never a contentEditable, see expandable-node.js) writes back
// through setNodeMarkup so run-convert emits one patch-block of the editable keys.
//
//   equation { tex, display? }                        → <div class="bp-equation">
//   footnote { notes:[{id?, text}] }                  → <ol class="bp-footnote">
//   toc      { items:[{text, level, anchor}], depth?, numbered? }  → <nav class="bp-toc">
//   video    { src, poster?, loop?, captions? }       → <figure><video controls>
//
// Field kinds: "text" (one line), "textarea" (many), "bool" (checkbox), "notes" (one
// note per line ⇄ [{id?, text}], ids kept by position), "outline" (one entry per line,
// two spaces of indent per level, `text | anchor` ⇄ [{text, level, anchor}]).
//
// DOM-aware node views; the schema objects load in plain Node.

import { Node, mergeAttributes } from "@tiptap/core";
import { DEBOUNCE_MS, configControlHidden } from "../contract.js";
import { wireAtomAccessibility } from "./embed-node.js";

// ── field codecs ──────────────────────────────────────────────────────────────

export function notesToText(notes) {
  return (Array.isArray(notes) ? notes : [])
    .map((n) => (n && typeof n === "object" ? String(n.text == null ? "" : n.text) : String(n == null ? "" : n)))
    .join("\n");
}

export function textToNotes(text, prev) {
  const before = Array.isArray(prev) ? prev : [];
  const lines = String(text || "").split(/\r?\n/).filter((l) => l.trim() !== "");
  return lines.map((line, i) => {
    const old = before[i] && typeof before[i] === "object" ? before[i] : null;
    return old ? { ...old, text: line } : { text: line };
  });
}

export function outlineToText(items) {
  return (Array.isArray(items) ? items : [])
    .filter((it) => it && typeof it === "object")
    .map((it) => {
      const level = Math.max(1, Math.min(6, parseInt(it.level, 10) || 1));
      const text = String(it.text == null ? "" : it.text);
      const anchor = it.anchor == null || it.anchor === "" ? "" : " | " + String(it.anchor);
      return "  ".repeat(level - 1) + text + anchor;
    })
    .join("\n");
}

export function textToOutline(text) {
  return String(text || "")
    .split(/\r?\n/)
    .filter((l) => l.trim() !== "")
    .map((line) => {
      const indent = /^( *)/.exec(line)[1].length;
      const level = Math.max(1, Math.min(6, Math.floor(indent / 2) + 1));
      const body = line.trim();
      const bar = body.lastIndexOf(" | ");
      const item = { text: bar >= 0 ? body.slice(0, bar).trim() : body, level };
      if (bar >= 0 && body.slice(bar + 3).trim() !== "") item.anchor = body.slice(bar + 3).trim();
      return item;
    });
}

// ── specs ─────────────────────────────────────────────────────────────────────

export const ISLAND_SPECS = {
  equation: {
    bpType: "equation",
    nodeName: "bpEquation",
    chip: "Equation",
    fields: [
      { key: "tex", kind: "textarea", label: "TeX", placeholder: "E = mc^2", mono: true },
      { key: "display", kind: "bool", label: "Display (own line)" },
    ],
    preview(attrs, el) {
      const tex = (attrs.tex || "").trim();
      el.className = "bp-equation" + (tex ? "" : " bp-equation--empty") + " bp-canvas-island__preview";
      el.textContent = "";
      if (!tex) {
        el.textContent = "equation — no tex source";
        return;
      }
      const code = document.createElement("code");
      code.className = "bp-canvas-equation__tex";
      code.textContent = tex;
      el.appendChild(code);
    },
  },
  footnote: {
    bpType: "footnote",
    nodeName: "bpFootnote",
    chip: "Footnotes",
    fields: [{ key: "notes", kind: "notes", label: "Notes, one per line", placeholder: "One footnote per line" }],
    preview(attrs, el) {
      const notes = Array.isArray(attrs.notes) ? attrs.notes : [];
      el.className = "bp-canvas-island__preview";
      el.textContent = "";
      if (!notes.length) {
        el.className += " bp-canvas-island__empty";
        el.textContent = "footnotes — none yet";
        return;
      }
      const ol = document.createElement("ol");
      ol.className = "bp-footnote";
      for (const n of notes) {
        const li = document.createElement("li");
        li.className = "bp-footnote__note";
        li.textContent = n && typeof n === "object" ? String(n.text == null ? "" : n.text) : String(n);
        ol.appendChild(li);
      }
      el.appendChild(ol);
    },
  },
  toc: {
    bpType: "toc",
    nodeName: "bpToc",
    chip: "Contents",
    fields: [
      { key: "items", kind: "outline", label: "Entries (indent two spaces per level; `text | anchor`)", placeholder: "Introduction | intro\n  Background" },
      { key: "numbered", kind: "bool", label: "Numbered" },
    ],
    preview(attrs, el) {
      const items = Array.isArray(attrs.items) ? attrs.items.filter((it) => it && it.text) : [];
      el.className = "bp-canvas-island__preview";
      el.textContent = "";
      if (!items.length) {
        el.className += " bp-canvas-island__empty";
        el.textContent = "contents — no entries yet";
        return;
      }
      const nav = document.createElement("nav");
      nav.className = "bp-toc";
      const numbered = attrs.numbered === true;
      const list = document.createElement(numbered ? "ol" : "ul");
      list.className = "bp-toc__list" + (numbered ? "" : " bp-toc__list--bulleted");
      const minLevel = Math.min(...items.map((it) => Math.max(1, parseInt(it.level, 10) || 1)));
      for (const it of items) {
        const li = document.createElement("li");
        li.className = "bp-toc__item";
        const rel = Math.max(1, (parseInt(it.level, 10) || 1) - minLevel + 1);
        li.setAttribute("data-level", String(rel));
        li.textContent = String(it.text);
        list.appendChild(li);
      }
      nav.appendChild(list);
      el.appendChild(nav);
    },
  },
  video: {
    bpType: "video",
    nodeName: "bpVideo",
    chip: "Video",
    fields: [
      { key: "src", kind: "text", label: "Video url", placeholder: "video url" },
      { key: "poster", kind: "text", label: "Poster url", placeholder: "poster url (optional)" },
      { key: "loop", kind: "bool", label: "Loop" },
    ],
    preview(attrs, el) {
      const src = (attrs.src || "").trim();
      el.className = "bp-canvas-island__preview";
      el.textContent = "";
      if (!src) {
        el.className += " bp-canvas-island__empty";
        el.textContent = "No video yet — paste a video url below";
        return;
      }
      const fig = document.createElement("figure");
      fig.className = "bp-canvas-video";
      const video = document.createElement("video");
      video.controls = true;
      video.setAttribute("playsinline", "");
      video.preload = "metadata";
      video.src = src;
      if (attrs.poster) video.poster = attrs.poster;
      video.loop = attrs.loop === true;
      fig.appendChild(video);
      el.appendChild(fig);
    },
  },
};

const isJsonKind = (kind) => kind === "notes" || kind === "outline";

function fieldAttribute(field) {
  const name = "data-" + field.key;
  if (field.kind === "bool") {
    return {
      default: null,
      parseHTML: (el) => (el.hasAttribute(name) ? el.getAttribute(name) === "true" : null),
      renderHTML: (attrs) => (attrs[field.key] != null ? { [name]: attrs[field.key] ? "true" : "false" } : {}),
    };
  }
  if (isJsonKind(field.kind)) {
    return {
      default: null,
      parseHTML: (el) => {
        const raw = el.getAttribute(name);
        if (raw == null || raw === "") return null;
        try {
          return JSON.parse(raw);
        } catch (_) {
          return null;
        }
      },
      renderHTML: (attrs) => (attrs[field.key] != null ? { [name]: JSON.stringify(attrs[field.key]) } : {}),
    };
  }
  return {
    default: null,
    parseHTML: (el) => (el.hasAttribute(name) ? el.getAttribute(name) : null),
    renderHTML: (attrs) => (attrs[field.key] != null && attrs[field.key] !== "" ? { [name]: attrs[field.key] } : {}),
  };
}

export function makeIslandNode(spec) {
  return Node.create({
    name: spec.nodeName,
    group: "block",
    atom: true,
    selectable: true,
    draggable: true,

    addAttributes() {
      const attrs = {
        bpId: {
          default: null,
          parseHTML: (el) => el.getAttribute("data-bp-id"),
          renderHTML: (a) => (a.bpId ? { "data-bp-id": a.bpId } : {}),
        },
        bpType: {
          default: spec.bpType,
          parseHTML: (el) => el.getAttribute("data-bp-type") || spec.bpType,
          renderHTML: (a) => (a.bpType ? { "data-bp-type": a.bpType } : {}),
        },
        bpRest: {
          default: null,
          parseHTML: (el) => {
            const raw = el.getAttribute("data-bp-rest");
            if (raw == null || raw === "") return null;
            try {
              return JSON.parse(raw);
            } catch (_) {
              return null;
            }
          },
          renderHTML: (a) => (a.bpRest != null ? { "data-bp-rest": JSON.stringify(a.bpRest) } : {}),
        },
      };
      for (const field of spec.fields) attrs[field.key] = fieldAttribute(field);
      return attrs;
    },

    parseHTML() {
      return [{ tag: `div[data-bp-type='${spec.bpType}']` }];
    },

    renderHTML({ HTMLAttributes }) {
      return ["div", mergeAttributes(HTMLAttributes, { "data-bp-type": spec.bpType, class: "bp-canvas-island" }), spec.chip];
    },

    addNodeView() {
      return ({ node, editor, getPos }) => {
        const dom = document.createElement("div");
        dom.className = "bp-canvas-island bp-canvas-island--" + spec.bpType;
        dom.setAttribute("data-bp-type", spec.bpType);
        dom.setAttribute("contenteditable", "false");
        dom.setAttribute("data-test-id", "paper-" + spec.bpType);

        const preview = document.createElement("div");
        dom.appendChild(preview);

        const chrome = document.createElement("div");
        chrome.className = "bp-canvas-island__fields";
        const controls = {};
        for (const field of spec.fields) {
          const row = document.createElement("label");
          row.className = "bp-canvas-island__field bp-canvas-island__field--" + field.kind;
          const caption = document.createElement("span");
          caption.className = "bp-canvas-island__label";
          caption.textContent = field.label;
          let input;
          if (field.kind === "bool") {
            input = document.createElement("input");
            input.type = "checkbox";
          } else if (field.kind === "text") {
            input = document.createElement("input");
            input.type = "text";
            input.placeholder = field.placeholder || "";
          } else {
            input = document.createElement("textarea");
            input.placeholder = field.placeholder || "";
            input.rows = 2;
            if (field.mono) input.classList.add("bp-canvas-island__mono");
          }
          input.className += " bp-canvas-island__input bp-canvas-island__input--" + field.key;
          input.setAttribute("aria-label", field.label);
          input.setAttribute("contenteditable", "false");
          input.spellcheck = false;
          input.setAttribute("data-test-id", `paper-${spec.bpType}-${field.key}`);
          if (field.kind === "bool") row.append(input, caption);
          else row.append(caption, input);
          chrome.appendChild(row);
          controls[field.key] = { field, input };
        }
        dom.appendChild(chrome);

        const readControl = (field, input, prev) => {
          if (field.kind === "bool") return input.checked ? true : prev == null ? null : false;
          if (field.kind === "notes") return textToNotes(input.value, prev);
          if (field.kind === "outline") return textToOutline(input.value);
          const v = input.value;
          return v.trim() === "" ? null : v;
        };
        const writeControl = (field, input, value) => {
          if (field.kind === "bool") input.checked = value === true;
          else if (field.kind === "notes") { const t = notesToText(value); if (input.value !== t) input.value = t; }
          else if (field.kind === "outline") { const t = outlineToText(value); if (input.value !== t) input.value = t; }
          else { const t = value == null ? "" : String(value); if (input.value !== t) input.value = t; }
        };
        const hasData = (attrs) => spec.fields.some((f) => {
          const v = attrs[f.key];
          return f.kind === "bool" ? false : Array.isArray(v) ? v.length > 0 : v != null && String(v).trim() !== "";
        });

        let hovered = false;
        let focused = false;
        const syncChrome = (attrs) => {
          const filled = hasData(attrs);
          const hide = configControlHidden({ value: filled ? "x" : "", hovered: hovered && editor.isEditable, focused: focused && editor.isEditable });
          chrome.style.display = filled && hide ? "none" : "";
        };

        const paint = (n) => {
          const attrs = n.attrs || {};
          spec.preview(attrs, preview);
          for (const { field, input } of Object.values(controls)) {
            writeControl(field, input, attrs[field.key]);
            if (field.kind === "bool") input.disabled = !editor.isEditable;
            else input.readOnly = !editor.isEditable;
          }
          syncChrome(attrs);
        };
        paint(node);

        const commit = () => {
          if (typeof getPos !== "function") return;
          const pos = getPos();
          if (pos == null) return;
          const cur = editor.state.doc.nodeAt(pos);
          if (!cur || cur.type.name !== spec.nodeName) return;
          const next = { ...cur.attrs };
          let changed = false;
          for (const { field, input } of Object.values(controls)) {
            const v = readControl(field, input, cur.attrs[field.key]);
            if (JSON.stringify(v) !== JSON.stringify(cur.attrs[field.key])) {
              next[field.key] = v;
              changed = true;
            }
          }
          if (!changed) return;
          editor
            .chain()
            .command(({ tr }) => {
              tr.setNodeMarkup(pos, undefined, next);
              return true;
            })
            .run();
        };
        let writeTimer = null;
        const schedule = () => {
          if (!editor.isEditable) return;
          if (writeTimer) clearTimeout(writeTimer);
          writeTimer = setTimeout(() => { writeTimer = null; commit(); }, DEBOUNCE_MS);
        };
        const flush = () => {
          if (writeTimer) { clearTimeout(writeTimer); writeTimer = null; }
          commit();
        };
        const onKey = (e) => {
          // Enter commits a one-line field; Ctrl/Cmd+Enter commits a textarea.
          if (e.key === "Enter" && (e.target.tagName !== "TEXTAREA" || e.ctrlKey || e.metaKey)) {
            e.preventDefault();
            flush();
          }
        };
        const onEnter = () => { hovered = true; syncChrome(currentAttrs()); };
        const onLeave = () => { hovered = false; syncChrome(currentAttrs()); };
        const onFocusIn = () => { focused = true; syncChrome(currentAttrs()); };
        const onFocusOut = (e) => {
          if (e && e.relatedTarget && dom.contains(e.relatedTarget)) return;
          focused = false;
          flush();
          syncChrome(currentAttrs());
        };
        const currentAttrs = () => {
          if (typeof getPos !== "function") return node.attrs;
          const pos = getPos();
          const cur = pos == null ? null : editor.state.doc.nodeAt(pos);
          return (cur && cur.attrs) || node.attrs;
        };
        for (const { field, input } of Object.values(controls)) {
          input.addEventListener(field.kind === "bool" ? "change" : "input", field.kind === "bool" ? flush : schedule);
          input.addEventListener("keydown", onKey);
        }
        dom.addEventListener("mouseenter", onEnter);
        dom.addEventListener("mouseleave", onLeave);
        dom.addEventListener("focusin", onFocusIn);
        dom.addEventListener("focusout", onFocusOut);
        dom.addEventListener("bp-flush-node", flush);

        wireAtomAccessibility(dom, { block: { type: spec.bpType }, chipText: spec.chip, editor, getPos });

        return {
          dom,
          update: (updated) => {
            if (updated.type.name !== spec.nodeName) return false;
            paint(updated);
            return true;
          },
          stopEvent: () => true,
          ignoreMutation: () => true,
          destroy: () => {
            if (writeTimer) clearTimeout(writeTimer);
            dom.removeEventListener("bp-flush-node", flush);
            dom.removeEventListener("mouseenter", onEnter);
            dom.removeEventListener("mouseleave", onLeave);
            dom.removeEventListener("focusin", onFocusIn);
            dom.removeEventListener("focusout", onFocusOut);
            for (const { field, input } of Object.values(controls)) {
              input.removeEventListener(field.kind === "bool" ? "change" : "input", field.kind === "bool" ? flush : schedule);
              input.removeEventListener("keydown", onKey);
            }
          },
        };
      };
    },
  });
}

export const Equation = makeIslandNode(ISLAND_SPECS.equation);
export const Footnote = makeIslandNode(ISLAND_SPECS.footnote);
export const Toc = makeIslandNode(ISLAND_SPECS.toc);
export const Video = makeIslandNode(ISLAND_SPECS.video);
