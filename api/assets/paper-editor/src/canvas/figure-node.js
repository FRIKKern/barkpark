// figure-node.js — the SERVER-PAINTED read-only-child + editable-caption ATOM.
//
// Brings the generic `figure` block INTO the continuous canvas as a ProseMirror
// ATOM (`bpFigure`) whose CHILD (typically an image; also code / diagram / heading)
// rides VERBATIM/immutable on a `bpChild` attr and is PAINTED read-only by the
// reader's OWN producer, while its `caption` is the SOLE edit affordance (a non-PM
// <input> island, exactly like diagram-node.js's caption chrome).
//
// ── WHY AN ATOM (server-painted child), NOT a container ───────────────────────
//
// The figure child is TYPICALLY AN IMAGE, and `image` has NO editable canvas node
// (it is a run BOUNDARY today — absent from every @canvas_types set). A "truly
// editable child" PM content model would only help `code` children, still degrade
// the common image child to a blank node, and need a RESTRICTED content expression
// to forbid v1 nesting. The atom + server-paint path instead renders ANY child
// (image / code / diagram / heading) BYTE-EXACT for free via the reader's own
// producer (shared/paper.ex push_block_renders → the SHIPPED `bp:block-html` hook),
// and structurally CANNOT nest by construction — the child NEVER enters the PM doc,
// so a figure atom can never contain another canvas node (the v1 no-nesting rule is
// satisfied for free, mirroring the Fleet atom's key advantage over a content
// expression). It reuses the shipped fleet paint pipeline (embed-node.js:Fleet) +
// the shipped diagram caption chrome (diagram-node.js) almost verbatim.
//
// ── THE CHILD PAINT HOLE (reuses the shipped fleet hook, ZERO hook change) ─────
//
// The node-view builds the reader `<figure style="margin:1.6rem 0">` wrapper
// containing (1) a `[data-bp-fleet-body]` paint hole keyed by `[data-bp-fleet-id]`
// — the EXACT selector the shipped `_paintFleet` hook (root.html.heex) targets, so
// the server injects the CHILD-only reader HTML with NO hook change — and (2) an
// editable `<figcaption>`-styled input, the ONLY edit affordance. The input is a
// SIBLING of the paint hole, so the hook's innerHTML write never touches it.
//
// ── THE CAPTION ISLAND (ported from diagram-node.js) ──────────────────────────
//
// The caption <input> is INVISIBLE to ProseMirror (stopEvent / ignoreMutation), so a
// keystroke never becomes a PM transaction (no caret jump, no doc split). On `input`
// (debounced DEBOUNCE_MS) the view writes the new caption back to the node's
// `caption` attr via setNodeMarkup → onUpdate → run-convert emits ONE
// patch-block{caption}. Empty → null (byte-fidelity, mirrors diagram): an empty
// caption round-trips as ABSENT and the resting-chrome gate hides its ghost input.
//
// ACCEPTED divergence (same class as diagram's caption): the editor shows the RAW
// caption in the input; the reader applies `Figures.figcaption_inner` — a bold
// "Figure N." run-in — AND (via render_block) resolves ref-title / code-label on the
// child. Recorded in the PR parity matrix as a deliberate exception.
//
// DOM-aware (the NodeView builds real DOM) but the Node SCHEMA object loads in plain
// Node: it imports ONLY @tiptap/core (+ the pure contract.js helpers) and references
// `document` lazily inside addNodeView, which never runs in the pure-Node harness.
// So __figure.test.mjs imports run-convert.js (which names only the "bpFigure" TYPE,
// never this NodeView) without a browser.

import { Node, mergeAttributes } from "@tiptap/core";
import { DEBOUNCE_MS, configControlHidden } from "../contract.js";
import { wireAtomAccessibility } from "./embed-node.js";

// The TipTap node NAME is `bpFigure`; the portable-doc `bpType` stays "figure"
// (run-convert.js maps a block.type "figure" to this node and back). NO StarterKit
// node is disabled: StarterKit ships no `figure` node, and we claim ONLY the typed
// `<figure data-bp-type='figure'>` wrapper (diagram / asciicast also emit a bare
// `<figure>`, so a bare claim would be ambiguous on paste/setContent).
export const BP_FIGURE_NODE_NAME = "bpFigure";

export const Figure = Node.create({
  name: BP_FIGURE_NODE_NAME,

  // A top-level block sibling inside the ONE canvas document (doc content is
  // block+), so it joins the run.
  group: "block",

  // An atom leaf: NO PM interior. The child is server-painted (read-only) and the
  // caption is a non-PM island, so PM treats the whole node as one indivisible unit
  // (caret-select + Backspace-of-a-selected-atom come free, like the fleet/diagram).
  // An atom holds NO PM children — this is what structurally dodges the v1
  // no-nesting problem: a figure atom CANNOT contain another canvas node.
  atom: true,

  // Clickable/selectable so the caret can select the whole atom and delete it.
  selectable: true,

  // A leaf container, not a textblock — defining keeps PM from merging an adjacent
  // textblock into it on backspace-at-edge.
  defining: true,

  addAttributes() {
    return {
      // bpId — the portable-doc block id runToOps keys by (data-bp-id survives the
      // setContent->getJSON round-trip) AND the paint-hole selector key.
      bpId: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-bp-id"),
        renderHTML: (attrs) => (attrs.bpId ? { "data-bp-id": attrs.bpId } : {}),
      },
      // bpType — the original portable-doc block kind ("figure").
      bpType: {
        default: "figure",
        parseHTML: (el) => el.getAttribute("data-bp-type") || "figure",
        renderHTML: (attrs) =>
          attrs.bpType ? { "data-bp-type": attrs.bpType } : {},
      },
      // caption — the ONLY editable datum. null when absent/empty: render
      // data-caption ONLY when non-null-non-"" so an empty caption round-trips as
      // ABSENT (byte-fidelity, mirrors diagram-node.js). The canonical compare in
      // run-convert.js treats ""/null/absent EQUAL → a no-op edit emits zero ops.
      caption: {
        default: null,
        parseHTML: (el) =>
          el.hasAttribute("data-caption") ? el.getAttribute("data-caption") : null,
        renderHTML: (attrs) =>
          attrs.caption != null && attrs.caption !== ""
            ? { "data-caption": attrs.caption }
            : {},
      },
      // bpChild — the deep-cloned CHILD block, carried VERBATIM/immutable in v1 (the
      // bpOpaque verbatim-carry pattern, but for the single child). It is the SOLE
      // source for the child paint (server-side) + the child on the reconstructed
      // block. data-bp-child holds it as a JSON string so it survives the
      // setContent->getJSON cycle. Carrying ONLY the child (NOT the whole figure on a
      // fleet-style bpBlock) keeps the editable caption attr the single source of
      // truth, so echo-equality compares child-only (no stale-caption misdetect).
      bpChild: {
        default: null,
        parseHTML: (el) => {
          const raw = el.getAttribute("data-bp-child");
          if (raw == null || raw === "") return null;
          try {
            return JSON.parse(raw);
          } catch (_) {
            return null;
          }
        },
        renderHTML: (attrs) =>
          attrs.bpChild != null
            ? { "data-bp-child": JSON.stringify(attrs.bpChild) }
            : {},
      },
    };
  },

  // Claim ONLY the typed wrapper — NOT bare `<figure>` (diagram / asciicast also emit
  // `<figure>`; a bare claim is ambiguous on paste/setContent).
  parseHTML() {
    return [{ tag: "figure[data-bp-type='figure']" }];
  },

  // Schema-level fallback render (no node-view mounted — pure-Node round-trip /
  // non-editable export). All data rides the typed attrs; data-bp-type is the parse
  // anchor. The node-view (below) OVERRIDES this in the live editor.
  renderHTML({ HTMLAttributes }) {
    return ["figure", mergeAttributes(HTMLAttributes, { "data-bp-type": "figure" })];
  },

  // ── the NodeView: a reader <figure> wrapping a CHILD paint hole + caption input ─
  //
  // Mirrors figure_html's article structure (compose.ex figure_html/3):
  //   <figure class="bp-canvas-readonly bp-canvas-figure" data-bp-type="figure"
  //           data-bp-fleet-id="<bpId>" contenteditable="false" style="margin:1.6rem 0">
  //     <div class="bp-paper-surface" data-bp-fleet-body>       ← CHILD paint hole
  //       <div class="bp-canvas-readonly-chip">Figure</div>     ← honest loading chip
  //     </div>
  //     <figcaption class="bp-canvas-figure-caption">
  //       <input class="bp-canvas-figure-caption-input" …/>     ← the ONLY edit surface
  //     </figcaption>
  //   </figure>
  //
  // data-bp-fleet-id / data-bp-fleet-body are reused EXACTLY so the SHIPPED
  // `_paintFleet` hook paints the child with ZERO hook change. The caption input is a
  // SIBLING of the paint hole, so the hook's innerHTML write never touches it.
  addNodeView() {
    return ({ node, editor, getPos }) => {
      const bpId = (node.attrs && node.attrs.bpId) || "";

      const dom = document.createElement("figure");
      dom.className = "bp-canvas-readonly bp-canvas-figure";
      dom.setAttribute("data-bp-type", "figure");
      dom.setAttribute("data-bp-fleet-id", bpId);
      dom.setAttribute("contenteditable", "false");
      dom.setAttribute("data-test-id", "paper-figure");
      // Restore the reader figure margin (figure_html article margin:1.6rem 0),
      // overriding the .bp-canvas-readonly 1em; also set inline so it holds before
      // the stylesheet loads.
      dom.style.margin = "var(--bp-air-figure, 1.6rem) 0 0";
      dom.style.marginInline = "var(--bp-evidence-pull, 0px)";
      dom.style.width = "var(--bp-evidence-width, 100%)";
      dom.style.boxSizing = "border-box";

      // The CHILD paint hole: a `.bp-paper-surface` sink (the injected reader HTML is
      // styled by the ONE canonical stylesheet exactly as /papers renders it — D8),
      // keyed by data-bp-fleet-id, filled by the server hook (`bp:block-html`). Until
      // that HTML arrives it shows an honest loading chip (never a blank strip).
      const body = document.createElement("div");
      body.className = "bp-paper-surface";
      body.setAttribute("data-bp-fleet-body", "");
      const chip = document.createElement("div");
      chip.className = "bp-canvas-readonly-chip";
      chip.textContent = "Figure";
      body.appendChild(chip);
      dom.appendChild(body);

      // The editable caption: a <figcaption> reader tag wrapping the edit <input>.
      const figcaption = document.createElement("figcaption");
      figcaption.className = "bp-canvas-figure-caption";
      const captionInput = document.createElement("input");
      captionInput.type = "text";
      captionInput.className = "bp-canvas-figure-caption-input";
      captionInput.placeholder = "caption";
      // Accessible name that survives the resting-chrome hide (a placeholder is only a
      // fallback name, and it is invisible while the control is hidden).
      captionInput.setAttribute("aria-label", "figure caption");
      captionInput.setAttribute("contenteditable", "false");
      // Inline styles mirroring the reader <figcaption>, which since
      // papers/captions-floor is styled by ONE class (.bp-figcaption in
      // paper-surface.css) rather than by inline styles: serif, ROMAN, 0.9rem/1.45,
      // --paper-ink-soft. An <input> inherits none of that, so the values are copied
      // here + an input reset. The stylesheet carries the same values via
      // .bp-canvas-figure-caption-input; the inline copy holds before CSS loads.
      captionInput.style.display = "block";
      captionInput.style.width = "100%";
      captionInput.style.boxSizing = "border-box";
      captionInput.style.border = "none";
      captionInput.style.background = "transparent";
      captionInput.style.padding = "0";
      captionInput.style.margin = "0";
      captionInput.style.color = "var(--paper-ink-soft, #6a6a6a)";
      captionInput.style.fontSize = "0.9rem";
      captionInput.style.lineHeight = "1.45";
      captionInput.style.fontFamily =
        "var(--paper-font-serif, 'Iowan Old Style', Palatino, Georgia, serif)";
      figcaption.appendChild(captionInput);
      dom.appendChild(figcaption);

      // Resting-chrome gate (ported from diagram-node.js): the empty caption input
      // hides at rest and reveals only while the frame is hovered or focus is inside
      // it (both gated on editability — view mode surfaces nothing), so an idle figure
      // atom carries no "caption" ghost chrome. Toggling the <figcaption> (not just the
      // input) hides the whole caption row.
      let hovered = false;
      let focused = false;
      const syncChrome = () => {
        const hide = configControlHidden({
          value: captionInput.value,
          hovered: hovered && editor.isEditable,
          focused: focused && editor.isEditable,
        });
        figcaption.style.display = hide ? "none" : "";
      };

      const paint = (n) => {
        const caption = (n.attrs && n.attrs.caption) || "";
        if (captionInput.value !== caption) captionInput.value = caption;
        captionInput.readOnly = !editor.isEditable;
        syncChrome();
      };

      const onEnter = () => {
        hovered = true;
        syncChrome();
      };
      const onLeave = () => {
        hovered = false;
        syncChrome();
      };
      const onFocusIn = () => {
        focused = true;
        syncChrome();
      };
      const onFocusOut = (e) => {
        // Focus-within guard (diagram-node.js): focusout fires BEFORE the next element
        // receives focus; hiding here mid-Tab would drop focus to <body>. relatedTarget
        // is the element gaining focus — when it is still inside this atom, keep the
        // chrome revealed and let the subsequent focusin confirm it.
        if (e && e.relatedTarget && dom.contains(e.relatedTarget)) return;
        focused = false;
        syncChrome();
      };
      dom.addEventListener("mouseenter", onEnter);
      dom.addEventListener("mouseleave", onLeave);
      dom.addEventListener("focusin", onFocusIn);
      dom.addEventListener("focusout", onFocusOut);

      paint(node);

      // pdd-t12c a11y parity: a tab stop with a role + accessible name ("Figure") and
      // Enter/Space → NodeSelection → Backspace deletes. The e.target !== dom guard
      // (inside wireAtomAccessibility) keeps a caption keystroke from triggering
      // atom-select. The child is passed for the (never-set) locked-state announcement.
      wireAtomAccessibility(dom, {
        block: (node.attrs && node.attrs.bpChild) || {},
        chipText: "Figure",
        editor,
        getPos,
      });

      // Debounced write-back of the caption to the node attr. setNodeMarkup changes
      // ONLY the attr (the node stays the same atom in the same place), so onUpdate →
      // run-convert emits ONE patch-block{caption}. The child is NEVER touched.
      let writeTimer = null;
      const commitCaptionWrite = () => {
        if (typeof getPos !== "function") return;
        const pos = getPos();
        if (pos == null) return;
        const cur = editor.state.doc.nodeAt(pos);
        if (!cur) return;
        // Empty string → null so an absent caption round-trips as ABSENT (the
        // canonical compare treats ""/null/absent equal → a no-op edit emits nothing).
        const raw = captionInput.value;
        const nextCaption = raw === "" ? null : raw;
        if ((cur.attrs.caption || null) === nextCaption) return;
        editor
          .chain()
          .command(({ tr }) => {
            tr.setNodeMarkup(pos, undefined, { ...cur.attrs, caption: nextCaption });
            return true;
          })
          .run();
      };
      const scheduleWrite = () => {
        if (!editor.isEditable) return;
        if (writeTimer) clearTimeout(writeTimer);
        writeTimer = setTimeout(() => {
          writeTimer = null;
          commitCaptionWrite();
        }, DEBOUNCE_MS);
      };
      const flushCaptionWrite = () => {
        if (!writeTimer) return;
        clearTimeout(writeTimer);
        writeTimer = null;
        commitCaptionWrite();
      };

      captionInput.addEventListener("input", scheduleWrite);
      // Keep the resting-chrome gate in step as the caption is typed / cleared.
      captionInput.addEventListener("input", syncChrome);
      dom.addEventListener("bp-flush-node", flushCaptionWrite);

      return {
        dom,
        // NO contentDOM — this is an atom; the child is server-painted and the caption
        // lives on the `caption` attr, edited entirely outside ProseMirror.

        // KEEP the existing DOM across attr updates (echo / undo): repaint the caption
        // + chrome, never rebuild — so the server-painted child HTML in the hole is
        // untouched (no flash back to the loading chip). Return false for a different
        // node type so PM rebuilds the view.
        update: (updated) => {
          if (updated.type.name !== BP_FIGURE_NODE_NAME) return false;
          paint(updated);
          return true;
        },

        // THE ISLAND CONTRACT: PM must NOT turn the caption input's OR the paint hole's
        // events into transactions (a caption keystroke never splits the doc; a child
        // click only selects the atom).
        stopEvent: () => true,
        // PM must NOT read the interior's DOM mutations into the document — the hook
        // mutates the paint hole's innerHTML directly and PM must ignore it.
        ignoreMutation: () => true,

        destroy: () => {
          if (writeTimer) clearTimeout(writeTimer);
          dom.removeEventListener("bp-flush-node", flushCaptionWrite);
          captionInput.removeEventListener("input", scheduleWrite);
          captionInput.removeEventListener("input", syncChrome);
          dom.removeEventListener("mouseenter", onEnter);
          dom.removeEventListener("mouseleave", onLeave);
          dom.removeEventListener("focusin", onFocusIn);
          dom.removeEventListener("focusout", onFocusOut);
        },
      };
    };
  },
});
