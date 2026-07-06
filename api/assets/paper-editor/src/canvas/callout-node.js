// callout-node.js — Phase-4 Stage S3.2: the FIRST canvas CONTENT node-view.
//
// Brings the `callout` block INTO the continuous canvas as a ProseMirror CONTENT
// node (NOT an atom like S3.1's divider). A callout has an EDITABLE PROSE BODY
// plus non-editable CHROME (a run-in bold title, or a native <summary> fold). In
// the canvas its body becomes a real editable PM region that JOINS the run +
// cross-block selection, while the chrome renders AROUND it via a NodeView with a
// `contentDOM` hole. This is the node-view pattern S3.1 proved, but as a content
// node — so runs WIDEN to include callouts.
//
// ── VIEW⇄EDIT PARITY (loop-epic/parity-callout, charter S2+S3+S4) ────────────
//
// The node-view root carries the READER's own classes — `bp-callout` +
// `bp-callout--<tone>` — so it is painted by the reader's OWN
// `.bp-paper-surface .bp-callout*` rules through the ancestor cascade (the canvas
// mounts in LIGHT DOM inside `<main class="bp-paper-shell bp-paper-surface">` with
// paper-surface.css inlined; view_edit_parity_test.exs:230-241). Tone colour +
// the dark-mode token swap come for FREE — ZERO editor CSS, ZERO drift. `bp-canvas-
// callout` stays only as a thin edit-only layout hook. The embedder bundle
// (styles.css) has no `.bp-paper-surface` ancestor, so it carries a hand-copied
// `.bp-paper-editor-body .bp-callout*` mirror (blessed standalone-host pattern).
//
// The structure mirrors walk.ex `callout/3` (article) byte-for-byte in shape:
//   * non-collapsible → <div class="bp-callout bp-callout--<tone>"> with a RUN-IN
//     <strong>title</strong> + a space + the inline body (reader has no body
//     wrapper; the editable contentDOM is displayed inline to approximate it).
//   * collapsible → native <details[ open]><summary class="bp-callout__summary">
//     <div class="bp-callout__body"> — the SAME tags the reader emits
//     (collapsible_callout_article/3). `open` reflects `!collapsed`. No icon.
//
// ── CONTENT MODEL (resolved against the live render code — cite file:line) ────
//
//   compose.ex:155  compose_block(%{"type" => "callout"}) does:
//       body = %{"kind" => "PdText",
//                "children" => compose_inline_children(Map.get(b, "content", []))}
//   i.e. the callout's `content` array is fed straight to compose_inline_children
//   (INLINE composition) and wrapped in ONE PdText. walk.ex callout/3 then renders
//   that single PdText body inline inside the tone <div>/<details>. So a callout
//   body is a SINGLE PROSE PARAGRAPH of INLINE runs — NOT nested blocks.
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
//     that joins the run's selection. The chrome (frame/title/summary) lives
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

// Tone → modifier class, mirroring walk.ex `callout_tone_class/1` (walk.ex:
// 1321-1326) EXACTLY: the five knowns pass through, anything else → info. This is
// DELIBERATELY not the tone.js alias-normalizer — that alias-expands note→info /
// warn→warning / error→danger, which the reader does NOT do, so reusing it would
// silently drift the tone (and thus the --bp-tone-<tone>-* token pair) on an
// aliased input. Colour is bound entirely through the `bp-callout--<tone>` class
// resolving `--bp-tone-<tone>-{bg,fg}` (light + dark) — NO inline paint, NO icon.
export function calloutToneClass(tone) {
  return ["success", "warning", "danger", "neutral", "info"].includes(tone)
    ? tone
    : "info";
}

// Summary text for a collapsed <details>, mirroring walk.ex `callout_summary/1`
// + `tone_label/1` (walk.ex:1349-1361): the title when present, else the tone
// label so the disclosure is never empty. Uses the RAW tone (unknown → "Info"),
// exactly as tone_label/1 does.
function toneLabel(tone) {
  switch (tone) {
    case "success":
      return "Success";
    case "warning":
      return "Warning";
    case "danger":
      return "Danger";
    case "neutral":
      return "Neutral";
    default:
      return "Info";
  }
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
      // the tone card colour. data-tone carries it through the round-trip so a
      // tone swap is diffable. default "info" mirrors the Elixir tone fallback
      // (compose.ex:157 `Map.get(b, "tone") || "info"`).
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

  // ── the NodeView: reader-shaped tone card around an editable contentDOM body ─
  //
  // Non-collapsible builds (mirrors walk.ex callout/3 :article):
  //   <div class="bp-canvas-callout bp-callout bp-callout--<tone>" data-bp-type>
  //     <strong>title</strong>" "            ← RUN-IN chrome (NOT editable)
  //     <div class="bp-callout__body">…</div> ← contentDOM hole (editable inline)
  //
  // Collapsible builds (mirrors walk.ex collapsible_callout_article/3):
  //   <details[ open] class="bp-canvas-callout bp-callout bp-callout--<tone>" …>
  //     <summary class="bp-callout__summary">title|toneLabel</summary>  ← chrome
  //     <div class="bp-callout__body">…</div>                ← contentDOM (editable)
  //
  // Colour rides ENTIRELY on the `bp-callout--<tone>` class (reader cascade +
  // hand-copied embedder mirror) — no inline background/border/color, no icon.
  // The <summary> is natively keyboard/hover reachable (rule 5 for free) and the
  // native <details> disclosure replaces the old edit-only <button> fold.
  addNodeView() {
    return ({ node, editor, getPos }) => {
      const isCollapsible = !!(node.attrs && node.attrs.collapsible);
      const toneClass = calloutToneClass((node.attrs && node.attrs.tone) || "info");

      // The editable BODY: the contentDOM hole PM fills with the inline content.
      // `bp-callout__body` gets the reader's body semantics; the embedder mirror
      // + a `.bp-canvas-callout .bp-callout__body{display:inline}` rule keep the
      // run-in title and body sharing a line (the reader has no body wrapper).
      const body = document.createElement("div");
      body.className = "bp-callout__body";

      let dom;
      let titleEl = null;
      let spaceNode = null;
      let summary = null;
      // Guards the paint→`dom.open` write from re-entering the toggle listener.
      let syncingOpen = false;

      if (isCollapsible) {
        // ── COLLAPSIBLE: native <details>/<summary>, reader-shaped. ──
        dom = document.createElement("details");
        dom.className = `bp-canvas-callout bp-callout bp-callout--${toneClass}`;
        dom.setAttribute("data-bp-type", "callout");

        summary = document.createElement("summary");
        summary.className = "bp-callout__summary";
        summary.contentEditable = "false";

        dom.appendChild(summary);
        dom.appendChild(body);

        // Native disclosure toggle → sync `collapsed`. Re-entrancy-guarded: only
        // dispatch when the DOM open state actually disagrees with the node attr,
        // and never while paint() is the one writing dom.open.
        dom.addEventListener("toggle", () => {
          if (syncingOpen) return;
          if (typeof getPos !== "function") return;
          const pos = getPos();
          if (pos == null) return;
          const cur = editor.state.doc.nodeAt(pos);
          if (!cur) return;
          const nextCollapsed = !dom.open;
          if (nextCollapsed === !!cur.attrs.collapsed) return;
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
      } else {
        // ── NON-COLLAPSIBLE: <div> tone card with a RUN-IN <strong> title. ──
        dom = document.createElement("div");
        dom.className = `bp-canvas-callout bp-callout bp-callout--${toneClass}`;
        dom.setAttribute("data-bp-type", "callout");

        // Run-in title chrome: <strong> + a literal space, both inert to the
        // caret. Hidden (display:none / empty space) when there is no title, so a
        // live title edit toggles without adding/removing nodes.
        titleEl = document.createElement("strong");
        titleEl.contentEditable = "false";
        spaceNode = document.createTextNode("");

        dom.appendChild(titleEl);
        dom.appendChild(spaceNode);
        dom.appendChild(body);
      }

      // Paint the chrome from the node's current attrs. Re-run on every update()
      // so a tone swap / title edit / fold toggle reflects immediately.
      const paint = (n) => {
        const tc = calloutToneClass((n.attrs && n.attrs.tone) || "info");
        dom.className = `bp-canvas-callout bp-callout bp-callout--${tc}`;

        const title = n.attrs && n.attrs.title;
        const hasTitle = title != null && title !== "";

        if (isCollapsible) {
          summary.textContent = hasTitle
            ? title
            : toneLabel(n.attrs && n.attrs.tone);
          // Reflect `open = !collapsed` without re-entering the toggle listener.
          syncingOpen = true;
          dom.open = !(n.attrs && n.attrs.collapsed);
          syncingOpen = false;
        } else if (hasTitle) {
          titleEl.textContent = title;
          titleEl.style.display = "";
          spaceNode.textContent = " ";
        } else {
          titleEl.textContent = "";
          titleEl.style.display = "none";
          spaceNode.textContent = "";
        }
      };

      paint(node);

      return {
        dom,
        // contentDOM is the editable body hole — PM manages the inline content
        // inside it. The chrome (title/summary) is OUTSIDE contentDOM so it is
        // never edited.
        contentDOM: body,
        // Re-render the chrome when the node's attrs change (tone/title/fold).
        // Return false — forcing PM to rebuild the view — for a different node
        // type OR a collapsible flip (which changes the root TAG div↔details).
        update: (updated) => {
          if (updated.type.name !== "callout") return false;
          if (!!(updated.attrs && updated.attrs.collapsible) !== isCollapsible)
            return false;
          paint(updated);
          return true;
        },
        // PM must NOT treat chrome mutations as content edits.
        ignoreMutation: (mutation) => {
          // Let PM manage selection.
          if (mutation.type === "selection") return false;
          // The native <details> `open` toggle mutates an attribute on the root —
          // it is a disclosure, not a content edit, so ignore it.
          if (mutation.type === "attributes" && mutation.target === dom)
            return true;
          // Let PM handle mutations inside the editable body (contentDOM); ignore
          // everything in the chrome (title/summary live outside body).
          return !body.contains(mutation.target);
        },
      };
    };
  },
});
