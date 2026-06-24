// callout-node.js — Phase-4 Stage S3.2: the FIRST canvas CONTENT node-view.
//
// Brings the `callout` block INTO the continuous canvas as a ProseMirror CONTENT
// node (NOT an atom like S3.1's divider). A callout has an EDITABLE PROSE BODY
// plus non-editable CHROME (tone color + icon, an optional title, a collapsible
// fold). In the canvas its body becomes a real editable PM region that JOINS the
// run + cross-block selection, while the chrome renders AROUND it via a NodeView
// with a `contentDOM` hole. This is the node-view pattern S3.1 proved, but as a
// content node — so runs WIDEN to include callouts.
//
// ── CONTENT MODEL (resolved against the live render code — cite file:line) ────
//
//   compose.ex:155  compose_block(%{"type" => "callout"}) does:
//       body = %{"kind" => "PdText",
//                "children" => compose_inline_children(Map.get(b, "content", []))}
//   i.e. the callout's `content` array is fed straight to compose_inline_children
//   (INLINE composition) and wrapped in ONE PdText. walk.ex:782 callout/3 then
//   renders that single PdText body inline inside the tone <div>/<details>. So a
//   callout body is a SINGLE PROSE PARAGRAPH of INLINE runs — NOT nested blocks.
//   convert.js has NO callout path (confirmed: grep callout convert.js → none),
//   so the body↔portable-doc inline mapping is written in run-convert.js, reusing
//   convert.js's inlineArrayToTiptap / tiptapInlineToPd verbatim (the SAME inline
//   serializer the per-block paragraph editor uses — byte-identical round-trip).
//
//   => PM content expression: `inline*`. The body is one editable inline region,
//   exactly like a paragraph's content, so cross-block caret + FormatBubble marks
//   work in it for free.
//
// Why a CONTENT node (not an atom):
//   * group:"block"   — a top-level sibling of paragraph/heading/list, so it sits
//     in the SAME ProseMirror document the canvas mounts (doc content is block+).
//   * content:"inline*" + a contentDOM — the body is a real editable PM region
//     that joins the run's selection. The chrome (frame/icon/title/fold) lives
//     OUTSIDE the contentDOM in the node-view, so it is NOT PM-editable.
//   * NOT atom — unlike the divider, a callout HAS an interior to edit, so its
//     content changes must produce a patch-block (see run-convert.js calloutNode
//     handling). The chrome attrs (tone/title/collapsible/collapsed) ride node
//     attrs and also feed the patch on change.
//
// bpId / bpType / tone / title / collapsible / collapsed ride the node as attrs,
// carried through the DOM round-trip on data-* attributes — IDENTICAL id contract
// to BpAttrs (bp-attrs.js) + divider-node.js. data-bp-id is what makes getJSON()
// preserve the id run-convert.js keys by; the tone/title/collapsible/collapsed
// data-* attrs make a chrome edit (tone swap, fold toggle) survive the round-trip
// so run-convert.js can diff them into a patch.
//
// The `> [!type]` shorthand AUTHORING (typing `> [!warning]` to mint a callout)
// is OUT of S3.2 — that lives in the per-block index.js callout detector. A
// canvas-native authoring seam (slash menu / paste rule) is a LATER increment.
//
// DOM-aware (the NodeView builds real DOM nodes) but the Node SCHEMA object loads
// in plain Node (it imports ONLY @tiptap/core and references `document` lazily,
// inside the NodeView factory, which never runs in the pure-Node smoke harness).
// So __smoke.mjs can import run-convert.js (which references the callout TYPE
// only, never the NodeView) without a browser.

import { Node, mergeAttributes } from "@tiptap/core";

// The canonical Barkpark callout tones — the SAME set tone.js normalizeTone and
// the Elixir tone_palette (render/util.ex:55-60) understand. Kept here as the
// tone→{bg,fg,icon} chrome map so the canvas frame matches the rendered callout
// byte-for-byte on color. icon is a tiny inline glyph (no asset dependency),
// chosen per tone; the icon is CHROME (non-editable, decoration only).
//
// bg/fg are the EXACT hex pairs render/util.ex tone_palette returns, so a callout
// looks identical in the canvas and in the rendered article.
export const CALLOUT_TONES = {
  info: { bg: "#eff6ff", fg: "#1d4ed8", icon: "ℹ" },
  success: { bg: "#ecfdf5", fg: "#047857", icon: "✓" },
  warning: { bg: "#fffbeb", fg: "#92400e", icon: "⚠" },
  danger: { bg: "#fef2f2", fg: "#b91c1c", icon: "✕" },
  neutral: { bg: "#f3f4f6", fg: "#374151", icon: "•" },
};

// Resolve a (possibly unknown) tone to its chrome descriptor — mirrors the
// Elixir tone_palette/1 fallback (unknown ⇒ info) so the canvas never renders an
// undefined frame. This is the SAME fallback tone.js normalizeTone applies.
export function calloutToneChrome(tone) {
  return CALLOUT_TONES[tone] || CALLOUT_TONES.info;
}

export const Callout = Node.create({
  name: "callout",

  // A top-level block sibling (paragraph|heading|list|divider|callout) inside the
  // one canvas document. group:"block" lets it sit in the doc's `block+` content.
  group: "block",

  // The body is a SINGLE editable inline region — exactly a paragraph's content
  // model (see CONTENT MODEL note above; compose.ex:155 feeds content[] through
  // compose_inline_children → one inline PdText). NOT block+ / paragraph+.
  content: "inline*",

  // The body is editable; the chrome is rendered around it in the NodeView and is
  // NOT part of the PM content, so it is never directly selectable/editable.
  selectable: true,

  // A callout is a container, not a leaf — defining keeps PM from merging it into
  // an adjacent textblock on backspace-at-edge (so Backspace at the body start
  // lifts out of the callout rather than dissolving the chrome).
  defining: true,

  addAttributes() {
    return {
      // bpId — the portable-doc block id runToOps keys by. data-bp-id survives the
      // setContent->getJSON round-trip (same role as BpAttrs.bpId / divider bpId).
      bpId: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-bp-id"),
        renderHTML: (attrs) => (attrs.bpId ? { "data-bp-id": attrs.bpId } : {}),
      },
      // bpType — the original portable-doc block kind ("callout").
      bpType: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-bp-type"),
        renderHTML: (attrs) =>
          attrs.bpType ? { "data-bp-type": attrs.bpType } : {},
      },
      // tone — the callout's tone (info|success|warning|danger|neutral). Drives
      // the chrome color/icon. data-tone carries it through the round-trip so a
      // tone swap is diffable. default "info" mirrors the Elixir/normalizeTone
      // fallback (compose.ex:157 `Map.get(b, "tone") || "info"`).
      tone: {
        default: "info",
        parseHTML: (el) => el.getAttribute("data-tone") || "info",
        renderHTML: (attrs) => ({ "data-tone": attrs.tone || "info" }),
      },
      // title — the optional bold title. null when absent (compose.ex maybe_put
      // only threads it when present), so we render NO data-title for a null
      // title — a null title must round-trip as ABSENT, never "" (byte-fidelity).
      title: {
        default: null,
        parseHTML: (el) =>
          el.hasAttribute("data-title") ? el.getAttribute("data-title") : null,
        renderHTML: (attrs) =>
          attrs.title != null ? { "data-title": attrs.title } : {},
      },
      // collapsible — whether the fold affordance is offered. Boolean; only ever
      // true in article mode (compose.ex gates it). data-collapsible="true" when
      // set; absent otherwise so a non-collapsible callout round-trips ABSENT.
      collapsible: {
        default: false,
        parseHTML: (el) => el.getAttribute("data-collapsible") === "true",
        renderHTML: (attrs) =>
          attrs.collapsible ? { "data-collapsible": "true" } : {},
      },
      // collapsed — the current fold state (only meaningful when collapsible).
      // The fold toggle in the NodeView flips this attr; run-convert.js diffs it
      // into a patch carrying `collapsed`. Absent when false (byte-fidelity).
      collapsed: {
        default: false,
        parseHTML: (el) => el.getAttribute("data-collapsed") === "true",
        renderHTML: (attrs) =>
          attrs.collapsed ? { "data-collapsed": "true" } : {},
      },
    };
  },

  // Parse a rendered callout shell back into a callout node (so setContent of the
  // node-view's own DOM round-trips). The body inline content is parsed from the
  // contentDOM child (data-callout-body). The data-* attrs are read by
  // addAttributes' parseHTML above.
  parseHTML() {
    return [{ tag: "div[data-bp-type='callout']" }];
  },

  // A schema-level fallback render (used when NO node-view is mounted — e.g. the
  // pure-Node round-trip, or a non-editable export). The node-view (below)
  // OVERRIDES this in the live editor; this keeps the schema self-describing and
  // gives parseHTML a target. The `0` is the content hole for the inline body.
  renderHTML({ HTMLAttributes }) {
    return [
      "div",
      mergeAttributes(HTMLAttributes, { "data-bp-type": "callout" }),
      ["div", { "data-callout-body": "" }, 0],
    ];
  },

  // ── the NodeView: tone-framed CHROME around an editable contentDOM body ──────
  //
  // Builds:
  //   <div class="bp-canvas-callout" data-tone=…>      ← frame (tone bg + fg, left border)
  //     <div class="bp-canvas-callout-head">           ← chrome (NOT editable)
  //       <span icon>  <strong title>  <button fold>   ← icon, optional title, fold toggle
  //     <div class="bp-canvas-callout-body">  ← contentDOM hole (editable inline body)
  //
  // The head + frame are CHROME: contentEditable=false on the head so clicks there
  // never put a caret in the chrome; only the body (contentDOM) is editable. The
  // fold toggle dispatches a PM transaction flipping the `collapsed` attr — which
  // run-convert.js diffs into a patch-block carrying `collapsed`.
  addNodeView() {
    return ({ node, editor, getPos }) => {
      const dom = document.createElement("div");
      dom.className = "bp-canvas-callout";
      dom.setAttribute("data-bp-type", "callout");

      // The chrome HEAD: icon + optional title + (when collapsible) a fold toggle.
      // contentEditable=false so the head is inert to the caret — it is decoration
      // around the editable body, mirroring the divider atom's non-editable nature
      // but here only the CHROME is non-editable (the body below IS editable).
      const head = document.createElement("div");
      head.className = "bp-canvas-callout-head";
      head.contentEditable = "false";

      const icon = document.createElement("span");
      icon.className = "bp-canvas-callout-icon";

      const titleEl = document.createElement("strong");
      titleEl.className = "bp-canvas-callout-title";

      // The fold toggle — only shown when collapsible. Clicking it flips the
      // node's `collapsed` attr via a PM transaction; PM re-renders the node-view
      // (update() below reflects the new state) and onUpdate fires → run-convert.js
      // emits a patch-block carrying the new `collapsed`.
      const fold = document.createElement("button");
      fold.type = "button";
      fold.className = "bp-canvas-callout-fold";
      fold.contentEditable = "false";
      fold.addEventListener("mousedown", (e) => {
        // mousedown (not click) + preventDefault so the editor never loses its
        // selection / blurs when the chrome button is pressed.
        e.preventDefault();
        e.stopPropagation();
        if (typeof getPos !== "function") return;
        const pos = getPos();
        if (pos == null) return;
        const cur = editor.state.doc.nodeAt(pos);
        const nextCollapsed = !(cur && cur.attrs && cur.attrs.collapsed);
        editor
          .chain()
          .command(({ tr }) => {
            tr.setNodeMarkup(pos, undefined, {
              ...cur.attrs,
              collapsed: nextCollapsed,
            });
            return true;
          })
          .run();
      });

      head.appendChild(icon);
      head.appendChild(titleEl);
      head.appendChild(fold);

      // The editable BODY: the contentDOM hole PM fills with the inline content.
      const body = document.createElement("div");
      body.className = "bp-canvas-callout-body";

      dom.appendChild(head);
      dom.appendChild(body);

      // Paint the chrome from the node's current attrs. Re-run on every update()
      // so a tone swap / title edit / fold toggle reflects immediately.
      const paint = (n) => {
        const tone = (n.attrs && n.attrs.tone) || "info";
        const chrome = calloutToneChrome(tone);
        dom.setAttribute("data-tone", tone);
        dom.style.borderLeft = "4px solid " + chrome.fg;
        dom.style.background = chrome.bg;
        dom.style.color = chrome.fg;
        icon.textContent = chrome.icon;

        const title = n.attrs && n.attrs.title;
        if (title != null && title !== "") {
          titleEl.textContent = title;
          titleEl.style.display = "";
        } else {
          titleEl.textContent = "";
          titleEl.style.display = "none";
        }

        const collapsible = !!(n.attrs && n.attrs.collapsible);
        const collapsed = !!(n.attrs && n.attrs.collapsed);
        if (collapsible) {
          fold.style.display = "";
          fold.textContent = collapsed ? "▸" : "▾";
          fold.setAttribute("aria-expanded", collapsed ? "false" : "true");
          // Collapsed hides the body (the fold affordance); expanded shows it.
          body.style.display = collapsed ? "none" : "";
        } else {
          fold.style.display = "none";
          body.style.display = "";
        }
      };

      paint(node);

      return {
        dom,
        // contentDOM is the editable body hole — PM manages the inline content
        // inside it. The chrome (head) is OUTSIDE contentDOM so it is never edited.
        contentDOM: body,
        // Re-render the chrome when the node's attrs change (tone/title/fold).
        // Return false for a different node type so PM rebuilds the view.
        update: (updated) => {
          if (updated.type.name !== "callout") return false;
          paint(updated);
          return true;
        },
        // PM must NOT treat clicks/mutations in the chrome head as content edits.
        ignoreMutation: (mutation) => {
          // Let PM handle mutations inside the editable body (contentDOM); ignore
          // everything in the chrome head (icon/title/fold are view-managed).
          if (mutation.type === "selection") return false;
          return !body.contains(mutation.target);
        },
      };
    };
  },
});
