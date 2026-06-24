// diagram-node.js — Phase-4 Stage S3.4: the SECOND canvas ATOM-WITH-ATTR node-view,
// mirroring S3.3 code-node.js ALMOST VERBATIM.
//
// Brings the `diagram` block INTO the continuous canvas as a ProseMirror ATOM whose
// Mermaid SOURCE rides in an ATTR (`source`) and is edited by a NON-PM <textarea>
// island — the stopEvent/ignoreMutation contenteditable-island pattern, identical to
// code-node.js. The diagram reuses the code shape with TWO field differences:
//   * the body field is `source` (the Mermaid text), NOT `value`;
//   * there is an extra OPTIONAL `caption` field (a short figure label) where the
//     code node had `lang`.
//
// ── CONTENT MODEL (resolved against the live persist code — cite file:line) ───
//
//   blocks.ex:238  default_block("diagram") → %{type:"diagram", source:"", caption:""}
//   blocks.ex:47   build_block_patch(%{"type"=>"diagram"}, params):
//       %{"source" => params["source"] || "", "caption" => params["caption"] || ""}
//   compose.ex:224 compose_block(%{"type"=>"diagram"}) reads Map.get(b,"source","")
//       and Map.get(b,"caption","").
//   So the diagram block is { id, type:"diagram", source:"<text>", caption:"<short>" }
//   — a PLAIN STRING `source` (the raw Mermaid text, NOT inline runs, NOT marks) plus
//   a `caption` string. v1 edits the SOURCE in the textarea — NO live Mermaid preview
//   in the editor (a later polish; the VIEW-mode render via walk.ex/figures.ex is
//   unchanged).
//
//   NOTE the caption asymmetry vs the code node's `lang`: the STORED diagram always
//   carries `caption` (default_block seeds "" and build_block_patch writes it
//   UNCONDITIONALLY — NOT via put_if_present, UNLIKE code's lang which is dropped on
//   nil/""). But for the CANVAS round-trip we MIRROR the code/lang shape anyway:
//   render data-caption ONLY when non-empty, so an absent/empty caption round-trips
//   as ABSENT (and the canonical compare in run-convert.js treats ""/null/absent
//   EQUAL → zero spurious ops). compose.ex defaults a missing caption to "", so an
//   omitted caption is render-equivalent to the stored "". This keeps the projection
//   byte-fidelity identical to the code node's lang handling.
//
//   convert.js has NO diagram path (it only round-trips paragraph|heading|list inline),
//   so the diagram block ⇄ TipTap-node mapping lives in run-convert.js
//   (diagramBlockToNode), exactly as code's lives there (codeBlockToNode).
//
// Why an ATOM (not a content node) — IDENTICAL reasoning to code-node.js:
//   * group:"block"  — a top-level sibling of paragraph/heading/list inside the
//     ONE canvas document (doc content is block+), so it joins the run.
//   * atom:true      — the body has NO PM-editable interior. The Mermaid source is a
//     plain string in `source`, edited by a <textarea> ProseMirror does not manage,
//     so PM treats the whole node as one indivisible unit (caret-select +
//     Backspace/Delete-of-a-selected-atom come free, like the divider/code).
//   * content absent — the node holds no PM children. It carries MUTABLE
//     `source`/`caption`, so it CAN emit a patch-block when those change (run-convert
//     .js diagramNode handling). The text edit happens OUTSIDE ProseMirror, in the
//     textarea island, then writes back to the attr.
//
// ── THE TEXTAREA ISLAND (the make-or-break, mirrored from code-node.js) ───────
//
// The NodeView builds a <pre> wrapper holding a <textarea>. The textarea is the
// EDIT surface, and it must be INVISIBLE to ProseMirror:
//   * stopEvent: () => true      — PM never sees the textarea's key/input/etc.
//     events, so a keystroke in the Mermaid source never becomes a ProseMirror
//     transaction (no caret jump, no split, no doc mutation from typing).
//   * ignoreMutation: () => true — PM never reads the textarea's DOM mutations
//     back into the document (the textarea is OUTSIDE any contentDOM; there is none
//     on an atom). PM's MutationObserver leaves it alone.
// On the textarea's `input` (debounced DEBOUNCE_MS), the view writes the new text
// back to the node's `source` attr via setNodeMarkup (a PM transaction that ONLY
// changes the attr, not the doc structure) → onUpdate → run-convert emits a
// patch-block carrying the new source. The same path serves the `caption` input.
//
// bpId / bpType / source / caption ride the node as attrs, carried through the DOM
// round-trip on data-* — IDENTICAL id contract to BpAttrs / divider / callout / code.
// data-bp-id is what makes getJSON() preserve the id run-convert.js keys by; the
// source/caption data-* attrs make a diagram edit survive the round-trip so
// run-convert.js can diff them into a patch. `source` is multi-line; a data-*
// attribute holds an arbitrary string (newlines included) verbatim, so a multi-line
// Mermaid body round-trips byte-exact.
//
// DOM-aware (the NodeView builds real DOM) but the Node SCHEMA object loads in
// plain Node (it imports ONLY @tiptap/core and references `document` lazily,
// inside the NodeView factory, which never runs in the pure-Node smoke harness).
// So __smoke.mjs imports run-convert.js (which references the diagram TYPE only,
// never the NodeView) without a browser.

import { Node, mergeAttributes } from "@tiptap/core";
import { DEBOUNCE_MS } from "../contract.js";

// The TipTap node NAME is `bpDiagram`, NOT `diagram`. UNLIKE code (whose name had to
// dodge the StarterKit inline `code` MARK) there is NO StarterKit collision for
// diagram — StarterKit ships no `diagram` node OR mark, so `diagram` would actually
// be free. We still name it `bpDiagram` to (1) keep the canvas naming convention
// consistent with bpCode/bpOpaque, and (2) leave the bare `diagram` name available
// should a future StarterKit-style extension want it. Its portable-doc `bpType` stays
// "diagram" (run-convert.js maps a block.type "diagram" to this node and back), so
// the persist contract is unchanged. NO StarterKit node is disabled for this node
// (contrast horizontalRule:false for divider and codeBlock:false for code).
export const BP_DIAGRAM_NODE_NAME = "bpDiagram";

export const Diagram = Node.create({
  name: BP_DIAGRAM_NODE_NAME,

  // A top-level block sibling (paragraph|heading|list|divider|callout|bpCode|
  // bpDiagram) inside the one canvas document. group:"block" lets it sit in the
  // doc's `block+` content without any schema surgery on the doc node itself.
  group: "block",

  // An atom leaf: no PM-editable interior, treated as a single unit. The Mermaid
  // SOURCE lives in the `source` attr and is edited by the <textarea> island below
  // (which PM never manages), so PM's atom selection + Backspace/Delete-of-a-selected
  // -atom come free — the entire structural delete affordance v1 needs.
  atom: true,

  // The node is clickable/selectable (caret can select the whole atom and delete
  // it). The textarea inside handles its own text caret; PM only ever sees a
  // NodeSelection of the whole diagram block.
  selectable: true,

  // A diagram block is a leaf container, not a textblock — defining keeps PM from
  // merging an adjacent textblock into it on backspace-at-edge.
  defining: true,

  // preserveWhitespace:'full' so a setContent of the schema-fallback <pre> (used in
  // the pure-Node round-trip / non-editable export) keeps the source's newlines and
  // indentation byte-exact. The live editor reads `source` off the attr (not the DOM
  // text), but the fallback render + parseHTML must still round-trip whitespace for
  // the non-node-view path — Mermaid source is whitespace-significant.
  code: true,

  addAttributes() {
    return {
      // bpId — the portable-doc block id runToOps keys by. data-bp-id survives the
      // setContent->getJSON round-trip (same role as BpAttrs.bpId / divider / callout
      // / code).
      bpId: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-bp-id"),
        renderHTML: (attrs) => (attrs.bpId ? { "data-bp-id": attrs.bpId } : {}),
      },
      // bpType — the original portable-doc block kind ("diagram"). Carried for
      // symmetry so runToOps can read the type back off node.attrs.
      bpType: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-bp-type"),
        renderHTML: (attrs) =>
          attrs.bpType ? { "data-bp-type": attrs.bpType } : {},
      },
      // source — the Mermaid TEXT (a plain string, possibly multi-line). The textarea
      // island edits it; the node-view writes it back via setNodeMarkup. data-source
      // carries it through the DOM round-trip (an attribute holds newlines verbatim,
      // so a multi-line body is byte-exact). default "" mirrors the Elixir default
      // (default_block diagram → source:""). Always projected (even "") so an empty
      // diagram block round-trips with a source key, matching the {source} shape the
      // diagram patch always writes. (Mirrors code's `value`.)
      source: {
        default: "",
        parseHTML: (el) =>
          el.hasAttribute("data-source")
            ? el.getAttribute("data-source")
            : el.textContent || "",
        renderHTML: (attrs) => ({ "data-source": attrs.source || "" }),
      },
      // caption — the OPTIONAL figure label. null when absent: we render data-caption
      // ONLY when non-empty so an absent/empty caption round-trips as ABSENT
      // (byte-fidelity), never "". compose.ex defaults a missing caption to "", so an
      // omitted caption is render-equivalent to the stored "". (Mirrors code's `lang`
      // handling — even though the STORED diagram always carries caption, the canvas
      // projection treats it like the optional, droppable `lang`.)
      caption: {
        default: null,
        parseHTML: (el) =>
          el.hasAttribute("data-caption")
            ? el.getAttribute("data-caption")
            : null,
        renderHTML: (attrs) =>
          attrs.caption != null && attrs.caption !== ""
            ? { "data-caption": attrs.caption }
            : {},
      },
    };
  },

  // Parse a rendered diagram shell back into a diagram node (so setContent of the
  // node-view's own DOM round-trips). There is NO StarterKit codeBlock contention
  // here — we match ONLY our own data-attributed wrapper (a <pre data-bp-type=
  // 'diagram'>), reading the source off data-source. We deliberately do NOT claim the
  // bare <pre> tag (UNLIKE code-node.js): the canvas code node already owns the bare
  // <pre> parse rule, and two canvas nodes both claiming <pre> would be ambiguous on
  // paste/setContent. The diagram only round-trips its OWN typed wrapper.
  parseHTML() {
    return [{ tag: "pre[data-bp-type='diagram']", preserveWhitespace: "full" }];
  },

  // A schema-level fallback render (used when NO node-view is mounted — e.g. the
  // pure-Node round-trip, or a non-editable export). The node-view (below) OVERRIDES
  // this in the live editor; this keeps the schema self-describing and gives parseHTML
  // a target. The Mermaid source rides in the `data-source` attr (via the source
  // attr's renderHTML), so we do NOT also emit it as the <pre> body — a double
  // emission would balloon a multi-line diagram to twice its size. parseHTML reads it
  // back off data-source. (Mirrors code-node.js's renderHTML.)
  renderHTML({ HTMLAttributes }) {
    return [
      "pre",
      mergeAttributes(HTMLAttributes, { "data-bp-type": "diagram" }),
    ];
  },

  // ── the NodeView: a <pre> wrapping a NON-PM <textarea> island ────────────────
  //
  // Builds:
  //   <pre class="bp-canvas-diagram" data-bp-type="diagram">  ← frame (monospace)
  //     <textarea class="bp-canvas-diagram-area">…source…</textarea>  ← EDIT island
  //     <input class="bp-canvas-diagram-caption" />            ← optional caption
  //
  // The textarea is the edit surface ProseMirror DOES NOT MANAGE:
  //   * stopEvent:()=>true      — PM never turns its keystrokes/clicks into
  //     transactions (typing Mermaid source never splits/mutates the PM doc).
  //   * ignoreMutation:()=>true — PM never reads its DOM mutations into the
  //     document (the textarea lives OUTSIDE any contentDOM; there is none).
  // On `input` (debounced), the view writes source/caption back to the node attrs via
  // setNodeMarkup — a PM transaction changing ONLY the attr — which fires onUpdate →
  // run-convert emits a patch-block carrying the new source/caption.
  //
  // The caption input is placed AFTER the source textarea (a caption is a figure
  // label that reads below the figure); the code node's lang input sat above. Purely
  // cosmetic — both are debounced non-PM controls writing one attr each.
  addNodeView() {
    return ({ node, editor, getPos }) => {
      const dom = document.createElement("pre");
      dom.className = "bp-canvas-diagram";
      dom.setAttribute("data-bp-type", "diagram");
      // Monospace + preserve the textarea's own whitespace; the <pre> is a frame,
      // the textarea owns the editable text.
      dom.style.fontFamily =
        "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace";
      dom.style.whiteSpace = "normal"; // the textarea wraps/scrolls; the <pre> frame doesn't

      // The EDIT island: a textarea showing the Mermaid source. Monospace, full-width,
      // auto-sized to its content lines. PM never manages it (stopEvent /
      // ignoreMutation below).
      const area = document.createElement("textarea");
      area.className = "bp-canvas-diagram-area";
      area.setAttribute("spellcheck", "false");
      area.style.fontFamily =
        "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace";
      area.style.width = "100%";
      area.style.boxSizing = "border-box";
      area.style.border = "none";
      area.style.background = "transparent";
      area.style.resize = "vertical";
      area.style.whiteSpace = "pre";
      area.style.overflowWrap = "normal";

      // The OPTIONAL caption input — a small non-PM control. Editing it writes the
      // `caption` attr (debounced) exactly like the textarea writes `source`.
      const captionInput = document.createElement("input");
      captionInput.type = "text";
      captionInput.className = "bp-canvas-diagram-caption";
      captionInput.placeholder = "caption";
      captionInput.setAttribute("contenteditable", "false");

      dom.appendChild(area);
      dom.appendChild(captionInput);

      // Paint the controls from the node's current attrs. Re-run on every update()
      // so an external attr change (an echo, an undo) reflects. Guard against
      // clobbering the field the user is actively typing in (don't reset its value
      // mid-keystroke) by only writing when the incoming value differs.
      const paint = (n) => {
        const source = (n.attrs && n.attrs.source) || "";
        const caption = (n.attrs && n.attrs.caption) || "";
        if (area.value !== source) area.value = source;
        if (captionInput.value !== caption) captionInput.value = caption;
        // Editability mirrors the editor's mode.
        const editable = editor.isEditable;
        area.readOnly = !editable;
        captionInput.readOnly = !editable;
      };

      paint(node);

      // Debounced write-back of source+caption to the node attrs. setNodeMarkup
      // changes ONLY the attrs (the node stays the same atom in the same place), so
      // onUpdate → run-convert emits a single patch-block carrying the changed
      // field(s). The debounce mirrors the editor's DEBOUNCE_MS so a burst of
      // keystrokes coalesces into one attr write (and thus one op batch).
      let writeTimer = null;
      const scheduleWrite = () => {
        if (!editor.isEditable) return;
        if (writeTimer) clearTimeout(writeTimer);
        writeTimer = setTimeout(() => {
          writeTimer = null;
          if (typeof getPos !== "function") return;
          const pos = getPos();
          if (pos == null) return;
          const cur = editor.state.doc.nodeAt(pos);
          if (!cur) return;
          const nextSource = area.value;
          // caption: empty string → null so an absent caption round-trips as ABSENT
          // (mirrors code's lang "" → null; the canonical compare treats ""/null/
          // absent equal, so a no-op edit emits nothing).
          const rawCaption = captionInput.value;
          const nextCaption = rawCaption === "" ? null : rawCaption;
          if (
            cur.attrs.source === nextSource &&
            (cur.attrs.caption || null) === nextCaption
          ) {
            return; // nothing changed — emit nothing
          }
          editor
            .chain()
            .command(({ tr }) => {
              tr.setNodeMarkup(pos, undefined, {
                ...cur.attrs,
                source: nextSource,
                caption: nextCaption,
              });
              return true;
            })
            .run();
        }, DEBOUNCE_MS);
      };

      area.addEventListener("input", scheduleWrite);
      captionInput.addEventListener("input", scheduleWrite);

      return {
        dom,
        // NO contentDOM — this is an atom; the textarea is NOT a PM content hole.
        // The source lives in the `source` attr, edited entirely outside ProseMirror.

        // Re-render the controls when the node's attrs change (echo/undo). Return
        // false for a different node type so PM rebuilds the view.
        update: (updated) => {
          if (updated.type.name !== BP_DIAGRAM_NODE_NAME) return false;
          paint(updated);
          return true;
        },

        // THE ISLAND CONTRACT: PM must NOT turn the textarea's events into
        // transactions. Returning true from stopEvent for every event in our DOM
        // tree tells ProseMirror "this is handled by the view, leave it alone" — so a
        // keystroke in the source never becomes a PM split/mutation/caret jump.
        stopEvent: () => true,

        // PM must NOT read the textarea's DOM mutations back into the document. The
        // textarea is outside any contentDOM; returning true tells PM's
        // MutationObserver to ignore every mutation under this node-view.
        ignoreMutation: () => true,

        destroy: () => {
          if (writeTimer) clearTimeout(writeTimer);
          area.removeEventListener("input", scheduleWrite);
          captionInput.removeEventListener("input", scheduleWrite);
        },
      };
    };
  },
});
