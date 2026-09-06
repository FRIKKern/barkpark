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
//                  read-only with the reader class AND edited by REAL controls: the
//                  media slot by the <bp-media-picker chrome="ghost"> WC (the
//                  field-node buildPickerNodeView MOUNT PATTERN — value/scope seed,
//                  bubbling bp-change → attrs.media={type:"image",src}); the action
//                  slot by a label/href/priority editor (the action-node pattern —
//                  attrs.action={type:"action",label,href,priority?} PRESENT-ONLY).
//
// ── VIEW⇄EDIT PARITY (MODEL B — byte-aligned with card_html/2) ────────────────
//
// CHROME = `bp-canvas-*` ONLY (bp-canvas-card, bp-canvas-card__controls). The
// node-view emits the reader's MODEL-B DOM directly — bare semantics, byte-aligned
// with `Components.card_html/2` (components.ex), which recurses each slot through
// the ONE shared compose→walk bridge:
//   media  → <img src alt style="max-width:100%;height:auto"[ width height]>
//            (walk.ex image/1 — a bare img, NO wrapper div)
//   title  → <h2>text</h2> (PdHeading, default level 2 — here a contentEditable
//            island writing node.attrs.title)
//   body   → <p>…</p> (PdParagraph, classless — here the contentDOM IS the <p>)
//   action → <a href class="bp-button[ bp-button--primary]">label</a>
//            (walk.ex button/2's binary priority collapse)
// inside <div class="bp-card[ bp-card--<tone>]">, slots in the reader ORDER
// media, title, body, action. The root ALSO carries the `bp-canvas-card` mount
// hook + `data-bp-type` stamp (edit-only, the section-node precedent), and the
// #2398 media-picker/action-editor CONTROLS ride a contentEditable=false bar
// OUTSIDE the reader-shape subtree. The node-view emits NO card slot-chrome class
// (the model-A `__t`/`__d`/`__media`/`__action` wrappers) — the reader dropped that
// chrome (PRs #1529/#1539) and parity-gate §3 forbids the literal again (so it may
// not appear here even in a comment); __card_parity.test.mjs pins the mounted shape
// against the reader ground truth above. It NEVER emits the legacy fleet GRID wrapper class
// (still gated) — a grid section of cards emits `bp-section__grid` instead.
//
// The body slot persists as ONE paragraph whose inline content round-trips
// (run-convert cardNodeToSlots) — model B renders it as a real <p> with inline
// marks, so what is authored here is what /papers shows.
//
// DOM-aware (the NodeView builds real DOM) but the Node SCHEMA object loads in plain
// Node (imports ONLY @tiptap/core; references `document` lazily inside addNodeView,
// which never runs in the pure-Node smoke harness). run-convert.js references the
// bpCard TYPE only (a string constant), never this NodeView, so __cards.test.mjs runs
// headless.

import { Node, mergeAttributes } from "@tiptap/core";
// The card's media/action slot editors REUSE the field node's canvasScope seam (the
// exact bp-media-picker MOUNT PATTERN: seed dataset/scope/token). The picker's
// bp-change value is parsed by mediaUrlFromValue (below), NOT field-node's
// coercePickerValue: the field path's identity coercion targets a JSON-tolerant render
// (media_field_url/1), but the CARD render path is JSON-intolerant, so the URL must be
// extracted here. card-node.js rides ONLY the browser bundle (index.js imports it), but
// Node.create runs headless (addNodeView never fires in pure Node), so smoke/cards.mjs
// imports this file for the pure mediaUrlFromValue helper without dragging the WC/DOM
// path into the harness.
import { canvasScope } from "./field-node.js";

// The BINARY priority collapse the reader performs (walk.ex button/2): primary iff
// =="primary", else secondary. Used for the priority-select display; the WRITE path
// keeps priority PRESENT-ONLY (a never-set action stays priority-less — nil≡secondary
// is a zero-op that must NOT materialize a spurious priority:"secondary"). Lifted from
// action-node.js:normalizePriority.
function normalizeActionPriority(p) {
  return p === "primary" ? "primary" : "secondary";
}

// Parse the bp-media-picker's serialized value into a bare URL. On an ASSET-LIBRARY
// pick the picker emits JSON.stringify({url,assetId}) (bp-media-picker
// bpSerializeMediaValue); a direct/legacy pick emits a bare URL. The card render path
// has NO server-side JSON normalizer (unlike the field path's media_field_url/1), so a
// JSON blob written into attrs.media.src renders a broken <img src="{…}"> on the reader
// (walk.ex image/1). This is the exact JSON-tolerant fallback root.html.heex uses for
// the field-image path. Non-string, empty/whitespace, or an unparseable envelope → ""
// (a CLEAR, or a safe degrade — NEVER the raw blob). A bare URL passes through verbatim.
export function mediaUrlFromValue(raw) {
  if (typeof raw !== "string") return "";
  if (raw.trim().startsWith("{")) {
    try {
      return JSON.parse(raw).url || "";
    } catch {
      return "";
    }
  }
  return raw;
}

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
      // bpBlock — the authoritative Card, carried so editing one known surface
      // never erases opaque top-level/slot keys or metadata on slot elements.
      // The editable title/body/media/action attrs remain the live values; the
      // converter overlays them onto this deep-cloned preservation baseline.
      bpBlock: jsonAttr("bpBlock", "data-bp-block"),
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

  // ── the NodeView: the reader's MODEL-B card around an editable body contentDOM ─
  //
  //   <div class="bp-canvas-card bp-card[ bp-card--<tone>]" data-bp-type="card">
  //     <div class="bp-canvas-card__controls">              ← PM-safe chrome (fenced)
  //       <bp-media-picker chrome="ghost">                  ← the REAL media editor
  //       <input action-label> <input action-href> <select action-priority>
  //     </div>
  //     <img style="max-width:100%;height:auto">            ← media slot (present-only,
  //                                                            the reader's bare <img>)
  //     <h2 contenteditable>TITLE</h2>                       ← EDITABLE title island
  //     <p>…</p>                                             ← contentDOM (editable body)
  //     <a class="bp-button[ bp-button--primary]">…</a>      ← action slot (present-only,
  //                                                            the reader's PdButton)
  //   </div>
  //
  // Colour rides ENTIRELY on `bp-card--<tone>` (reader cascade + embedder mirror);
  // the slots are the reader's OWN bare-semantic shapes, so the surface h2/p/img/
  // .bp-button rules paint them identically in View and Edit. The title island
  // writes node.attrs.title via a debounced, re-entrancy-guarded setNodeMarkup;
  // its events/mutations are hidden from PM (stopEvent/ignoreMutation).
  addNodeView() {
    return ({ node, editor, getPos }) => {
      const dom = document.createElement("div");
      dom.setAttribute("data-bp-type", "card");

      // ── light edit-only controls (hidden at rest; the section controls precedent).
      // The whole bar is PM-safe chrome OUTSIDE the contentDOM (body only): it is a
      // contentEditable=false sibling and every host inside it is covered by BOTH the
      // stopEvent test and the ignoreMutation .contains chain below, so a keystroke /
      // WC fetch / select never becomes a PM transaction or a doc mutation.
      const controls = document.createElement("div");
      controls.className = "bp-canvas-card__controls";
      controls.contentEditable = "false";

      // MEDIA: the REAL <bp-media-picker chrome="ghost"> WC — the field-node
      // buildPickerNodeView MOUNT PATTERN, not the function. Seed value (the media
      // element's src) + dataset/scope-prefix/token via canvasScope, listen for the
      // bubbling `bp-change` CustomEvent (detail.value is a single asset-ref STRING),
      // and commit via the SAME writeAttr/setNodeMarkup path the raw input used.
      const scope = canvasScope(editor);
      const mediaPicker = document.createElement("bp-media-picker");
      mediaPicker.className = "bp-canvas-card__media-picker";
      mediaPicker.setAttribute("chrome", "ghost");
      mediaPicker.setAttribute("contenteditable", "false");
      mediaPicker.setAttribute("data-test-id", "paper-card-media-src");
      // Seed scope EXACTLY like the per-block / field picker: omit an empty attr so the
      // WC keeps its own defaults (dataset="production", no token → upload disabled).
      if (scope.dataset) mediaPicker.setAttribute("dataset", scope.dataset);
      if (scope.scopePrefix) mediaPicker.setAttribute("scope-prefix", scope.scopePrefix);
      if (scope.token) mediaPicker.setAttribute("data-token", scope.token);
      {
        const seedMedia = node.attrs && node.attrs.media;
        const seedSrc = (seedMedia && seedMedia.src) || "";
        mediaPicker.setAttribute("value", seedSrc);
      }

      const actionLabelInput = document.createElement("input");
      actionLabelInput.type = "text";
      actionLabelInput.className = "bp-canvas-card__input";
      actionLabelInput.placeholder = "action label";
      actionLabelInput.setAttribute("data-test-id", "paper-card-action-label");

      const actionHrefInput = document.createElement("input");
      actionHrefInput.type = "url";
      actionHrefInput.className = "bp-canvas-card__input";
      actionHrefInput.placeholder = "action href";
      actionHrefInput.setAttribute("data-test-id", "paper-card-action-href");

      // ACTION priority (the action-node.js editor, third control): a BINARY select the
      // reader collapses. "secondary" on a never-set action is a ZERO-op — the write
      // path drops the priority key rather than emitting priority:"secondary".
      const actionPrioritySelect = document.createElement("select");
      actionPrioritySelect.className = "bp-canvas-card__select";
      actionPrioritySelect.setAttribute("data-test-id", "paper-card-action-priority");
      for (const [value, text] of [
        ["primary", "Primary"],
        ["secondary", "Secondary"],
      ]) {
        const o = document.createElement("option");
        o.value = value;
        o.textContent = text;
        actionPrioritySelect.appendChild(o);
      }

      controls.append(
        mediaPicker,
        actionLabelInput,
        actionHrefInput,
        actionPrioritySelect
      );

      // media slot — the reader's BARE <img> (walk.ex image/1): the same inline
      // max-width:100%/height:auto rides the element, NO model-A media wrapper div
      // (model B). Read-only chrome, present-only (hidden when the slot is absent).
      const mediaImg = document.createElement("img");
      mediaImg.setAttribute("contenteditable", "false");
      mediaImg.style.maxWidth = "100%";
      mediaImg.style.height = "auto";

      // title slot — the reader's semantic <h2> (PdHeading, default level 2), here
      // an editable contentEditable island writing node.attrs.title.
      const titleEl = document.createElement("h2");
      titleEl.setAttribute("data-test-id", "paper-card-title");

      // body slot — the reader's <p>: the contentDOM IS the paragraph, so PM fills
      // the card's inline* content straight into the same classless <p> shape
      // card_html/2 emits (zero wrapper).
      const body = document.createElement("p");

      // action slot — the reader's PdButton anchor (walk.ex button/2). Read-only
      // chrome, present-only; label/href/priority are edited via the controls bar.
      const actionLink = document.createElement("a");
      actionLink.setAttribute("contenteditable", "false");

      // Reader order: media, title, body, action. Controls ride at the top (edit-only).
      dom.append(controls, mediaImg, titleEl, body, actionLink);

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

        // media slot (present-only): show the bare <img> iff a media element with
        // a src. width/height mirror PdImage's optional dims (the media element is
        // carried VERBATIM, so an API-authored width/height paints here too).
        const media = a.media;
        const src = (media && media.src) || "";
        if (src) {
          mediaImg.setAttribute("src", src);
          mediaImg.setAttribute("alt", (media && media.alt) || "");
          if (media && media.width != null) {
            mediaImg.setAttribute("width", String(media.width));
          } else {
            mediaImg.removeAttribute("width");
          }
          if (media && media.height != null) {
            mediaImg.setAttribute("height", String(media.height));
          } else {
            mediaImg.removeAttribute("height");
          }
          mediaImg.style.display = "";
        } else {
          mediaImg.style.display = "none";
        }
        // Keep the media picker in sync with an EXTERNAL attr change (an echo, an undo)
        // via its `value` PROPERTY setter (re-renders the preview; does NOT re-fire
        // bp-change). Only write when it differs so we never yank the picker the user
        // is mid-interaction with.
        if (mediaPicker.value !== src) mediaPicker.value = src;

        // action slot (present-only): show the PdButton anchor iff a label or
        // href. The class mirrors walk.ex button/2's binary priority collapse:
        // primary iff priority=="primary", else the plain secondary outline.
        const action = a.action;
        const label = (action && action.label) || "";
        const href = (action && action.href) || "";
        if (label || href) {
          actionLink.textContent = label;
          actionLink.setAttribute("href", href);
          actionLink.className =
            action && action.priority === "primary"
              ? "bp-button bp-button--primary"
              : "bp-button";
          actionLink.style.display = "";
        } else {
          actionLink.style.display = "none";
        }
        if (actionLabelInput.value !== label && document.activeElement !== actionLabelInput) {
          actionLabelInput.value = label;
        }
        if (actionHrefInput.value !== href && document.activeElement !== actionHrefInput) {
          actionHrefInput.value = href;
        }
        // Priority select — collapse the stored (tri-state, present-only) priority to
        // its binary display; a never-set action shows "secondary" (nil≡secondary).
        const priority = normalizeActionPriority(action && action.priority);
        if (actionPrioritySelect.value !== priority && document.activeElement !== actionPrioritySelect) {
          actionPrioritySelect.value = priority;
        }
        actionPrioritySelect.disabled = !editable;

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
      const commitTitleWrite = () => {
        const raw = titleEl.textContent || "";
        const nextTitle = raw === "" ? null : raw;
        writeAttr((attrs) => {
          if ((attrs.title || null) === nextTitle) return attrs;
          attrs.title = nextTitle;
          return attrs;
        });
      };
      const scheduleTitleWrite = () => {
        if (syncingTitle) return;
        if (!editor.isEditable) return;
        if (writeTimer) clearTimeout(writeTimer);
        writeTimer = setTimeout(() => {
          writeTimer = null;
          commitTitleWrite();
        }, 250);
      };
      const flushTitleWrite = () => {
        if (!writeTimer) return;
        clearTimeout(writeTimer);
        writeTimer = null;
        commitTitleWrite();
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
      dom.addEventListener("bp-flush-node", flushTitleWrite);

      // ── media control: read the picker's PARSED accessor (e.target.meta.url), with a
      // JSON-tolerant fallback (mediaUrlFromValue) over the bp-change STRING detail — the
      // exact precedent root.html.heex uses for field images. An asset-library pick emits
      // JSON {url,assetId}; extracting the URL here keeps attrs.media.src a bare URL so
      // the reader's <img src> is never the literal JSON blob. Map it to the media element
      // {type:"image",src} — NEVER write the raw value. An empty string is a CLEAR →
      // attrs.media=null → round-trips ABSENT (removal lands).
      const onMediaChange = (e) => {
        const meta = (e.target && e.target.meta) || {};
        const src = meta.url || mediaUrlFromValue((e.detail && e.detail.value) || "");
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
      mediaPicker.addEventListener("bp-change", onMediaChange);

      // ── action controls: set/clear the action element's label/href/priority.
      // type:"action" is ALWAYS present (no server normalize net — dropping it renders
      // nothing in email while tests stay green). priority is PRESENT-ONLY: written
      // only when "primary"; "secondary" drops the key (nil≡secondary zero-op), so a
      // never-set action never gains a spurious priority:"secondary".
      const writeAction = () => {
        const label = actionLabelInput.value || "";
        const href = actionHrefInput.value || "";
        const priority = actionPrioritySelect.value; // "primary" | "secondary"
        writeAttr((attrs) => {
          if (label === "" && href === "") {
            attrs.action = null; // clear → round-trips ABSENT
          } else {
            const prev = attrs.action && typeof attrs.action === "object" ? attrs.action : {};
            const next = { ...prev, type: "action", label, href };
            if (priority === "primary") {
              next.priority = "primary";
            } else {
              delete next.priority; // present-only: secondary ≡ nil, never emit it
            }
            attrs.action = next;
          }
          return attrs;
        });
      };
      actionLabelInput.addEventListener("change", writeAction);
      actionHrefInput.addEventListener("change", writeAction);
      actionPrioritySelect.addEventListener("change", writeAction);

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
          if (controls.contains(m.target)) return true; // controls (inc. the picker WC's own preview DOM) are attr writes
          if (mediaImg.contains(m.target)) return true; // media slot is attr-painted
          if (actionLink.contains(m.target)) return true; // action slot is attr-painted
          // Let PM handle mutations inside the editable body (contentDOM); ignore chrome.
          return !body.contains(m.target);
        },
        destroy: () => {
          if (writeTimer) clearTimeout(writeTimer);
          dom.removeEventListener("bp-flush-node", flushTitleWrite);
          titleEl.removeEventListener("input", onTitleInput);
          titleEl.removeEventListener("focus", onTitleFocus);
          titleEl.removeEventListener("blur", onTitleBlur);
          titleEl.removeEventListener("keydown", onTitleKeydown);
          mediaPicker.removeEventListener("bp-change", onMediaChange);
          actionLabelInput.removeEventListener("change", writeAction);
          actionHrefInput.removeEventListener("change", writeAction);
          actionPrioritySelect.removeEventListener("change", writeAction);
        },
      };
    };
  },
});
