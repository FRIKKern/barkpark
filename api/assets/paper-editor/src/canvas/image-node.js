// image-node.js — the `image` block as a canvas ATOM that paints itself.
//
// `image` is the element the markdown importer, the BPML parser and agents write
// (`{ type:"image", src, alt, width?, height? }`, plus the doctrine template's locked
// `role:"featured"` image at block 1 of every new paper). Until now it was a run
// BOUNDARY: in Studio the typed-leaf picker owns it, and in a whole-paper canvas
// (Barkdown) it mounted as a read-only bpOpaque chip an author could not touch.
//
// This node is the figure atom's shape (figure-node.js) with the server paint
// removed: an <img> needs no producer, so the node-view shows the picture itself
// (or an honest "no image" frame when the asset is missing — the reader skips such a
// block, compose.ex's asset-less doctrine) and offers two non-PM inputs, ALT and
// URL. Both write back to typed attrs through setNodeMarkup, so run-convert emits
// ONE patch-block{src, alt}; every other key (width, height, role, unknown) rides
// verbatim on `bpRest` and is never patched. Uploads (paste / drop → Barkpark media)
// are the next plan item; this node is what they will land in.
//
// DOM-aware (the node-view builds real DOM) but the Node SCHEMA object loads in
// plain Node: `document` is touched only inside addNodeView, which the pure-Node
// harness never runs (__image.test.mjs imports run-convert.js and this NAME only).

import { Node, mergeAttributes } from "@tiptap/core";
import { DEBOUNCE_MS, configControlHidden } from "../contract.js";
import { wireAtomAccessibility } from "./embed-node.js";

// The TipTap node NAME is `bpImage`; the portable-doc `bpType` stays "image"
// (run-convert.js maps a block.type "image" to this node and back).
export const BP_IMAGE_NODE_NAME = "bpImage";

const stringAttr = (name) => ({
  default: null,
  parseHTML: (el) => (el.hasAttribute(name) ? el.getAttribute(name) : null),
  renderHTML: (attrs) => {
    const key = name.replace(/^data-/, "");
    const v = attrs[key];
    return v != null && v !== "" ? { [name]: v } : {};
  },
});

export const Image = Node.create({
  name: BP_IMAGE_NODE_NAME,
  group: "block",
  // An atom leaf: no PM interior. The picture and the two inputs live outside
  // ProseMirror, so the node is one indivisible unit (select + Backspace deletes).
  atom: true,
  selectable: true,
  draggable: true,

  addAttributes() {
    return {
      bpId: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-bp-id"),
        renderHTML: (attrs) => (attrs.bpId ? { "data-bp-id": attrs.bpId } : {}),
      },
      bpType: {
        default: "image",
        parseHTML: (el) => el.getAttribute("data-bp-type") || "image",
        renderHTML: (attrs) => (attrs.bpType ? { "data-bp-type": attrs.bpType } : {}),
      },
      // The two editable data. "" and absent both read as null so a src-less
      // template image round-trips without inventing a key.
      src: stringAttr("data-src"),
      alt: stringAttr("data-alt"),
      // Doctrine template identity (locked title / featured image): carried so the
      // locked-block guard in index.js recognizes the node; never patched.
      locked: {
        default: null,
        parseHTML: (el) => (el.getAttribute("data-locked") === "true" ? true : null),
        renderHTML: (attrs) => (attrs.locked === true ? { "data-locked": "true" } : {}),
      },
      role: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-role"),
        renderHTML: (attrs) => (attrs.role != null ? { "data-role": attrs.role } : {}),
      },
      // Every other block key (width, height, unknown) verbatim, as JSON.
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
        renderHTML: (attrs) =>
          attrs.bpRest != null ? { "data-bp-rest": JSON.stringify(attrs.bpRest) } : {},
      },
    };
  },

  parseHTML() {
    return [{ tag: "figure[data-bp-type='image']" }];
  },

  // Schema-level fallback render (no node-view mounted): the typed wrapper with the
  // picture inside, so a non-editable export still shows it.
  renderHTML({ HTMLAttributes, node }) {
    const src = node && node.attrs ? node.attrs.src : null;
    const img = src
      ? ["img", { src, alt: (node.attrs && node.attrs.alt) || "", loading: "lazy" }]
      : ["div", { class: "bp-canvas-image-empty" }, "No image"];
    return ["figure", mergeAttributes(HTMLAttributes, { "data-bp-type": "image", class: "bp-canvas-image" }), img];
  },

  addNodeView() {
    return ({ node, editor, getPos }) => {
      const dom = document.createElement("figure");
      dom.className = "bp-canvas-image";
      dom.setAttribute("data-bp-type", "image");
      dom.setAttribute("contenteditable", "false");
      dom.setAttribute("data-test-id", "paper-image");

      // The picture, or the empty frame.
      const frame = document.createElement("div");
      frame.className = "bp-canvas-image-frame";
      const img = document.createElement("img");
      img.className = "bp-canvas-image-img";
      img.loading = "lazy";
      img.draggable = false;
      const empty = document.createElement("div");
      empty.className = "bp-canvas-image-empty";
      empty.textContent = "No image yet — paste an image URL below";
      frame.appendChild(img);
      frame.appendChild(empty);
      dom.appendChild(frame);

      // The two edit inputs, in a row that hides at rest like the figure caption.
      const chrome = document.createElement("div");
      chrome.className = "bp-canvas-image-chrome";
      const mkInput = (cls, placeholder, label) => {
        const input = document.createElement("input");
        input.type = "text";
        input.className = cls;
        input.placeholder = placeholder;
        input.setAttribute("aria-label", label);
        input.setAttribute("contenteditable", "false");
        input.spellcheck = false;
        return input;
      };
      const altInput = mkInput("bp-canvas-image-alt", "alt text", "image alt text");
      const srcInput = mkInput("bp-canvas-image-src", "image url", "image url");
      chrome.appendChild(altInput);
      chrome.appendChild(srcInput);
      dom.appendChild(chrome);

      let hovered = false;
      let focused = false;
      const syncChrome = () => {
        const hide = configControlHidden({
          // With no src the chrome is the only affordance, so it never hides then.
          value: srcInput.value === "" ? "" : altInput.value + srcInput.value,
          hovered: hovered && editor.isEditable,
          focused: focused && editor.isEditable,
        });
        chrome.style.display = hide && srcInput.value !== "" ? "none" : "";
      };

      const paint = (n) => {
        const a = n.attrs || {};
        const src = a.src || "";
        const alt = a.alt || "";
        if (srcInput.value !== src) srcInput.value = src;
        if (altInput.value !== alt) altInput.value = alt;
        if (src) {
          if (img.getAttribute("src") !== src) img.setAttribute("src", src);
          img.alt = alt;
          img.style.display = "";
          empty.style.display = "none";
        } else {
          img.removeAttribute("src");
          img.style.display = "none";
          empty.style.display = "";
        }
        const locked = a.locked === true;
        dom.classList.toggle("bp-canvas-image--empty", !src);
        dom.classList.toggle("bp-canvas-image--locked", locked);
        srcInput.readOnly = altInput.readOnly = !editor.isEditable;
        syncChrome();
      };
      paint(node);

      const onEnter = () => { hovered = true; syncChrome(); };
      const onLeave = () => { hovered = false; syncChrome(); };
      const onFocusIn = () => { focused = true; syncChrome(); };
      const onFocusOut = (e) => {
        if (e && e.relatedTarget && dom.contains(e.relatedTarget)) return;
        focused = false;
        syncChrome();
      };
      dom.addEventListener("mouseenter", onEnter);
      dom.addEventListener("mouseleave", onLeave);
      dom.addEventListener("focusin", onFocusIn);
      dom.addEventListener("focusout", onFocusOut);

      wireAtomAccessibility(dom, {
        block: { type: "image", locked: node.attrs && node.attrs.locked === true },
        chipText: "Image",
        editor,
        getPos,
      });

      // Debounced write-back of the two inputs to the node attrs: one setNodeMarkup
      // per settled edit → onUpdate → run-convert emits one patch-block{src, alt}.
      let writeTimer = null;
      const commitWrite = () => {
        if (typeof getPos !== "function") return;
        const pos = getPos();
        if (pos == null) return;
        const cur = editor.state.doc.nodeAt(pos);
        if (!cur) return;
        const nextSrc = srcInput.value.trim() === "" ? null : srcInput.value.trim();
        const nextAlt = altInput.value === "" ? null : altInput.value;
        if ((cur.attrs.src || null) === nextSrc && (cur.attrs.alt || null) === nextAlt) return;
        editor
          .chain()
          .command(({ tr }) => {
            tr.setNodeMarkup(pos, undefined, { ...cur.attrs, src: nextSrc, alt: nextAlt });
            return true;
          })
          .run();
      };
      const scheduleWrite = () => {
        if (!editor.isEditable) return;
        if (writeTimer) clearTimeout(writeTimer);
        writeTimer = setTimeout(() => {
          writeTimer = null;
          commitWrite();
        }, DEBOUNCE_MS);
      };
      const flushWrite = () => {
        if (!writeTimer) return;
        clearTimeout(writeTimer);
        writeTimer = null;
        commitWrite();
      };
      const onKey = (e) => {
        // Enter commits the URL at once so the picture appears without the debounce.
        if (e.key === "Enter") {
          e.preventDefault();
          flushWrite();
        }
      };
      altInput.addEventListener("input", scheduleWrite);
      srcInput.addEventListener("input", scheduleWrite);
      srcInput.addEventListener("keydown", onKey);
      altInput.addEventListener("keydown", onKey);
      dom.addEventListener("bp-flush-node", flushWrite);

      return {
        dom,
        update: (updated) => {
          if (updated.type.name !== BP_IMAGE_NODE_NAME) return false;
          paint(updated);
          return true;
        },
        // The island contract: a keystroke in an input never becomes a PM
        // transaction; the frame's DOM is ours.
        stopEvent: () => true,
        ignoreMutation: () => true,
        destroy: () => {
          if (writeTimer) clearTimeout(writeTimer);
          dom.removeEventListener("bp-flush-node", flushWrite);
          altInput.removeEventListener("input", scheduleWrite);
          srcInput.removeEventListener("input", scheduleWrite);
          srcInput.removeEventListener("keydown", onKey);
          altInput.removeEventListener("keydown", onKey);
          dom.removeEventListener("mouseenter", onEnter);
          dom.removeEventListener("mouseleave", onLeave);
          dom.removeEventListener("focusin", onFocusIn);
          dom.removeEventListener("focusout", onFocusOut);
        },
      };
    };
  },
});
