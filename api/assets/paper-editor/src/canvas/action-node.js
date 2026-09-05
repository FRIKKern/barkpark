// action-node.js — the CTA `action` block as a canvas CONTROL-ATOM node-view.
//
// Byte-modelled on field-node.js's native-control branch (the S3.5 bpField atom):
// an ATOM LEAF whose editable data rides in ATTRS and is edited by NATIVE HTML
// controls wrapped in a stopEvent/ignoreMutation island, so ProseMirror never turns
// a keystroke / select into a doc transaction. UNLIKE bpField (one `value` attr,
// coerced by field type) an action carries THREE editable attrs — href / label /
// priority — and serves ONE bpType ("action", like bpCode), so there is no
// per-type control dispatch and no BarkparkFieldBlockBridge coercion.
//
// ── the reader parity target (the crux) ─────────────────────────────────────
//
// The reader emits the CTA as an anchor (Render.Walk.button/2 :article):
//   priority=="primary" → <a class="bp-button bp-button--primary">
//   else                → <a class="bp-button>                       (secondary)
// i.e. the variant set is BINARY (primary vs everything-else=secondary); the reader
// collapses nil≡secondary. The node-view renders a LIVE PREVIEW <a> carrying EXACTLY
// those classes so the editor CSS mirror (.bp-canvas-action .bp-button[…]) paints it
// byte-identical to /papers. The preview is display-only: tabindex=-1 + a click
// preventDefault so PM never navigates.
//
// ── the data shape (verified against compose.ex:192 + compose_test.exs:40/59) ─
//
// A persisted action block is { id, type:"action", href?, label?, priority? } — all
// three payload keys OPTIONAL (compose defaults href/label to "" and priority to nil).
// The byte-fidelity rule (mirrors field's optional-config handling): thread each of
// href/label/priority onto attrs ONLY when present in source, using attr default
// `null` (NOT "") as the absence sentinel — so `{type:"action"}` round-trips to
// exactly `{id,type:"action"}` (zero ops) and `{href,label}` with no priority
// round-trips with no priority key. "" is used only for DOM display / compare, never
// written as a key unless the user edits.
//
// DOM-aware (the NodeView builds real DOM) but the Node SCHEMA object loads in plain
// Node (imports ONLY @tiptap/core; references `document` lazily inside the NodeView
// factory, which never runs in the pure-Node smoke harness), so run-convert.js can be
// imported by __smoke.mjs without a browser.

import { Node, mergeAttributes } from "@tiptap/core";
import { DEBOUNCE_MS } from "../contract.js";

// The TipTap node NAME is `bpAction`. There is NO StarterKit collision (StarterKit
// ships no action/button node), so — UNLIKE bpCode / divider — NO StarterKit node is
// disabled for it. Keep aligned with run-convert.js:CANVAS_ACTION_NODE_NAME and
// paper_canvas.ex:@canvas_action_types.
export const BP_ACTION_NODE_NAME = "bpAction";

// pdd-t2: the calm lock cue for a template-locked action node-view. Stamps
// data-bp-locked (a CSS hook) + a hover title on the frame — chrome around content,
// NEVER an error flash (doctrine rule 5). No-op for an unlocked action. Lifted
// VERBATIM from field-node.js's applyLockCue.
function applyLockCue(dom, node) {
  if (node && node.attrs && node.attrs.locked === true) {
    dom.setAttribute("data-bp-locked", "true");
    dom.setAttribute("title", "Part of the document template");
  }
}

// The BINARY priority collapse the reader performs (walk.ex button/2): primary iff
// =="primary", else secondary. Used for the preview class + the select display + the
// change-detection normalize, so selecting "Secondary" on a never-set-priority block
// is a ZERO-op (matches the reader collapsing nil≡secondary).
function normalizePriority(p) {
  return p === "primary" ? "primary" : "secondary";
}

// The canonical (order/absence-insensitive) key of an action node's diff-relevant
// attrs — href/label as their DOM display strings ("" when absent), priority collapsed
// to its binary value. Two nodes with the SAME key persist render-identically, so the
// commit guard + the run-convert diff both skip a no-op re-select. Mirrors
// run-convert.js:stableActionKey (kept in lockstep by construction).
function actionKey(attrs) {
  const a = attrs || {};
  return JSON.stringify({
    href: a.href == null ? "" : String(a.href),
    label: a.label == null ? "" : String(a.label),
    priority: normalizePriority(a.priority),
  });
}

export const Action = Node.create({
  name: BP_ACTION_NODE_NAME,

  // A top-level block sibling inside the one canvas document. group:"block" lets it
  // sit in the doc's `block+` content with no schema surgery on the doc node.
  group: "block",

  // An atom leaf: no PM-editable interior. The href/label/priority live in attrs and
  // are edited by the native control island below (which PM never manages), so PM's
  // atom selection + Backspace/Delete-of-a-selected-atom come free — the entire
  // structural delete affordance v1 needs. Identical rationale to bpField.
  atom: true,

  // Clickable/selectable (the caret can select the whole atom and delete it). The
  // native controls inside handle their own focus; PM only ever sees a NodeSelection
  // of the whole action block.
  selectable: true,

  // A leaf container, not a textblock — defining keeps PM from merging an adjacent
  // textblock into it on backspace-at-edge.
  defining: true,

  addAttributes() {
    return {
      // bpId — the portable-doc block id runToOps keys by. data-bp-id survives the
      // setContent->getJSON round-trip (same role as every other canvas node).
      bpId: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-bp-id"),
        renderHTML: (attrs) => (attrs.bpId ? { "data-bp-id": attrs.bpId } : {}),
      },
      // bpType — CONSTANT "action" (this node serves ONE bpType, like bpCode, UNLIKE
      // bpField/bpFleet which multiplex). Carried on data-bp-type-kind so getJSON
      // round-trips it (run-convert.js classifyNode resolves bpType off node.attrs).
      bpType: {
        default: "action",
        parseHTML: (el) => el.getAttribute("data-bp-type-kind") || "action",
        renderHTML: (attrs) =>
          attrs.bpType ? { "data-bp-type-kind": attrs.bpType } : {},
      },
      // href — the CTA target URL. OPTIONAL; default null (the absence sentinel) so an
      // href-less action round-trips WITHOUT an href key. Rendered to data-href only
      // when set.
      href: {
        default: null,
        parseHTML: (el) =>
          el.hasAttribute("data-href") ? el.getAttribute("data-href") : null,
        renderHTML: (attrs) =>
          attrs.href != null ? { "data-href": attrs.href } : {},
      },
      // label — the CTA button text. OPTIONAL; default null. Rendered to data-label
      // only when set.
      label: {
        default: null,
        parseHTML: (el) =>
          el.hasAttribute("data-label") ? el.getAttribute("data-label") : null,
        renderHTML: (attrs) =>
          attrs.label != null ? { "data-label": attrs.label } : {},
      },
      // priority — TRI-STATE at rest (absent/nil | "primary" | "secondary" | other)
      // that the reader collapses to BINARY. OPTIONAL; default null. Rendered to
      // data-priority only when set.
      priority: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-priority") || null,
        renderHTML: (attrs) =>
          attrs.priority != null ? { "data-priority": attrs.priority } : {},
      },
      // locked / role — the DOCTRINE template attrs (pdd-t2). An action could itself
      // be a mandated template block, so it carries the SAME locked/role round-trip as
      // the prose title (BpAttrs) + the field node. D3 additive: rendered ONLY when
      // set, so an ordinary action round-trips byte-identically. locked also drives the
      // calm lock cue on the node-view.
      locked: {
        default: null,
        parseHTML: (el) =>
          el.getAttribute("data-bp-locked") === "true" ? true : null,
        renderHTML: (attrs) =>
          attrs.locked === true ? { "data-bp-locked": "true" } : {},
      },
      role: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-bp-role"),
        renderHTML: (attrs) => (attrs.role ? { "data-bp-role": attrs.role } : {}),
      },
    };
  },

  // Parse a rendered action shell back into an action node (so setContent of the
  // node-view's own DOM round-trips). Match ONLY our own data-attributed wrapper (a
  // <div data-bp-type='action'>), reading the typed attrs off data-*; no bare-tag
  // claim, so we never contend with another node's parse rule.
  parseHTML() {
    return [{ tag: "div[data-bp-type='action']" }];
  },

  // A schema-level fallback render (used when NO node-view is mounted — the pure-Node
  // round-trip, or a non-editable export). The node-view (below) OVERRIDES this in the
  // live editor; this keeps the schema self-describing and gives parseHTML a target.
  // All data rides the typed attrs (via their renderHTML), so the <div> body is empty.
  renderHTML({ HTMLAttributes }) {
    return ["div", mergeAttributes(HTMLAttributes, { "data-bp-type": "action" })];
  },

  // ── the NodeView: a frame wrapping the NON-PM native control island ──────────
  //
  // Builds:
  //   <div class="bp-canvas-action" data-bp-type="action" contenteditable="false">
  //     <a class="bp-button[ bp-button--primary]" …>   ← LIVE PREVIEW (reader classes)
  //     <div class="bp-canvas-action-controls">
  //       <input  class="bp-canvas-action-label">      ← the EDIT islands
  //       <input  class="bp-canvas-action-href">
  //       <select class="bp-canvas-action-priority">
  //
  // The controls are the edit surface ProseMirror DOES NOT MANAGE:
  //   * stopEvent:()=>true      — PM never turns their key/input/change/click events
  //     into transactions.
  //   * ignoreMutation:()=>true — PM never reads their DOM mutations into the document.
  // label & href commit on `input` DEBOUNCED (DEBOUNCE_MS); priority commits on
  // `change` (immediate). Each handler reads all three controls, builds nextAttrs, and
  // setNodeMarkup(pos, undefined, nextAttrs) via editor.chain().command → onUpdate →
  // run-convert emits the patch. The commit is skipped when the canonical action key
  // is unchanged (a no-op re-select emits nothing, matching the reader's nil≡secondary).
  addNodeView() {
    return ({ node, editor, getPos }) => {
      const dom = document.createElement("div");
      dom.className = "bp-canvas-action";
      dom.setAttribute("data-bp-type", "action");
      dom.setAttribute("contenteditable", "false");
      dom.setAttribute("data-test-id", "paper-action");
      applyLockCue(dom, node);

      // The LIVE PREVIEW anchor — display-only, byte-matching the reader anchor
      // classes so the editor CSS mirror paints it byte-identical to /papers.
      const preview = document.createElement("a");
      preview.setAttribute("tabindex", "-1");
      // A click inside the stopEvent island must never navigate — guard explicitly.
      preview.addEventListener("click", (e) => e.preventDefault());

      // The controls row.
      const controls = document.createElement("div");
      controls.className = "bp-canvas-action-controls";

      const labelInput = document.createElement("input");
      labelInput.type = "text";
      labelInput.className = "bp-canvas-action-label";
      labelInput.placeholder = "Button label";
      labelInput.setAttribute("contenteditable", "false");
      labelInput.setAttribute("data-test-id", "paper-action-label");

      const hrefInput = document.createElement("input");
      hrefInput.type = "url";
      hrefInput.className = "bp-canvas-action-href";
      hrefInput.placeholder = "https://…";
      hrefInput.setAttribute("contenteditable", "false");
      hrefInput.setAttribute("data-test-id", "paper-action-href");

      const prioritySelect = document.createElement("select");
      prioritySelect.className = "bp-canvas-action-priority";
      prioritySelect.setAttribute("contenteditable", "false");
      prioritySelect.setAttribute("data-test-id", "paper-action-priority");
      for (const [value, text] of [
        ["primary", "Primary"],
        ["secondary", "Secondary"],
      ]) {
        const o = document.createElement("option");
        o.value = value;
        o.textContent = text;
        prioritySelect.appendChild(o);
      }

      controls.appendChild(labelInput);
      controls.appendChild(hrefInput);
      controls.appendChild(prioritySelect);

      dom.appendChild(preview);
      dom.appendChild(controls);

      // Paint the controls + preview from the node's current attrs. Re-run on every
      // update() so an external attr change (an echo, an undo) reflects. Guard "only
      // write when differs" so an echo/undo never clobbers a field mid-edit.
      const paint = (n) => {
        const attrs = (n && n.attrs) || {};
        const label = attrs.label == null ? "" : String(attrs.label);
        const href = attrs.href == null ? "" : String(attrs.href);
        const priority = normalizePriority(attrs.priority);
        const editable = editor.isEditable;

        if (labelInput.value !== label) labelInput.value = label;
        if (hrefInput.value !== href) hrefInput.value = href;
        if (prioritySelect.value !== priority) prioritySelect.value = priority;

        labelInput.readOnly = !editable;
        hrefInput.readOnly = !editable;
        prioritySelect.disabled = !editable;

        // The live preview: text = label || "Button"; class carries the reader
        // variant; href is display-only.
        preview.textContent = label || "Button";
        preview.className =
          priority === "primary" ? "bp-button bp-button--primary" : "bp-button";
        preview.setAttribute("href", href || "#");
      };

      paint(node);

      // Build the next attrs bag from the three controls. href/label ride as their
      // string value (an EMPTY input stays "" — a user who cleared the field
      // intentionally emptied it; the coarse re-emit sends "" and the reader shows an
      // empty label / "#" href, matching a live edit). priority is the select value
      // ("primary" | "secondary").
      const buildNextAttrs = (cur) => ({
        ...cur.attrs,
        label: labelInput.value,
        href: hrefInput.value,
        priority: prioritySelect.value,
      });

      // Write the edited attrs back via setNodeMarkup (a PM transaction that ONLY
      // changes attrs, not the doc structure) → onUpdate → run-convert emits the
      // patch. Skip when getPos()==null / nodeAt==null / the canonical action key is
      // unchanged, so a no-op re-select (e.g. "Secondary" on a never-set block) emits
      // nothing.
      const commitNow = () => {
        if (!editor.isEditable) return;
        if (typeof getPos !== "function") return;
        const pos = getPos();
        if (pos == null) return;
        const cur = editor.state.doc.nodeAt(pos);
        if (!cur) return;
        const nextAttrs = buildNextAttrs(cur);
        if (actionKey(cur.attrs) === actionKey(nextAttrs)) return; // no-op
        editor
          .chain()
          .command(({ tr }) => {
            tr.setNodeMarkup(pos, undefined, nextAttrs);
            return true;
          })
          .run();
      };

      // label & href commit DEBOUNCED on `input` (mirroring the string-field debounce);
      // priority commits IMMEDIATELY on `change`.
      let writeTimer = null;
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

      labelInput.addEventListener("input", scheduleWrite);
      hrefInput.addEventListener("input", scheduleWrite);
      prioritySelect.addEventListener("change", commitNow);
      dom.addEventListener("bp-flush-node", flushPending);

      return {
        dom,
        // NO contentDOM — an atom; the controls are NOT a PM content hole. The data
        // lives in attrs, edited entirely outside ProseMirror.
        update: (updated) => {
          if (updated.type.name !== BP_ACTION_NODE_NAME) return false;
          paint(updated);
          return true;
        },
        // THE ISLAND CONTRACT: PM must NOT turn the controls' events into transactions.
        stopEvent: () => true,
        // PM must NOT read the controls' DOM mutations back into the document.
        ignoreMutation: () => true,
        destroy: () => {
          if (writeTimer) clearTimeout(writeTimer);
          labelInput.removeEventListener("input", scheduleWrite);
          hrefInput.removeEventListener("input", scheduleWrite);
          prioritySelect.removeEventListener("change", commitNow);
          dom.removeEventListener("bp-flush-node", flushPending);
        },
      };
    };
  },
});
