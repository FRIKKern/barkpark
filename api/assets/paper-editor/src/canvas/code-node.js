// code-node.js — Phase-4 Stage S3.3: the FIRST canvas ATOM-WITH-ATTR node-view.
//
// Brings the `code` block INTO the continuous canvas as a ProseMirror ATOM whose
// code TEXT rides in an ATTR (`value`) and is edited by a NON-PM <textarea> island
// — the stopEvent/ignoreMutation contenteditable-island pattern. This is the THIRD
// node-view shape:
//   * S3.1 divider — an ATOM with NO content and NO attr to edit (a pure leaf).
//   * S3.2 callout — a CONTENT node whose body is a PM-managed inline region.
//   * S3.3 code    — an ATOM whose body text is a plain STRING in an attr, edited
//                    by a control PROSEMIRROR DOES NOT MANAGE. Diagram is next and
//                    will reuse this exact shape (an attr-bearing atom island).
//
// ── CONTENT MODEL (resolved against the live persist code — cite file:line) ───
//
//   blocks.ex:230  default_block("code") → %{type:"code", lang:"", value:""}
//   blocks.ex:37   build_block_patch(%{"type"=>"code"}, params):
//       %{} |> put_if_present("lang", params["lang"])   # blocks.ex:113-115:
//           |> Map.put("value", params["value"] || "")   #   nil/"" lang is DROPPED
//   compose.ex:272 compose_block(%{"type"=>"code"}) reads ONLY Map.get(b,"value").
//   So the code block is { id, type:"code", value:"<text>", lang?:"<lang>" } — a
//   PLAIN STRING `value` (NOT inline runs, NOT marks) plus an OPTIONAL `lang`.
//   The language field is `lang` (NOT `language`) — match it so the round-trip is
//   byte-identical. An empty/absent lang round-trips as NO `lang` key (put_if_present
//   drops "" / nil), so the canvas must carry lang ONLY when non-empty.
//   convert.js has NO code-BLOCK path (its `code` is the INLINE code MARK), so the
//   code block ⇄ TipTap-node mapping lives in run-convert.js (codeBlockToNode).
//
// Why an ATOM (not a content node):
//   * group:"block"  — a top-level sibling of paragraph/heading/list inside the
//     ONE canvas document (doc content is block+), so it joins the run.
//   * atom:true      — the body has NO PM-editable interior. The code text is a
//     plain string in `value`, edited by a <textarea> ProseMirror does not manage,
//     so PM treats the whole node as one indivisible unit (caret-select +
//     Backspace/Delete-of-a-selected-atom come free, like the divider).
//   * content absent — like the divider, the node holds no PM children. UNLIKE the
//     divider it carries a MUTABLE `value`/`lang`, so it CAN emit a patch-block
//     when those change (run-convert.js codeNode handling). The text edit happens
//     OUTSIDE ProseMirror, in the textarea island, then writes back to the attr.
//
// ── THE TEXTAREA ISLAND (the make-or-break of S3.3) ───────────────────────────
//
// The NodeView builds a <pre> wrapper holding a <textarea>. The textarea is the
// EDIT surface, and it must be INVISIBLE to ProseMirror:
//   * stopEvent: () => true      — PM never sees the textarea's key/input/etc.
//     events, so a keystroke in the code never becomes a ProseMirror transaction
//     (no caret jump, no split, no doc mutation from typing code).
//   * ignoreMutation: () => true — PM never reads the textarea's DOM mutations
//     back into the document (the textarea is OUTSIDE any contentDOM; there is no
//     contentDOM at all on an atom). PM's MutationObserver leaves it alone.
// On the textarea's `input` (debounced DEBOUNCE_MS), the view writes the new text
// back to the node's `value` attr via setNodeMarkup (a PM transaction that ONLY
// changes the attr, not the doc structure) → onUpdate → run-convert emits a
// patch-block carrying the new value. The same path serves the `lang` input.
//
// bpId / bpType / value / lang ride the node as attrs, carried through the DOM
// round-trip on data-* — IDENTICAL id contract to BpAttrs / divider / callout.
// data-bp-id is what makes getJSON() preserve the id run-convert.js keys by; the
// value/lang data-* attrs make a code edit survive the round-trip so run-convert.js
// can diff them into a patch. `value` is multi-line; a data-* attribute holds an
// arbitrary string (newlines included) verbatim, so a multi-line code body
// round-trips byte-exact.
//
// DOM-aware (the NodeView builds real DOM) but the Node SCHEMA object loads in
// plain Node (it imports ONLY @tiptap/core and references `document` lazily,
// inside the NodeView factory, which never runs in the pure-Node smoke harness).
// So __smoke.mjs imports run-convert.js (which references the code TYPE only,
// never the NodeView) without a browser.

import { Node, mergeAttributes } from "@tiptap/core";
import { DEBOUNCE_MS, configControlHidden } from "../contract.js";

// The TipTap node NAME is `bpCode`, NOT `code` — `code` is already the StarterKit
// INLINE code MARK (extension-code: name:'code', parses <code>), which the canvas
// KEEPS so inline-code round-trips. A ProseMirror schema cannot hold a NODE and a
// MARK of the same name, so the canvas code BLOCK node takes a distinct name. Its
// portable-doc `bpType` stays "code" (run-convert.js maps a block.type "code" to
// this node and back), so the persist contract is unchanged.
//
// Separately, index.js DISABLES StarterKit's `codeBlock` NODE (codeBlock:false)
// so ONLY this node owns the <pre> parse rule — the same lesson as the S3.1
// horizontalRule fix (two nodes claiming one tag is ambiguous on paste/setContent,
// and StarterKit's setCodeBlock would otherwise insert a `codeBlock` runToOps
// mis-diffs as unknown). With codeBlock off, <pre> is free for this node.
export const BP_CODE_NODE_NAME = "bpCode";

export const Code = Node.create({
  name: BP_CODE_NODE_NAME,

  // A top-level block sibling (paragraph|heading|list|divider|callout|bpCode)
  // inside the one canvas document. group:"block" lets it sit in the doc's
  // `block+` content without any schema surgery on the doc node itself.
  group: "block",

  // An atom leaf: no PM-editable interior, treated as a single unit. The code TEXT
  // lives in the `value` attr and is edited by the <textarea> island below (which
  // PM never manages), so PM's atom selection + Backspace/Delete-of-a-selected-atom
  // come free — the entire structural delete affordance v1 needs.
  atom: true,

  // The node is clickable/selectable (caret can select the whole atom and delete
  // it). The textarea inside handles its own text caret; PM only ever sees a
  // NodeSelection of the whole code block.
  selectable: true,

  // A code block is a leaf container, not a textblock — defining keeps PM from
  // merging an adjacent textblock into it on backspace-at-edge.
  defining: true,

  // preserveWhitespace:'full' so a setContent of the schema-fallback <pre> (used
  // in the pure-Node round-trip / non-editable export) keeps the code's newlines
  // and indentation byte-exact, exactly as StarterKit's codeBlock did. The live
  // editor reads `value` off the attr (not the DOM text), but the fallback render
  // + parseHTML must still round-trip whitespace for the non-node-view path.
  code: true,

  addAttributes() {
    return {
      // bpId — the portable-doc block id runToOps keys by. data-bp-id survives the
      // setContent->getJSON round-trip (same role as BpAttrs.bpId / divider / callout).
      bpId: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-bp-id"),
        renderHTML: (attrs) => (attrs.bpId ? { "data-bp-id": attrs.bpId } : {}),
      },
      // bpType — the original portable-doc block kind ("code"). Carried for
      // symmetry so runToOps can read the type back off node.attrs.
      bpType: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-bp-type"),
        renderHTML: (attrs) =>
          attrs.bpType ? { "data-bp-type": attrs.bpType } : {},
      },
      // value — the code TEXT (a plain string, possibly multi-line). The textarea
      // island edits it; the node-view writes it back via setNodeMarkup. data-value
      // carries it through the DOM round-trip (an attribute holds newlines verbatim,
      // so a multi-line body is byte-exact). default "" mirrors the Elixir default
      // (default_block code → value:""). Always projected (even "") so an empty
      // code block round-trips with a value key, matching Map.put("value", …).
      value: {
        default: "",
        parseHTML: (el) =>
          el.hasAttribute("data-value")
            ? el.getAttribute("data-value")
            : el.textContent || "",
        renderHTML: (attrs) => ({ "data-value": attrs.value || "" }),
      },
      // lang — the OPTIONAL language. null when absent: put_if_present drops a
      // nil/"" lang on persist (blocks.ex:113-115), so a code block with no language
      // has NO `lang` key. We render data-lang ONLY when non-empty so an absent lang
      // round-trips as ABSENT (byte-fidelity), never "".
      lang: {
        default: null,
        parseHTML: (el) =>
          el.hasAttribute("data-lang") ? el.getAttribute("data-lang") : null,
        renderHTML: (attrs) =>
          attrs.lang != null && attrs.lang !== ""
            ? { "data-lang": attrs.lang }
            : {},
      },
    };
  },

  // Parse a rendered code shell back into a code node (so setContent of the
  // node-view's own DOM round-trips). With StarterKit's codeBlock disabled, the
  // bare <pre> is free; we match BOTH our data-attributed wrapper (the node-view's
  // own DOM) AND a bare <pre> (a pasted/legacy code block), reading the text off
  // data-value when present else the element's textContent.
  parseHTML() {
    // preserveWhitespace:'full' so a bare <pre> paste (value off textContent, not
    // data-value) keeps its newlines/indentation verbatim, matching how the code
    // text round-trips through the data-value attribute.
    return [
      { tag: "pre[data-bp-type='code']", preserveWhitespace: "full" },
      { tag: "pre", preserveWhitespace: "full" },
    ];
  },

  // A schema-level fallback render (used when NO node-view is mounted — e.g. the
  // pure-Node round-trip, or a non-editable export). The node-view (below)
  // OVERRIDES this in the live editor; this keeps the schema self-describing and
  // gives parseHTML a target. The code text rides in the `data-value` attr (via
  // the value attr's renderHTML), so we do NOT also emit it as the <pre> body —
  // a double emission would balloon a multi-KB code block to twice its size.
  // parseHTML reads it back off data-value.
  renderHTML({ HTMLAttributes }) {
    return ["pre", mergeAttributes(HTMLAttributes, { "data-bp-type": "code" })];
  },

  // ── the NodeView: a <pre> wrapping a NON-PM <textarea> island ────────────────
  //
  // Builds:
  //   <pre class="bp-canvas-code" data-bp-type="code">     ← frame (monospace)
  //     <input class="bp-canvas-code-lang" />              ← optional language input
  //     <textarea class="bp-canvas-code-area">…value…</textarea>  ← the EDIT island
  //
  // The textarea is the edit surface ProseMirror DOES NOT MANAGE:
  //   * stopEvent:()=>true      — PM never turns its keystrokes/clicks into
  //     transactions (typing code never splits/mutates the PM doc).
  //   * ignoreMutation:()=>true — PM never reads its DOM mutations into the
  //     document (the textarea lives OUTSIDE any contentDOM; there is none).
  // On `input` (debounced), the view writes value/lang back to the node attrs via
  // setNodeMarkup — a PM transaction changing ONLY the attr — which fires onUpdate
  // → run-convert emits a patch-block carrying the new value/lang.
  addNodeView() {
    return ({ node, editor, getPos }) => {
      const dom = document.createElement("pre");
      dom.className = "bp-canvas-code";
      dom.setAttribute("data-bp-type", "code");
      // S9 code-interior: font-family + white-space now live in the
      // `.bp-canvas-code` CSS rule (both sinks), bound to --paper-font-mono — NOT
      // stamped inline here. The old inline stack ("…SFMono-Regular…Consolas…")
      // diverged from the reader's --paper-font-mono AND, being inline, out-ranked
      // the token — the source of the code-block font drift. Removing it lets the
      // shared token win, so the <pre> frame is theme-agnostic and reader-aligned.

      // The OPTIONAL language input — a small non-PM control. Editing it writes the
      // `lang` attr (debounced) exactly like the textarea writes `value`.
      //
      // pdd-t18b (rule 6 / D13): `lang` is edit-only config the reader NEVER paints
      // (Figures.code_block_html/1 ignores it). An empty `lang` input left showing
      // its "lang" placeholder at rest is chrome that won't exist in the render, so
      // it becomes a HOVER/FOCUS affordance (see syncChrome below) — hidden while
      // idle, revealed on interaction. A SET lang stays visible (meaningful config).
      const langInput = document.createElement("input");
      langInput.type = "text";
      langInput.className = "bp-canvas-code-lang";
      langInput.placeholder = "lang";
      // Accessible name that survives the resting-chrome hide (a placeholder is
      // only a fallback name, and it's invisible while the control is hidden).
      langInput.setAttribute("aria-label", "code language");
      langInput.setAttribute("contenteditable", "false");

      // The EDIT island: a textarea showing the code. Monospace, full-width,
      // auto-sized to its content lines. PM never manages it (stopEvent /
      // ignoreMutation below).
      const area = document.createElement("textarea");
      area.className = "bp-canvas-code-area";
      area.setAttribute("spellcheck", "false");
      // S9 code-interior: the textarea's typography (font / size / line-height /
      // colour / whitespace / transparent-borderless frame / width / resize) now
      // lives in the `.bp-canvas-code-area` CSS rule (both sinks), token-bound to
      // the SAME --bp-codeblock-*/--paper-* the reader <pre> uses — so the editable
      // code renders at 0.9rem/1.5 mono/ink, byte-identical to the reader, instead
      // of the UA-default ~13.3px sans the old inline styles left unset. Kept
      // outside inline JS so the shared token can win; NONE of this touches the
      // island contract (stopEvent/ignoreMutation), so editing is unaffected.

      dom.appendChild(langInput);
      dom.appendChild(area);

      // Paint the controls from the node's current attrs. Re-run on every update()
      // so an external attr change (an echo, an undo) reflects. Guard against
      // clobbering the field the user is actively typing in (don't reset its value
      // mid-keystroke) by only writing when the incoming value differs.
      // pdd-t18b: the resting-chrome gate. The empty `lang` input hides at rest and
      // reveals only while the frame is hovered or focus is inside it — so an idle
      // code atom reads byte-identically to the /papers <pre> (no "lang" ghost). The
      // pure predicate (contract.js) owns the decision; this just toggles display.
      let hovered = false;
      let focused = false;
      const syncRows = () => {
        // A textarea defaults to two rows, while the reader's <pre> is exactly
        // one line tall for one authored line. Keep the edit island on the
        // authored logical-line count so the Terminal body does not grow by an
        // invisible second row. white-space:pre keeps long lines horizontal,
        // matching the reader rather than introducing visual wrap rows.
        area.rows = Math.max(1, area.value.split("\n").length);
      };
      const syncChrome = () => {
        // Both reveal channels are gated on editability: a non-editable editor
        // (view mode) must not surface an empty readonly config control on
        // hover OR focus — there is nothing the reveal could let you do.
        const hide = configControlHidden({
          value: langInput.value,
          hovered: hovered && editor.isEditable,
          focused: focused && editor.isEditable,
        });
        langInput.style.display = hide ? "none" : "";
      };

      const paint = (n) => {
        const value = (n.attrs && n.attrs.value) || "";
        const lang = (n.attrs && n.attrs.lang) || "";
        if (area.value !== value) area.value = value;
        syncRows();
        if (langInput.value !== lang) langInput.value = lang;
        // Editability mirrors the editor's mode.
        const editable = editor.isEditable;
        area.readOnly = !editable;
        langInput.readOnly = !editable;
        syncChrome();
      };

      // Reveal the config chrome on hover / focus-within; hide it again when idle.
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
        // Focus-within guard: focusout fires BEFORE the next element receives
        // focus, so hiding here would yank display:none onto the langInput in the
        // middle of a Shift+Tab from the textarea INTO it — the browser's focus
        // fixup then drops focus to <body> and the control is never reachable by
        // keyboard. relatedTarget is the element gaining focus; when it is still
        // inside this atom, focus is only MOVING within, not leaving — keep the
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

      // Debounced write-back of value+lang to the node attrs. setNodeMarkup changes
      // ONLY the attrs (the node stays the same atom in the same place), so onUpdate
      // → run-convert emits a single patch-block carrying the changed field(s). The
      // debounce mirrors the editor's DEBOUNCE_MS so a burst of keystrokes coalesces
      // into one attr write (and thus one op batch).
      let writeTimer = null;
      const commitNow = () => {
        if (typeof getPos !== "function") return;
        const pos = getPos();
        if (pos == null) return;
        const cur = editor.state.doc.nodeAt(pos);
        if (!cur) return;
        const nextValue = area.value;
        // lang: empty string → null so an absent language round-trips as ABSENT
        // (put_if_present drops "" / nil on persist).
        const rawLang = langInput.value;
        const nextLang = rawLang === "" ? null : rawLang;
        if (cur.attrs.value === nextValue && (cur.attrs.lang || null) === nextLang) {
          return; // nothing changed — emit nothing
        }
        editor
          .chain()
          .command(({ tr }) => {
            tr.setNodeMarkup(pos, undefined, {
              ...cur.attrs,
              value: nextValue,
              lang: nextLang,
            });
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
      const onAreaInput = () => {
        syncRows();
        scheduleWrite();
      };
      const flushPending = () => {
        if (!writeTimer) return;
        clearTimeout(writeTimer);
        writeTimer = null;
        commitNow();
      };

      area.addEventListener("input", onAreaInput);
      langInput.addEventListener("input", scheduleWrite);
      dom.addEventListener("bp-flush-node", flushPending);
      // Keep the resting-chrome gate in step as the user types a lang (empty→set
      // must not snap back to hidden while they are focused, and clearing it while
      // idle must re-hide it once blur+mouseleave settle).
      langInput.addEventListener("input", syncChrome);

      return {
        dom,
        // NO contentDOM — this is an atom; the textarea is NOT a PM content hole.
        // The text lives in the `value` attr, edited entirely outside ProseMirror.

        // Re-render the controls when the node's attrs change (echo/undo). Return
        // false for a different node type so PM rebuilds the view.
        update: (updated) => {
          if (updated.type.name !== BP_CODE_NODE_NAME) return false;
          paint(updated);
          return true;
        },

        // THE ISLAND CONTRACT: PM must NOT turn the textarea's events into
        // transactions. Returning true from stopEvent for every event in our DOM
        // tells ProseMirror "this is handled by the view, leave it alone" — so a
        // keystroke in the code never becomes a PM split/mutation/caret jump.
        stopEvent: () => true,

        // PM must NOT read the textarea's DOM mutations back into the document. The
        // textarea is outside any contentDOM; returning true tells PM's
        // MutationObserver to ignore every mutation under this node-view.
        ignoreMutation: () => true,

        destroy: () => {
          if (writeTimer) clearTimeout(writeTimer);
          area.removeEventListener("input", onAreaInput);
          langInput.removeEventListener("input", scheduleWrite);
          dom.removeEventListener("bp-flush-node", flushPending);
          langInput.removeEventListener("input", syncChrome);
          dom.removeEventListener("mouseenter", onEnter);
          dom.removeEventListener("mouseleave", onLeave);
          dom.removeEventListener("focusin", onFocusIn);
          dom.removeEventListener("focusout", onFocusOut);
        },
      };
    };
  },
});
