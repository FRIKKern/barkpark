// card-node.js — STEP 4 (composition-doctrine FINALE): the card WIDGET as a canvas
// node.
//
// Brings the NEW slots-native `card` block INTO the continuous canvas as a
// ProseMirror CONTENT node (`bpCard`). A card is a callout+section FUSION:
//   * body slot  → THE contentDOM (content:"inline*"), a real editable inline region
//                  that JOINS the run + FormatBubble (the callout body precedent). A
//                  PM NodeView has EXACTLY ONE contentDOM, so the body slot claims it.
//   * title slot → an attr-backed contentEditable ISLAND writing node.attrs.title
//                  (the section.title precedent: debounced, re-entrancy-guarded
//                  setNodeMarkup; Enter suppressed; cleared → null round-trips ABSENT).
//   * media/action slots → PRESENT-ONLY attrs carrying the WHOLE image/action element
//                  (deep-cloned; the bpColumnAtom/section.cells precedent), painted
//                  read-only with a light control (round-trip-FAITHFUL now, richer
//                  editing a fast-follow).
//
// ── VIEW⇄EDIT PARITY (the callout carve-out) ─────────────────────────────────
//
// CHROME = `bp-canvas-*` ONLY (bp-canvas-card, bp-canvas-card__controls). PAINT VIA
// THE SHARED READER CLASS: the node-view root carries `bp-card` + `bp-card--<tone>`,
// its title/body wrappers carry `bp-card__t` / `bp-card__d`, its media/action wrappers
// carry `bp-card__media` / `bp-card__action` — so the reader's OWN
// `.bp-paper-surface .bp-card*` cascade paints it for FREE (callout-node.js pattern;
// embedder styles.css mirror + root.html.heex canvas copy). ZERO inline paint, ZERO
// reader-class duplication in logic. The node-view emits `bp-card__` literals so it
// inherits the reader paint (parity-gate §3 GRADUATED `bp-card__` out of its forbidden
// list for exactly this reason); it NEVER emits the legacy fleet GRID wrapper class
// (still gated) — a grid section of cards emits `bp-section__grid` instead.
//
// The reader ground truth is Components.card_html/1 (byte-aligned to ONE legacy
// `cards` item): <div class="bp-card[ bp-card--<tone>]">[media][__t][__d][action]</div>.
// The body slot FLATTENS to plain text server-side (Slots.card_body_text), so inline
// marks authored here round-trip in persistence but do NOT render — a deliberate
// STEP-4 tradeoff (byte-compat over rich body).
//
// DOM-aware (the NodeView builds real DOM) but the Node SCHEMA object loads in plain
// Node (imports ONLY @tiptap/core; references `document` lazily inside addNodeView,
// which never runs in the pure-Node smoke harness). run-convert.js references the
// bpCard TYPE only (a string constant), never this NodeView, so __cards.test.mjs runs
// headless.

import { Node, mergeAttributes } from "@tiptap/core";

// The TipTap node NAME is `bpCard` (its portable-doc bpType stays "card"); run-convert
// maps a block.type "card" → this node and back via node.attrs.bpType — the SAME
// node/bpType indirection bpSection/bpCode use.
export const BP_CARD_NODE_NAME = "bpCard";
export const BP_CARD_BP_TYPE = "card";

// Tone → the modifier class, mirroring Components.card_html/1's allowlist EXACTLY
// (cards_html:306): the four legacy card tones pass through, anything else → NO
// modifier (unlike callout, which falls back to "info"). This is the LEGACY CARD tone
// vocab (info|ok|warn|danger), NOT the callout success/warning/danger/neutral/info
// vocab — a card renders identically to a legacy cards item, not to a callout.
const CARD_TONES = ["info", "ok", "warn", "danger"];
function cardToneClass(tone) {
  return CARD_TONES.includes(tone) ? ` bp-card--${tone}` : "";
}

// A present-only JSON data-attr (the section layout/cells precedent): a JSON object
// survives setContent→getJSON because it rides a data-attr, not a dropped node key.
// null/absent round-trips ABSENT. Closes over BOTH the attr key (`attrKey`, e.g.
// "media") and the DOM data-attr name (`dataName`, e.g. "data-media") because TipTap's
// renderHTML receives only the full attrs object.
function jsonAttr(attrKey, dataName) {
  return {
    default: null,
    parseHTML: (el) => {
      const raw = el.getAttribute(dataName);
      if (raw == null) return null;
      try {
        return JSON.parse(raw);
      } catch {
        return null;
      }
    },
    renderHTML: (attrs) =>
      attrs[attrKey] != null ? { [dataName]: JSON.stringify(attrs[attrKey]) } : {},
  };
}

export const Card = Node.create({
  name: BP_CARD_NODE_NAME,

  // A top-level block sibling inside the one canvas document. group:"block" lets it
  // sit in the doc's `block+` content AND in a grid section's body (bpCard is in
  // BP_SECTION_CONTENT).
  group: "block",

  // The body slot is a SINGLE editable inline region — a paragraph's content model
  // (the callout body precedent). NOT block+.
  content: "inline*",

  selectable: true,

  // defining — PM won't merge the card into an adjacent textblock on backspace-at-edge
  // (Backspace at the body start lifts out of the card rather than dissolving chrome).
  defining: true,

  addAttributes() {
    return {
      // bpId — the portable-doc block id runToOps keys by.
      bpId: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-bp-id"),
        renderHTML: (attrs) => (attrs.bpId ? { "data-bp-id": attrs.bpId } : {}),
      },
      // bpType — the original portable-doc block kind ("card").
      bpType: {
        default: BP_CARD_BP_TYPE,
        parseHTML: (el) => el.getAttribute("data-bp-type") || BP_CARD_BP_TYPE,
        renderHTML: (attrs) => ({ "data-bp-type": attrs.bpType || BP_CARD_BP_TYPE }),
      },
      // tone — PRESENT-ONLY (info|ok|warn|danger). DIVERGES from callout: a tone-less
      // card renders NO data-tone and NO modifier class (byte-matches a legacy item);
      // it must NOT gain "info" or it would emit a spurious op on round-trip.
      tone: {
        default: null,
        parseHTML: (el) =>
          el.hasAttribute("data-tone") ? el.getAttribute("data-tone") : null,
        renderHTML: (attrs) =>
          attrs.tone != null ? { "data-tone": attrs.tone } : {},
      },
      // title — the title slot heading's text, PRESENT-ONLY. A null/absent title
      // round-trips ABSENT (never ""), byte-mirroring section/callout title.
      title: {
        default: null,
        parseHTML: (el) =>
          el.hasAttribute("data-title") ? el.getAttribute("data-title") : null,
        renderHTML: (attrs) =>
          attrs.title != null ? { "data-title": attrs.title } : {},
      },
      // media / action — PRESENT-ONLY JSON carriers for the whole image/action element.
      media: jsonAttr("media", "data-media"),
      action: jsonAttr("action", "data-action"),
    };
  },

  parseHTML() {
    return [{ tag: "div[data-bp-type='card']" }];
  },

  // A schema-level fallback render (used when NO node-view is mounted — the pure-Node
  // round-trip / a non-editable export). The node-view (below) OVERRIDES this. The `0`
  // is the inline body content hole; chrome (title/media/action) lives ONLY in the
  // node-view, so parseHTML never mis-parses chrome as body.
  renderHTML({ HTMLAttributes }) {
    return [
      "div",
      mergeAttributes(HTMLAttributes, { "data-bp-type": "card" }),
      ["div", { "data-card-body": "" }, 0],
    ];
  },

  // ── the NodeView: reader-shaped card around an editable body contentDOM ───────
  //
  //   <div class="bp-canvas-card bp-card[ bp-card--<tone>]" data-bp-type="card">
  //     <div class="bp-canvas-card__controls">…light media/action/tone controls…</div>
  //     <div class="bp-card__media"><img></div>            ← media chrome (present-only)
  //     <div class="bp-card__t" contenteditable>TITLE</div> ← EDITABLE title island
  //     <div class="bp-card__d">…</div>                     ← contentDOM (editable body)
  //     <div class="bp-card__action"><a>…</a></div>         ← action chrome (present-only)
  //   </div>
  //
  // Colour rides ENTIRELY on `bp-card--<tone>` (reader cascade + embedder mirror). The
  // title island writes node.attrs.title via a debounced, re-entrancy-guarded
  // setNodeMarkup; its events/mutations are hidden from PM (stopEvent/ignoreMutation).
  addNodeView() {
    return ({ node, editor, getPos }) => {
      const dom = document.createElement("div");
      dom.setAttribute("data-bp-type", "card");

      // ── light edit-only controls (hidden at rest; the section controls precedent).
      const controls = document.createElement("div");
      controls.className = "bp-canvas-card__controls";
      controls.contentEditable = "false";

      const mediaInput = document.createElement("input");
      mediaInput.type = "text";
      mediaInput.className = "bp-canvas-card__input";
      mediaInput.placeholder = "media src";
      mediaInput.setAttribute("data-test-id", "paper-card-media-src");

      const actionLabelInput = document.createElement("input");
      actionLabelInput.type = "text";
      actionLabelInput.className = "bp-canvas-card__input";
      actionLabelInput.placeholder = "action label";
      actionLabelInput.setAttribute("data-test-id", "paper-card-action-label");

      const actionHrefInput = document.createElement("input");
      actionHrefInput.type = "text";
      actionHrefInput.className = "bp-canvas-card__input";
      actionHrefInput.placeholder = "action href";
      actionHrefInput.setAttribute("data-test-id", "paper-card-action-href");

      controls.append(mediaInput, actionLabelInput, actionHrefInput);

      // media chrome — a read-only <img> wrapper (present-only).
      const mediaEl = document.createElement("div");
      mediaEl.className = "bp-card__media";
      mediaEl.contentEditable = "false";
      const mediaImg = document.createElement("img");
      mediaEl.appendChild(mediaImg);

      // title island — an editable contentEditable island writing node.attrs.title.
      const titleEl = document.createElement("div");
      titleEl.className = "bp-card__t";
      titleEl.setAttribute("data-test-id", "paper-card-title");

      // body — the contentDOM hole PM fills with the inline body slot.
      const body = document.createElement("div");
      body.className = "bp-card__d";

      // action chrome — a read-only link wrapper (present-only).
      const actionEl = document.createElement("div");
      actionEl.className = "bp-card__action";
      actionEl.contentEditable = "false";
      const actionLink = document.createElement("a");
      actionEl.appendChild(actionLink);

      // Reader order: media, title, body, action. Controls ride at the top (edit-only).
      dom.append(controls, mediaEl, titleEl, body, actionEl);

      let syncingTitle = false;
      let titleFocused = false;

      const currentNode = () => {
        if (typeof getPos !== "function") return node;
        const pos = getPos();
        if (pos == null) return node;
        return editor.state.doc.nodeAt(pos) || node;
      };

      const paint = (n) => {
        const a = (n && n.attrs) || {};
        dom.className = `bp-canvas-card bp-card${cardToneClass(a.tone)}`;

        // Title island — write only when the DOM disagrees (never clobber the caret).
        const title = a.title;
        const hasTitle = title != null && title !== "";
        const shown = hasTitle ? title : "";
        if (titleEl.textContent !== shown) {
          syncingTitle = true;
          titleEl.textContent = shown;
          syncingTitle = false;
        }
        const editable = editor.isEditable;
        titleEl.contentEditable = editable ? "true" : "false";
        titleEl.style.display = hasTitle || (editable && titleFocused) ? "" : "none";

        // media chrome (present-only): show the <img> iff a media element with a src.
        const media = a.media;
        const src = (media && media.src) || "";
        if (src) {
          mediaImg.setAttribute("src", src);
          mediaImg.setAttribute("alt", (media && media.alt) || "");
          mediaEl.style.display = "";
        } else {
          mediaEl.style.display = "none";
        }
        if (mediaInput.value !== src && document.activeElement !== mediaInput) {
          mediaInput.value = src;
        }

        // action chrome (present-only): show the link iff a label or href.
        const action = a.action;
        const label = (action && action.label) || "";
        const href = (action && action.href) || "";
        if (label || href) {
          actionLink.textContent = label;
          actionLink.setAttribute("href", href);
          actionEl.style.display = "";
        } else {
          actionEl.style.display = "none";
        }
        if (actionLabelInput.value !== label && document.activeElement !== actionLabelInput) {
          actionLabelInput.value = label;
        }
        if (actionHrefInput.value !== href && document.activeElement !== actionHrefInput) {
          actionHrefInput.value = href;
        }

        controls.style.display = editor.isEditable ? "" : "none";
      };

      // Write an attr via a re-entrancy-guarded setNodeMarkup (the section precedent).
      const writeAttr = (mutate) => {
        if (!editor.isEditable) return;
        if (typeof getPos !== "function") return;
        const pos = getPos();
        if (pos == null) return;
        const cur = editor.state.doc.nodeAt(pos);
        if (!cur || cur.type.name !== BP_CARD_NODE_NAME) return;
        const nextAttrs = mutate({ ...cur.attrs });
        editor
          .chain()
          .command(({ tr }) => {
            tr.setNodeMarkup(pos, undefined, nextAttrs);
            return true;
          })
          .run();
      };

      // ── title island: debounced write-back (cleared → null → round-trips ABSENT).
      let writeTimer = null;
      const scheduleTitleWrite = () => {
        if (syncingTitle) return;
        if (!editor.isEditable) return;
        if (writeTimer) clearTimeout(writeTimer);
        writeTimer = setTimeout(() => {
          writeTimer = null;
          const raw = titleEl.textContent || "";
          const nextTitle = raw === "" ? null : raw;
          writeAttr((attrs) => {
            if ((attrs.title || null) === nextTitle) return attrs;
            attrs.title = nextTitle;
            return attrs;
          });
        }, 250);
      };
      const onTitleInput = () => scheduleTitleWrite();
      const onTitleFocus = () => {
        titleFocused = true;
        if (editor.isEditable) titleEl.style.display = "";
      };
      const onTitleBlur = () => {
        titleFocused = false;
        paint(currentNode());
      };
      const onTitleKeydown = (e) => {
        if (e.key === "Enter") {
          e.preventDefault();
          titleEl.blur();
        }
      };
      titleEl.addEventListener("input", onTitleInput);
      titleEl.addEventListener("focus", onTitleFocus);
      titleEl.addEventListener("blur", onTitleBlur);
      titleEl.addEventListener("keydown", onTitleKeydown);

      // ── media control: set/clear the media element's src (present-only carrier).
      const onMediaInput = () => {
        const src = mediaInput.value || "";
        writeAttr((attrs) => {
          if (src === "") {
            attrs.media = null; // clear → round-trips ABSENT (removal lands)
          } else {
            const prev = attrs.media && typeof attrs.media === "object" ? attrs.media : {};
            attrs.media = { ...prev, type: "image", src };
          }
          return attrs;
        });
      };
      mediaInput.addEventListener("change", onMediaInput);

      // ── action controls: set/clear the action element's label/href.
      const writeAction = () => {
        const label = actionLabelInput.value || "";
        const href = actionHrefInput.value || "";
        writeAttr((attrs) => {
          if (label === "" && href === "") {
            attrs.action = null; // clear → round-trips ABSENT
          } else {
            const prev = attrs.action && typeof attrs.action === "object" ? attrs.action : {};
            attrs.action = { ...prev, type: "action", label, href };
          }
          return attrs;
        });
      };
      actionLabelInput.addEventListener("change", writeAction);
      actionHrefInput.addEventListener("change", writeAction);

      paint(node);

      return {
        dom,
        contentDOM: body,
        update: (updated) => {
          if (updated.type.name !== BP_CARD_NODE_NAME) return false;
          paint(updated);
          return true;
        },
        stopEvent: (e) => {
          const t = e && e.target;
          return !!(t && (titleEl.contains(t) || controls.contains(t)));
        },
        ignoreMutation: (m) => {
          if (m.type === "selection") return false; // let PM own selection
          if (m.type === "attributes" && m.target === dom) return true;
          if (titleEl.contains(m.target)) return true; // title edits are attr writes
          if (controls.contains(m.target)) return true; // controls are attr writes
          if (mediaEl.contains(m.target)) return true; // media chrome is attr-painted
          if (actionEl.contains(m.target)) return true; // action chrome is attr-painted
          // Let PM handle mutations inside the editable body (contentDOM); ignore chrome.
          return !body.contains(m.target);
        },
        destroy: () => {
          if (writeTimer) clearTimeout(writeTimer);
          titleEl.removeEventListener("input", onTitleInput);
          titleEl.removeEventListener("focus", onTitleFocus);
          titleEl.removeEventListener("blur", onTitleBlur);
          titleEl.removeEventListener("keydown", onTitleKeydown);
          mediaInput.removeEventListener("change", onMediaInput);
          actionLabelInput.removeEventListener("change", writeAction);
          actionHrefInput.removeEventListener("change", writeAction);
        },
      };
    };
  },
});
