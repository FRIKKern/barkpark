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
import { safeUrl } from "../safe-url.js";
import { t } from "../i18n.js";

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
    dom.setAttribute("title", t("Part of the document template"));
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
  //     <a class="bp-button[ bp-button--primary]" …>   ← read-only PREVIEW (reader classes)
  //     <span contenteditable="false">                  ← editable: the label IN PLACE
  //       <span class="bp-button[ …]" contenteditable="plaintext-only">label</span>
  //     <div class="bp-canvas-action-controls">
  //       <input  class="bp-canvas-action-href">       ← config the reader never paints
  //       <select class="bp-canvas-action-priority">
  //
  // Every editable surface is one ProseMirror DOES NOT MANAGE:
  //   * stopEvent:()=>true      — PM never turns their key/input/change/click events
  //     into transactions.
  //   * ignoreMutation:()=>true — PM never reads their DOM mutations into the document.
  // label & href commit on `input` DEBOUNCED (DEBOUNCE_MS; blur and bp-flush-node
  // flush); priority commits on `change` (immediate). A commit replaces ONLY the
  // touched keys on the latest attrs and setNodeMarkup(pos, undefined, nextAttrs) →
  // onUpdate → run-convert emits the patch. The commit is skipped when the canonical
  // action key is unchanged (a no-op re-select emits nothing, the reader's nil≡secondary).
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
      // Painted only while the editor is read-only.
      const preview = document.createElement("a");
      preview.setAttribute("tabindex", "-1");
      // A click inside the stopEvent island must never navigate — guard explicitly.
      preview.addEventListener("click", (e) => e.preventDefault());

      // The label edits where it reads (the card action-label precedent, card-node.js):
      // while editable, a non-link sibling carrying the reader's button classes is the
      // sole label editor — no navigation, no nested interactive content. A
      // contentEditable=false boundary makes the plaintext-only host its own browser
      // editing host, so the caret stays inside the button.
      const labelBoundary = document.createElement("span");
      labelBoundary.contentEditable = "false";
      const labelHost = document.createElement("span");
      labelHost.setAttribute("data-test-id", "paper-action-label");
      labelHost.setAttribute("data-placeholder", t("Button label"));
      labelHost.setAttribute("role", "textbox");
      labelHost.setAttribute("aria-label", t("Action label"));
      labelHost.setAttribute("aria-multiline", "false");
      labelHost.tabIndex = 0;
      labelHost.style.cursor = "text";
      labelBoundary.appendChild(labelHost);

      // The controls row.
      const controls = document.createElement("div");
      controls.className = "bp-canvas-action-controls";

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
        o.textContent = t(text);
        prioritySelect.appendChild(o);
      }

      controls.appendChild(hrefInput);
      controls.appendChild(prioritySelect);

      dom.appendChild(preview);
      dom.appendChild(labelBoundary);
      dom.appendChild(controls);

      // Which surfaces hold an unsaved edit. Only a touched key is written, so a label
      // edit never materialises an href or priority the author never set.
      let labelDirty = false;
      let hrefDirty = false;
      let composing = false;

      // Paint the controls + preview from the node's current attrs. Re-run on every
      // update() so an external attr change (an echo, an undo) reflects. Guard "only
      // write when differs" so an echo/undo never clobbers a field mid-edit.
      const paint = (n) => {
        const attrs = (n && n.attrs) || {};
        const label = attrs.label == null ? "" : String(attrs.label);
        const href = attrs.href == null ? "" : String(attrs.href);
        const priority = normalizePriority(attrs.priority);
        const editable = editor.isEditable;
        const variant = priority === "primary" ? "bp-button bp-button--primary" : "bp-button";

        if (!composing && !labelDirty && labelHost.textContent !== label) labelHost.textContent = label;
        if (!hrefDirty && hrefInput.value !== href) hrefInput.value = href;
        if (prioritySelect.value !== priority) prioritySelect.value = priority;

        labelHost.className = variant;
        labelHost.contentEditable = editable ? "plaintext-only" : "false";
        labelHost.tabIndex = editable ? 0 : -1;
        labelBoundary.style.display = editable ? "" : "none";
        hrefInput.readOnly = !editable;
        prioritySelect.disabled = !editable;

        // The read-only preview: the reader's anchor, class carries the reader
        // variant; href is display-only.
        preview.textContent = label || t("Button");
        preview.className = variant;
        preview.setAttribute("href", safeUrl(href || "#"));
        preview.style.display = editable ? "none" : "";
      };

      paint(node);

      // The next attrs bag: the latest attrs with ONLY the touched keys replaced. href
      // and label ride as their string value (an EMPTY value stays "" — a user who
      // cleared it intentionally emptied it). priority is the select value
      // ("primary" | "secondary"); actionKey collapses nil≡secondary, so re-selecting
      // Secondary on a never-set block stays a zero-op.
      const buildNextAttrs = (cur, { priority = false } = {}) => {
        const next = { ...cur.attrs };
        if (labelDirty) next.label = labelHost.textContent || "";
        if (hrefDirty) next.href = hrefInput.value;
        if (priority) next.priority = prioritySelect.value;
        return next;
      };

      // Write the edited attrs back via setNodeMarkup (a PM transaction that ONLY
      // changes attrs, not the doc structure) → onUpdate → run-convert emits the
      // patch. Skip when getPos()==null / nodeAt==null / the canonical action key is
      // unchanged, so a no-op re-select (e.g. "Secondary" on a never-set block) emits
      // nothing.
      const commitNow = (options) => {
        if (!editor.isEditable || composing) return;
        if (typeof getPos !== "function") return;
        const pos = getPos();
        if (pos == null) return;
        const cur = editor.state.doc.nodeAt(pos);
        if (!cur) return;
        const nextAttrs = buildNextAttrs(cur, options);
        labelDirty = false;
        hrefDirty = false;
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

      const onLabelInput = () => { labelDirty = true; if (!composing) scheduleWrite(); };
      const onHrefInput = () => { hrefDirty = true; scheduleWrite(); };
      const onPriorityChange = () => {
        if (writeTimer) { clearTimeout(writeTimer); writeTimer = null; }
        commitNow({ priority: true });
      };
      // The label host follows the painted-text-inline keyboard contract: Enter ends
      // the edit, select-all stays inside the button, undo/redo reach canvas history.
      const onLabelKeydown = (event) => {
        if (!editor.isEditable || event.isComposing) return;
        const key = event.key.toLowerCase();
        if (event.key === "Enter") {
          event.preventDefault();
          labelHost.blur();
        } else if ((event.metaKey || event.ctrlKey) && !event.altKey && key === "a") {
          event.preventDefault();
          const range = document.createRange();
          range.selectNodeContents(labelHost);
          const selection = window.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
        } else if ((event.metaKey || event.ctrlKey) && !event.altKey && (key === "z" || key === "y")) {
          event.preventDefault();
          flushPending();
          editor.commands[event.shiftKey || key === "y" ? "redo" : "undo"]();
        }
      };
      const onLabelBeforeInput = (event) => {
        if (event.inputType === "insertParagraph" || event.inputType === "insertLineBreak") event.preventDefault();
      };
      const onCompositionStart = () => { composing = true; };
      const onCompositionEnd = () => { composing = false; labelDirty = true; scheduleWrite(); };
      const onLabelBlur = () => {
        composing = false;
        if (writeTimer) { clearTimeout(writeTimer); writeTimer = null; }
        if (labelDirty) commitNow();
        const pos = typeof getPos === "function" ? getPos() : null;
        const cur = pos == null ? null : editor.state.doc.nodeAt(pos);
        if (cur && cur.type.name === BP_ACTION_NODE_NAME) paint(cur);
      };

      const listeners = [
        [labelHost, "input", onLabelInput],
        [labelHost, "keydown", onLabelKeydown],
        [labelHost, "beforeinput", onLabelBeforeInput],
        [labelHost, "compositionstart", onCompositionStart],
        [labelHost, "compositionend", onCompositionEnd],
        [labelHost, "blur", onLabelBlur],
        [hrefInput, "input", onHrefInput],
        [prioritySelect, "change", onPriorityChange],
        [dom, "bp-flush-node", flushPending],
      ];
      for (const [target, type, listener] of listeners) target.addEventListener(type, listener);

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
          for (const [target, type, listener] of listeners) target.removeEventListener(type, listener);
        },
      };
    };
  },
});
