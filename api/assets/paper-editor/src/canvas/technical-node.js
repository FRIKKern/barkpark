// technical-node.js — the `diff` + `filetree` canvas ATTR-ATOM node-views.
//
// scaffy-backlog-blocks-editable-studio. Brings the two TECHNICAL blocks that
// shipped View-only (charter D84 / W7) INTO the continuous canvas as ProseMirror
// ATOMs whose verbatim body TEXT rides in an attr and is edited by a NON-PM
// <textarea> island — the stopEvent/ignoreMutation contenteditable-island pattern
// of code-node.js / diagram-node.js.
//
// ── WHY A SERVER-PAINTED PREVIEW (and not a hand-mirrored one) ───────────────
//
// diagram paints its own preview because a CLIENT runtime (Mermaid) exists for it.
// `diff` and `filetree` have NO client runtime: their reader HTML is produced ONLY
// by `Components.diff_html/1` / `Components.filetree_html/1` (compose.ex's `_raw`
// hatch). D8 / pd-doctrine rule 3 forbids a second, hand-written JS producer, and
// canvas_reader_parity_gate_test.exs §3 MECHANICALLY forbids each type's reader
// container class literal anywhere under src/**/*.js. (Those two literals are
// deliberately NOT quoted here: §3 scans this file's COMMENTS too, so naming them
// would red the gate from a comment. They are the `bp-` prefix plus the block type,
// and they live in components.ex diff_html/1 + filetree_html/1.)
//
// So these two follow the task-list-node.js / figure-node.js shape instead:
//   * the EDITABLE datum (the verbatim text + its metadata) rides node attrs and is
//     edited by non-PM controls the node-view owns;
//   * the DISPLAY HTML is the reader's OWN `Render.render_block(block, %{style:
//     :article})`, pushed server-side on the SHIPPED `bp:block-html` channel
//     (shared/paper.ex push_block_renders) and injected into a
//     `[data-bp-fleet-body]` hole keyed by `[data-bp-fleet-id]`.
// The node-view writes `bp-canvas-*` chrome ONLY, never a reader class literal, so
// §3 stays green and the canvas can never fork from the reader.
//
// ── CONTENT MODEL (resolved against the live persist code) ───────────────────
//
//   blocks.ex default_block("diff")     → %{type:"diff", diff:"", file:"", lang:""}
//   blocks.ex default_block("filetree") → %{type:"filetree", text:"", legend:""}
//   blocks.ex build_block_patch/validate_block_patch for both route to
//     TechnicalBlockEditor.build_patch/2, which writes exactly:
//       diff     → the fetched subset of ~w(diff file lang)
//       filetree → the fetched subset of ~w(text legend)
//   compose.ex compose_block reads Map.get(b,"diff"/"text") plus the metadata.
//
// The canvas patch writes the SAME key set the classic form writes, so a block
// edited in either surface lands the identical shape — the lossless round-trip the
// task's first acceptance lock demands.
//
// DOM-aware (the NodeView builds real DOM) but the Node SCHEMA object loads in
// plain Node: it imports ONLY @tiptap/core + sibling modules and touches `document`
// lazily inside addNodeView, which never runs in the pure-Node smoke harness. So
// __smoke.mjs can import run-convert.js (which references the TYPES only) headless.

import { Node, mergeAttributes } from "@tiptap/core";
import { DEBOUNCE_MS } from "../contract.js";
import { wireAtomAccessibility, readerPaintClass } from "./embed-node.js";

// The TipTap node NAMES. Like bpCode / bpDiagram the node name differs from the
// portable-doc bpType ("diff" / "filetree"): run-convert.js maps block.type → node
// name and back via CANVAS_ATTR_ATOM_NODE_NAMES. StarterKit ships no `diff` or
// `filetree` node, so the bp- prefix is convention, not collision-avoidance.
export const BP_DIFF_NODE_NAME = "bpDiff";
export const BP_FILETREE_NODE_NAME = "bpFiletree";

// The per-type SHAPE. `body` is the verbatim-text attr (always projected, even "");
// `meta` are the OPTIONAL scalar fields (null when absent so an empty one
// round-trips as ABSENT, mirroring code's `lang` / diagram's `caption`).
//
// KEEP LOCKSTEP with run-convert.js TECHNICAL_ATOM_SHAPES and
// TechnicalBlockEditor.build_patch/2.
export const TECHNICAL_ATOM_SPECS = {
  diff: {
    nodeName: BP_DIFF_NODE_NAME,
    body: "diff",
    bodyLabel: "Unified diff",
    meta: [
      { key: "file", label: "File", placeholder: "path/to/file" },
      { key: "lang", label: "Language", placeholder: "language" },
    ],
    chipText: "Diff",
    summary: "Edit diff",
  },
  filetree: {
    nodeName: BP_FILETREE_NODE_NAME,
    body: "text",
    bodyLabel: "File tree",
    meta: [{ key: "legend", label: "Legend", placeholder: "legend" }],
    chipText: "File tree",
    summary: "Edit file tree",
  },
};

// Build one TipTap Node extension for a technical attr-atom bpType. Both types
// share EVERY structural decision (atom, group:"block", selectable, defining,
// code:true for whitespace-exact round-trip) and differ only in their attr names —
// so the factory keeps the two nodes provably in lock-step instead of duplicating
// ~400 lines twice and letting them drift.
function createTechnicalNode(bpType) {
  const spec = TECHNICAL_ATOM_SPECS[bpType];

  return Node.create({
    name: spec.nodeName,

    // A top-level block sibling inside the ONE canvas document (doc content is
    // `block+`), so it joins the run instead of splitting it.
    group: "block",

    // An atom leaf: no PM-editable interior. The verbatim text lives in an attr and
    // is edited by the <textarea> island PM never manages, so atom selection +
    // Backspace/Delete-of-a-selected-atom come free (divider/code/diagram precedent).
    atom: true,

    selectable: true,

    // A leaf container, not a textblock — `defining` keeps PM from merging an
    // adjacent textblock into it on backspace-at-edge.
    defining: true,

    // preserveWhitespace on the fallback parse: BOTH bodies are whitespace-
    // SIGNIFICANT (a unified diff's leading +/-/space column; a filetree's box
    // glyphs and indentation), so the non-node-view round-trip must keep them
    // byte-exact.
    code: true,

    addAttributes() {
      const attrs = {
        // bpId — the portable-doc block id runToOps keys by.
        bpId: {
          default: null,
          parseHTML: (el) => el.getAttribute("data-bp-id"),
          renderHTML: (a) => (a.bpId ? { "data-bp-id": a.bpId } : {}),
        },
        // bpType — the original portable-doc block kind ("diff" / "filetree").
        bpType: {
          default: null,
          parseHTML: (el) => el.getAttribute("data-bp-type"),
          renderHTML: (a) => (a.bpType ? { "data-bp-type": a.bpType } : {}),
        },
      };

      // The BODY attr: the verbatim text. ALWAYS projected (even "") so an empty
      // block round-trips with the body key present, matching the shape the patch
      // always writes. A data-* attribute holds newlines verbatim, so a multi-line
      // body is byte-exact through the DOM round-trip.
      attrs[spec.body] = {
        default: "",
        parseHTML: (el) =>
          el.hasAttribute("data-bp-body")
            ? el.getAttribute("data-bp-body")
            : el.textContent || "",
        renderHTML: (a) => ({ "data-bp-body": a[spec.body] || "" }),
      };

      // The OPTIONAL metadata attrs. null when absent: data-* is emitted ONLY when
      // non-empty so an absent/empty value round-trips as ABSENT, never "" (mirrors
      // code's `lang` / diagram's `caption`). The canonical compare in run-convert.js
      // normalizes ""/null/absent EQUAL, so a no-op edit emits zero ops.
      for (const meta of spec.meta) {
        attrs[meta.key] = {
          default: null,
          parseHTML: (el) =>
            el.hasAttribute(`data-bp-${meta.key}`)
              ? el.getAttribute(`data-bp-${meta.key}`)
              : null,
          renderHTML: (a) =>
            a[meta.key] != null && a[meta.key] !== ""
              ? { [`data-bp-${meta.key}`]: a[meta.key] }
              : {},
        };
      }

      return attrs;
    },

    // Parse ONLY our own typed wrapper. We deliberately do NOT claim a bare tag:
    // the canvas code node already owns bare <pre>, and two nodes claiming it would
    // be ambiguous on paste/setContent (the diagram node made the same choice).
    parseHTML() {
      return [
        {
          tag: `div[data-bp-type='${bpType}']`,
          preserveWhitespace: "full",
        },
      ];
    },

    // Schema-level fallback render (used when NO node-view is mounted — the
    // pure-Node round-trip, a non-editable export). The body rides in data-bp-body
    // (via the body attr's renderHTML), so we do NOT ALSO emit it as element text —
    // a double emission would balloon a long diff to twice its size.
    renderHTML({ HTMLAttributes }) {
      return [
        "div",
        mergeAttributes(HTMLAttributes, { "data-bp-type": bpType }),
      ];
    },

    // ── the NodeView: a server-painted preview + a disclosed NON-PM edit island ──
    //
    //   <div class="bp-canvas-readonly bp-canvas-technical" data-bp-type="diff"
    //        data-bp-fleet-id="<bpId>" contenteditable="false">
    //     <div class="bp-paper-surface" data-bp-fleet-body>  ← reader paint hole
    //       <div class="bp-canvas-readonly-chip">Diff</div>  ← honest loading chip
    //     </div>
    //     <details class="bp-canvas-technical-editor"> … textarea + meta inputs … </details>
    //   </div>
    //
    // data-bp-fleet-id / data-bp-fleet-body are reused EXACTLY so the SHIPPED
    // `bp:block-html` hook paints with ZERO hook change. The edit controls are
    // SIBLINGS of the paint hole, so the hook's innerHTML write never touches them.
    addNodeView() {
      return ({ node, editor, getPos }) => {
        const bpId = (node.attrs && node.attrs.bpId) || "";

        const dom = document.createElement("div");
        dom.className = "bp-canvas-readonly bp-canvas-technical";
        dom.setAttribute("data-bp-type", bpType);
        dom.setAttribute("data-bp-fleet-id", bpId);
        dom.setAttribute("contenteditable", "false");
        dom.setAttribute("data-test-id", `paper-canvas-${bpType}`);

        // The PREVIEW paint hole: a `.bp-paper-surface` sink so the injected reader
        // HTML is styled by the ONE canonical stylesheet exactly as /papers renders
        // it (D8). Until the server HTML arrives it shows an honest loading chip.
        const body = document.createElement("div");
        body.className = readerPaintClass(editor);
        body.setAttribute("data-bp-fleet-body", "");
        const chip = document.createElement("div");
        chip.className = "bp-canvas-readonly-chip";
        chip.textContent = spec.chipText;
        body.appendChild(chip);
        dom.appendChild(body);

        // The EDIT disclosure — closed at rest (the preview IS the resting reader
        // surface, exactly like the classic TechnicalBlockEditor's <details>).
        const disclosure = document.createElement("details");
        disclosure.className = "bp-canvas-technical-editor";
        disclosure.setAttribute("contenteditable", "false");
        const summary = document.createElement("summary");
        summary.className = "bp-canvas-technical-editor-toggle";
        summary.textContent = spec.summary;
        disclosure.appendChild(summary);

        const fields = document.createElement("div");
        fields.className = "bp-canvas-technical-fields";

        // The BODY island: a monospace textarea holding the verbatim text. PM never
        // manages it (stopEvent / ignoreMutation below).
        const bodyLabel = document.createElement("label");
        bodyLabel.className = "bp-canvas-technical-field";
        const bodyLabelText = document.createElement("span");
        bodyLabelText.textContent = spec.bodyLabel;
        const area = document.createElement("textarea");
        area.className = "bp-canvas-technical-area";
        area.setAttribute("spellcheck", "false");
        area.setAttribute("aria-label", spec.bodyLabel);
        area.setAttribute("contenteditable", "false");
        area.style.fontFamily =
          "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace";
        area.style.width = "100%";
        area.style.boxSizing = "border-box";
        area.style.resize = "vertical";
        // `pre` (never pre-wrap): both bodies are column-significant, so a soft wrap
        // would misrepresent what the reader renders.
        area.style.whiteSpace = "pre";
        area.style.overflowWrap = "normal";
        bodyLabel.appendChild(bodyLabelText);
        bodyLabel.appendChild(area);
        fields.appendChild(bodyLabel);

        // The OPTIONAL metadata inputs — small non-PM controls, one attr each.
        const metaInputs = spec.meta.map((meta) => {
          const label = document.createElement("label");
          label.className = "bp-canvas-technical-field";
          const labelText = document.createElement("span");
          labelText.textContent = meta.label;
          const input = document.createElement("input");
          input.type = "text";
          input.className = "bp-canvas-technical-meta";
          input.placeholder = meta.placeholder;
          input.setAttribute("aria-label", `${bpType} ${meta.label}`);
          input.setAttribute("contenteditable", "false");
          label.appendChild(labelText);
          label.appendChild(input);
          fields.appendChild(label);
          return { key: meta.key, input };
        });

        disclosure.appendChild(fields);
        dom.appendChild(disclosure);

        // Auto-grow the textarea to its content (a <textarea> with no `rows` defaults
        // to ~2 lines, which clips a real diff behind an internal scrollbar). Guarded
        // for a detached node (scrollHeight 0 → keep the previous height and let the
        // rAF/focus passes re-fit once laid out).
        const fitArea = () => {
          const prev = area.style.height;
          area.style.height = "auto";
          const h = area.scrollHeight;
          area.style.height = h > 0 ? h + "px" : prev;
        };

        const paint = (n) => {
          const attrs = (n && n.attrs) || {};
          const text = attrs[spec.body] || "";
          if (area.value !== text) area.value = text;
          for (const { key, input } of metaInputs) {
            const value = attrs[key] || "";
            if (input.value !== value) input.value = value;
          }
          const editable = editor.isEditable;
          area.readOnly = !editable;
          for (const { input } of metaInputs) input.readOnly = !editable;
          // No edit affordance at all in view mode.
          disclosure.hidden = !editable;
          fitArea();
          requestAnimationFrame(fitArea);
        };

        paint(node);

        // a11y: a tab stop with a role + accessible name, Enter/Space → NodeSelection
        // → Backspace deletes. wireAtomAccessibility's `e.target !== dom` guard keeps
        // a keystroke inside the textarea from triggering atom-select.
        wireAtomAccessibility(dom, {
          block: node.attrs || {},
          chipText: spec.chipText,
          editor,
          getPos,
        });

        // Debounced write-back of body + metadata to the node attrs. setNodeMarkup
        // changes ONLY the attrs (same atom, same place), so onUpdate → run-convert
        // emits ONE patch-block carrying the changed field(s); the server then
        // repaints the preview from the SAVED block on the same bp:block-html channel.
        let writeTimer = null;
        const commitNow = () => {
          if (typeof getPos !== "function") return;
          const pos = getPos();
          if (pos == null) return;
          const cur = editor.state.doc.nodeAt(pos);
          if (!cur) return;

          const next = { ...cur.attrs, [spec.body]: area.value };
          let changed = (cur.attrs[spec.body] || "") !== area.value;
          for (const { key, input } of metaInputs) {
            // "" → null so an absent value round-trips as ABSENT (the canonical
            // compare treats ""/null/absent equal → a no-op edit emits nothing).
            const value = input.value === "" ? null : input.value;
            if ((cur.attrs[key] || null) !== value) changed = true;
            next[key] = value;
          }
          if (!changed) return; // nothing changed — emit nothing

          editor
            .chain()
            .command(({ tr }) => {
              tr.setNodeMarkup(pos, undefined, next);
              return true;
            })
            .run();
        };
        const scheduleWrite = () => {
          if (!editor.isEditable) return;
          if (writeTimer) clearTimeout(writeTimer);
          writeTimer = setTimeout(() => {
            writeTimer = null;
            commitNow();
          }, DEBOUNCE_MS);
        };
        const flushPending = () => {
          if (!writeTimer) return;
          clearTimeout(writeTimer);
          writeTimer = null;
          commitNow();
        };

        area.addEventListener("input", scheduleWrite);
        area.addEventListener("input", fitArea);
        area.addEventListener("focus", fitArea);
        for (const { input } of metaInputs)
          input.addEventListener("input", scheduleWrite);
        dom.addEventListener("bp-flush-node", flushPending);

        return {
          dom,
          // NO contentDOM — this is an atom; the preview is server-painted and the
          // text lives on attrs, edited entirely outside ProseMirror.

          // KEEP the existing DOM across attr updates (echo / undo): repaint the
          // controls, never rebuild — so the server-painted HTML in the hole is
          // untouched (no flash back to the loading chip).
          update: (updated) => {
            if (updated.type.name !== spec.nodeName) return false;
            paint(updated);
            return true;
          },

          // THE ISLAND CONTRACT: PM must NOT turn the controls' or the paint hole's
          // events into transactions, and must NOT read the interior's DOM mutations
          // back into the document (the hook writes the hole's innerHTML directly).
          stopEvent: () => true,
          ignoreMutation: () => true,

          destroy: () => {
            if (writeTimer) clearTimeout(writeTimer);
            area.removeEventListener("input", scheduleWrite);
            area.removeEventListener("input", fitArea);
            area.removeEventListener("focus", fitArea);
            for (const { input } of metaInputs)
              input.removeEventListener("input", scheduleWrite);
            dom.removeEventListener("bp-flush-node", flushPending);
          },
        };
      };
    },
  });
}

export const Diff = createTechnicalNode("diff");
export const Filetree = createTechnicalNode("filetree");
