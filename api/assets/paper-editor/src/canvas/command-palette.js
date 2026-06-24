// canvas/command-palette.js — Phase-5 COMMAND PALETTE for <bp-paper-canvas>.
//
// The Obsidian Cmd-P analog: a fuzzy, keyboard-triggered launcher over editor
// COMMANDS (NOT a typed "/" trigger). The quick-switcher (Cmd-O, "navigate to a
// paper") already ships server-side; this is the Cmd-P half — "run an editor
// command". Canvas-only, flag-gated: <bp-paper-editor> (src/index.js) is byte-
// unchanged. Opened by the canvas on Mod-p (see canvas/index.js _onKeyDown /
// editorProps.handleKeyDown).
//
// TWO exports, split PURE vs DOM:
//   buildCommandRegistry(editor?) — PURE. The static command registry: an array of
//       { id, label, group, hint?, run(editor) }. Insert commands REUSE the canvas
//       slash primitives (slashTypeToNode + the same replace/insert logic, factored
//       into insertSlashTypeAtSelection); Format commands toggle the marks already
//       registered in the canvas StarterKit; Turn-into commands set the current
//       block via the TipTap node commands. NO DOM — unit-testable in plain Node.
//   CommandPalette — the popup. A THIN subclass of SlashMenu that reuses its entire
//       render/keyboard/positioning machinery (grouped, filtered, arrow-navigable
//       rows; Enter/Tab pick; Esc dismiss) and only re-parameterizes the eyebrow,
//       footer, filter (fuzzy over label+group), and positioning (centered modal).
//
// insertSlashTypeAtSelection is shared by the canvas slash pick (_chooseSlash) AND
// the palette's Insert commands, so an Insert command produces the EXACT same block
// the slash menu does (default_block parity, asserted in __smoke.mjs).

import { SlashMenu } from "../slash-menu.js";
import { TextSelection, NodeSelection } from "@tiptap/pm/state";
import {
  CANVAS_SLASH_TYPES,
  slashTypeToNode,
  CANVAS_SLASH_TEXTABLE_NODES,
  slashTriggerAllowsParent,
} from "./slash-insert.js";

// ── the shared "insert a canvas default node, replacing the caret block" seam ──
//
// FACTORED OUT of canvas/index.js _chooseSlash so the slash pick AND the palette's
// Insert commands share ONE code path → an Insert command is guaranteed to produce
// the SAME block the slash menu does. Pure-ish: it touches the live editor (PM
// transaction) but is keyed only on the editor's state/selection, no popup DOM.
//
// Behavior (identical to _chooseSlash before this refactor):
//   * type NOT in CANVAS_SLASH_TYPES → no-op (defensive; e.g. a picker field).
//   * The TOP-LEVEL-PROSE guard (slashTriggerAllowsParent): only when the caret sits
//     in a paragraph/heading that is a DIRECT child of the doc do we REPLACE that
//     whole block with the new node. Inside a callout body / list item / non-prose
//     parent the replace would corrupt the enclosing node — so we DEGRADE SAFELY by
//     inserting the node at the nearest valid spot (insertAfter the enclosing top-
//     level node) instead of replacing, and never split the run. This honors the
//     same guard the slash menu uses while keeping the palette command non-failing.
//   * On a top-level-prose caret: replaceWith(before, after, node) — same as the
//     slash pick. The new node carries bpId:null so runToOps mints a fresh id and
//     emits ONE insert-after (or append on an empty run).
//   * Caret placement: INTO the body for a textable node (prose/callout), or a
//     NodeSelection on the atom (divider/code/diagram/field).
//
// Returns true iff a node was inserted, false on the no-op (non-insertable type).
export function insertSlashTypeAtSelection(editor, type, fieldName) {
  if (!editor || !CANVAS_SLASH_TYPES.has(type)) return false;

  const node = slashTypeToNode(type);
  // EXPECTED-style binding plumb-through (parity with _chooseSlash): thread the
  // field name onto the node so a bound-field insert round-trips. Harmless when
  // absent (the common palette case — palette Insert commands are unbound).
  if (fieldName && node && node.attrs) {
    node.attrs.fieldName = fieldName;
  }

  const { state, view } = editor;
  const $pos = state.selection.$from;
  const newNode = state.schema.nodeFromJSON(node);

  let tr;
  let caretAnchor; // doc position the new node starts at (for caret placement)

  if (slashTriggerAllowsParent($pos.depth, $pos.parent.type.name)) {
    // TOP-LEVEL PROSE: replace the whole enclosing block (identical to the slash
    // pick — start=$pos.before(depth), end=$pos.after(depth)).
    const start = $pos.before($pos.depth);
    const end = $pos.after($pos.depth);
    tr = state.tr.replaceWith(start, end, newNode);
    caretAnchor = start;
  } else {
    // DEGRADE SAFELY: the caret is inside a callout body / list item / other non-
    // top-level-prose node. Do NOT replace (that would corrupt the container).
    // Insert the new node AFTER the nearest TOP-LEVEL node so it lands at a valid
    // top-level spot without splitting the run. depth>=1 always has a depth-1
    // ancestor; after(1) is the position just past that top-level node.
    const insertAt = $pos.depth >= 1 ? $pos.after(1) : state.doc.content.size;
    tr = state.tr.insert(insertAt, newNode);
    caretAnchor = insertAt;
  }

  // Caret placement — same rule as _chooseSlash. Best-effort; the insert already
  // landed even if selection placement throws.
  try {
    if (CANVAS_SLASH_TEXTABLE_NODES.has(node.type)) {
      tr = tr.setSelection(TextSelection.near(tr.doc.resolve(caretAnchor + 1)));
    } else {
      tr = tr.setSelection(NodeSelection.create(tr.doc, caretAnchor));
    }
  } catch (_e) {
    // Selection placement is best-effort; the insert itself already landed.
  }
  view.dispatch(tr);
  editor.commands.focus();
  return true;
}

// ── the command registry ─────────────────────────────────────────────────────
//
// Static array of { id, label, group, hint?, run(editor) }, fuzzy-filtered by the
// typed query. Three groups mirror the task:
//   Insert    — one per CANVAS_SLASH_TYPES entry; run() inserts the default node
//               EXACTLY like the slash pick (via insertSlashTypeAtSelection).
//   Format    — toggle bold/italic/strike/code + clear formatting, on the selection.
//   Turn into — set the current block to paragraph / heading 1-3 / bullet / ordered.
//
// The per-type Insert metadata (label/hint) is read from the slash menu's own item
// list so the palette's Insert rows match the slash rows (no duplicate copy of the
// labels). buildInsertItemMeta below maps each insertable type to its { label, hint }.

// Human label + glyph per insertable type, in CANVAS_SLASH_TYPES order. Mirrors the
// slash menu's SLASH_ITEMS rows (label/hint) for the same types — kept here as a small
// explicit table so the registry is PURE (no DOM read) and stable across the canvas.
const INSERT_META = {
  paragraph: { label: "Paragraph", hint: "¶" },
  heading: { label: "Heading", hint: "H" },
  list: { label: "List", hint: "•" },
  callout: { label: "Callout", hint: "!" },
  code: { label: "Code", hint: "</>" },
  divider: { label: "Divider", hint: "—" },
  diagram: { label: "Diagram", hint: "⬡" },
  "field-string": { label: "String", hint: "T" },
  "field-slug": { label: "Slug", hint: "/" },
  "field-text": { label: "Long text", hint: "¶" },
  "field-boolean": { label: "Boolean", hint: "✓" },
  "field-select": { label: "Select", hint: "▾" },
  "field-datetime": { label: "Date & time", hint: "◷" },
  "field-color": { label: "Color", hint: "●" },
};

// Stable insertion order for the Insert group (CANVAS_SLASH_TYPES is a Set; pin the
// order so the registry is deterministic and matches the slash menu's reading order).
const INSERT_ORDER = [
  "paragraph",
  "heading",
  "list",
  "callout",
  "code",
  "divider",
  "diagram",
  "field-string",
  "field-slug",
  "field-text",
  "field-boolean",
  "field-select",
  "field-datetime",
  "field-color",
];

// The FORMAT toggle commands. id, label, the StarterKit toggle command name, and the
// `isActive` mark name. Underline is OMITTED here and added conditionally below ONLY
// when the live editor actually registers it (the canvas StarterKit ships bold /
// italic / strike / code marks; it does NOT register underline, and this feature adds
// no dependency — so an underline command is offered only if some host registered it).
const FORMAT_TOGGLES = [
  { id: "format-bold", label: "Bold", hint: "B", cmd: "toggleBold", mark: "bold" },
  { id: "format-italic", label: "Italic", hint: "I", cmd: "toggleItalic", mark: "italic" },
  { id: "format-strike", label: "Strikethrough", hint: "S", cmd: "toggleStrike", mark: "strike" },
  { id: "format-code", label: "Code", hint: "</>", cmd: "toggleCode", mark: "code" },
];

// True when the live editor's command registry exposes `name` (so we only offer a
// command the editor can actually run). When no editor is passed (pure registry
// build for tests) we ASSUME the canvas StarterKit set (bold/italic/strike/code +
// the node commands) is present — the static registry is the documented contract.
function editorHasCommand(editor, name) {
  if (!editor) return true; // pure build: trust the canvas StarterKit contract
  try {
    return typeof editor.commands[name] === "function";
  } catch (_e) {
    return false;
  }
}

// buildCommandRegistry(editor?, opts?) → the full command list. `editor` is OPTIONAL:
// when absent (pure test build) the full canvas StarterKit command set is assumed;
// when present, each command is filtered to one the editor can actually run (so a host
// that omitted, say, the strike mark never shows a dead Strike row, and underline
// shows up only if registered).
//
// `opts.onToggleSource` is the canvas's toggleSourceMode method (the WC owns the rich/
// source swap, not the editor). When provided, a "View" group is appended with a
// "Toggle Markdown source" command whose run() flips the mode — the SAME method the
// Mod-Shift-m shortcut calls. Absent in the pure test build (no canvas), so the View
// group simply does not appear there; the registry stays well-formed either way.
export function buildCommandRegistry(editor, opts) {
  const cmds = [];

  // INSERT — one per canvas-insertable type; run() reuses the slash insert seam.
  for (const type of INSERT_ORDER) {
    const meta = INSERT_META[type];
    if (!meta) continue;
    cmds.push({
      id: `insert-${type}`,
      label: `Insert ${meta.label}`,
      group: "Insert",
      hint: meta.hint,
      // Insert the default node EXACTLY like the slash pick. Honors the same top-
      // level-prose guard (degrades safely inside a callout body / list item).
      run: (ed) => insertSlashTypeAtSelection(ed, type),
    });
  }

  // FORMAT — toggle marks on the current selection (only those the editor has).
  for (const f of FORMAT_TOGGLES) {
    if (!editorHasCommand(editor, f.cmd)) continue;
    cmds.push({
      id: f.id,
      label: `Format ${f.label}`,
      group: "Format",
      hint: f.hint,
      run: (ed) => ed.chain().focus()[f.cmd]().run(),
    });
  }
  // Underline only if the live editor registered it (no dependency added here).
  if (editor && editorHasCommand(editor, "toggleUnderline")) {
    cmds.push({
      id: "format-underline",
      label: "Format Underline",
      group: "Format",
      hint: "U",
      run: (ed) => ed.chain().focus().toggleUnderline().run(),
    });
  }
  // Clear formatting — unset every mark on the selection.
  if (editorHasCommand(editor, "unsetAllMarks")) {
    cmds.push({
      id: "format-clear",
      label: "Clear formatting",
      group: "Format",
      hint: "⌫",
      run: (ed) => ed.chain().focus().unsetAllMarks().run(),
    });
  }

  // TURN INTO — set the current block via the TipTap node commands.
  const turnInto = [
    { id: "turn-paragraph", label: "Paragraph", hint: "¶", run: (ed) => ed.chain().focus().setParagraph().run(), need: "setParagraph" },
    { id: "turn-h1", label: "Heading 1", hint: "H", run: (ed) => ed.chain().focus().toggleHeading({ level: 1 }).run(), need: "toggleHeading" },
    { id: "turn-h2", label: "Heading 2", hint: "H", run: (ed) => ed.chain().focus().toggleHeading({ level: 2 }).run(), need: "toggleHeading" },
    { id: "turn-h3", label: "Heading 3", hint: "H", run: (ed) => ed.chain().focus().toggleHeading({ level: 3 }).run(), need: "toggleHeading" },
    { id: "turn-bullet", label: "Bullet list", hint: "•", run: (ed) => ed.chain().focus().toggleBulletList().run(), need: "toggleBulletList" },
    { id: "turn-ordered", label: "Ordered list", hint: "1.", run: (ed) => ed.chain().focus().toggleOrderedList().run(), need: "toggleOrderedList" },
  ];
  for (const t of turnInto) {
    if (!editorHasCommand(editor, t.need)) continue;
    cmds.push({
      id: t.id,
      label: `Turn into ${t.label}`,
      group: "Turn into",
      hint: t.hint,
      run: t.run,
    });
  }

  // VIEW — the markdown source-mode toggle. Only when the canvas wired an
  // onToggleSource callback (it owns the rich⇄source swap, not the editor). run()
  // ignores the editor arg and calls the canvas toggle — the SAME method Mod-Shift-m
  // calls — so both triggers are identical. Omitted in the pure test build (no canvas).
  if (opts && typeof opts.onToggleSource === "function") {
    cmds.push({
      id: "view-toggle-source",
      label: "Toggle Markdown source",
      group: "View",
      hint: "</>",
      run: () => opts.onToggleSource(),
    });
  }

  return cmds;
}

// ── fuzzy filter ─────────────────────────────────────────────────────────────
//
// Subsequence fuzzy match over `label + " " + group` (Obsidian-style): every char
// of the query must appear, in order, somewhere in the haystack (gaps allowed).
// Case-insensitive. An empty query passes everything. PURE — exported for tests.
export function fuzzyMatch(query, hay) {
  const q = (query || "").trim().toLowerCase();
  if (!q) return true;
  const h = (hay || "").toLowerCase();
  let qi = 0;
  for (let hi = 0; hi < h.length && qi < q.length; hi++) {
    if (h[hi] === q[qi]) qi++;
  }
  return qi === q.length;
}

// Filter a registry by the fuzzy query over each command's `label` + `group`.
// PURE — exported so the smoke can assert "cal" → Insert Callout, "bold" → Format
// Bold, etc. Preserves registry order (so grouped rendering stays group-contiguous).
export function fuzzyFilterCommands(commands, query) {
  const q = (query || "").trim();
  if (!q) return commands.slice();
  return commands.filter((c) => fuzzyMatch(q, `${c.label || ""} ${c.group || ""}`));
}

// ── the popup ────────────────────────────────────────────────────────────────
//
// A THIN subclass of SlashMenu: reuses ALL of its render/keyboard/positioning/
// outside-click machinery and only re-parameterizes the eyebrow ("Run command"),
// the footer chips ("run" not "insert"), the filter (fuzzy over label+group via the
// SlashMenu `filter` seam), and the positioning (centered modal, _position override).
// The static command registry is the item list; readExtraItems is a no-op so the
// palette is NEVER EXPECTED-augmented (that is the slash menu's behavior only).
//
// SlashMenu's `choose()` calls onChoose(item) with the active row; the canvas wires
// onChoose to run the command's run(editor), then close + refocus. The rows render
// via the shared `.bp-slash-*` DOM/CSS (no styling drift); the `bp-cmd-palette`
// modifier class only hangs the centered position off the same DOM.
export class CommandPalette extends SlashMenu {
  constructor({ commands, onChoose, onDismiss }) {
    super({
      items: commands || [],
      onChoose,
      onDismiss,
      eyebrow: "Run command",
      extraClass: "bp-cmd-palette",
      emptyText: "No commands match",
      footHtml:
        "<kbd>↵</kbd> run <span class=\"bp-slash-foot-sep\">·</span> " +
        "<kbd>↑</kbd><kbd>↓</kbd> navigate " +
        "<span class=\"bp-slash-foot-sep\">·</span> <kbd>esc</kbd> dismiss",
      // Fuzzy over the WHOLE registry by label+group (no doc text consumed).
      filter: (allItems, query) => fuzzyFilterCommands(allItems, query),
      // The palette's items are the static registry — never EXPECTED-augmented.
      readExtraItems: () => [],
    });
  }

  // Replace the command list (the canvas rebuilds it against the live editor on each
  // open so command availability — e.g. underline — reflects the current editor).
  setCommands(commands) {
    this._baseItems = commands || [];
  }

  // Override open() to clear the query each time (the palette is keyboard-triggered,
  // not driven by re-opens with a growing doc-text query) and focus its input so the
  // user can type the fuzzy filter immediately. Then delegate to SlashMenu.open with
  // an empty query (positioning + render + filter all run there).
  open(rect, _query = "") {
    super.open(rect, "");
    // Focus the input after the popup is shown so the cursor lands in it (the user
    // types the filter; arrow/enter/esc are handled by the input keydown below).
    if (this._input) {
      this._input.value = "";
      try {
        this._input.focus();
      } catch (_e) {
        // focus is best-effort (e.g. a detached test env).
      }
    }
  }

  // Render the query <input> under the eyebrow (the SlashMenu hook). The input is a
  // PERSISTENT element held on `this._input` and RE-APPENDED each render (SlashMenu's
  // _render clears innerHTML), so its value + caret + focus survive a row re-render
  // when the user types. Its `input` event re-filters live; its keydown owns the
  // navigation keys (the palette has stolen focus from the editor, so ProseMirror's
  // handleKeyDown does NOT see these — the canvas _onKeyDown branch is a fallback for
  // the JS-dispatched / editor-focused path only).
  _renderQueryInput(parentEl) {
    if (!this._input) {
      const input = document.createElement("input");
      input.className = "bp-cmd-input";
      input.type = "text";
      input.setAttribute("placeholder", "Type a command…");
      input.setAttribute("aria-label", "Command palette filter");
      input.autocomplete = "off";
      input.spellcheck = false;
      // Live fuzzy re-filter. Update the query, re-filter, re-render the rows. We
      // do NOT re-run the full open() (that would reset the input). Re-render keeps
      // the input (re-appended) so focus/caret survive.
      input.addEventListener("input", () => {
        const caret = input.selectionStart;
        this._query = input.value;
        this._applyFilter();
        this._active = 0;
        // _render clears the popup innerHTML (detaching + blurring the input) and
        // re-appends this SAME input node via _renderQueryInput. Restore its focus +
        // caret + value so continuous typing is seamless.
        this._render();
        this._syncActive();
        if (this._input) {
          try {
            this._input.focus();
            if (caret != null) this._input.setSelectionRange(caret, caret);
          } catch (_e) {
            // focus/caret restore is best-effort.
          }
        }
      });
      // Navigation keys while focus is in the input.
      input.addEventListener("keydown", (e) => {
        // Mod-p again toggles the palette CLOSED (and swallows the browser's
        // Ctrl-P / Cmd-P print so it never fires while the palette owns focus).
        if (
          (e.metaKey || e.ctrlKey) &&
          !e.shiftKey &&
          !e.altKey &&
          (e.key === "p" || e.key === "P")
        ) {
          e.preventDefault();
          this._onDismiss();
          return;
        }
        switch (e.key) {
          case "ArrowDown":
            e.preventDefault();
            this.move(1);
            break;
          case "ArrowUp":
            e.preventDefault();
            this.move(-1);
            break;
          case "Enter":
          case "Tab":
            e.preventDefault();
            this.choose();
            break;
          case "Escape":
          case "Esc":
            e.preventDefault();
            this._onDismiss();
            break;
          default:
            break;
        }
      });
      this._input = input;
    }
    parentEl.appendChild(this._input);
  }

  // Drop the persistent input on destroy (the base destroy removes the popup root).
  destroy() {
    super.destroy();
    this._input = null;
  }

  // Centered-ish modal positioning (Obsidian Cmd-P is a centered modal), overriding
  // SlashMenu's caret-anchored _position. The incoming rect is IGNORED — the palette
  // floats centered horizontally and pinned to the upper third vertically. Reuses the
  // shared popup chrome; only the placement differs.
  _position(_rect) {
    if (!this._el) return;
    this._el.style.display = "block";
    this._el.style.position = "fixed";

    const menuRect = this._el.getBoundingClientRect();
    const margin = 8;
    let left = Math.round((window.innerWidth - menuRect.width) / 2);
    if (left < margin) left = margin;
    // Pin near the upper third — the Obsidian-modal resting spot.
    let top = Math.round(window.innerHeight * 0.18);
    if (top + menuRect.height > window.innerHeight - margin) {
      top = Math.max(margin, window.innerHeight - menuRect.height - margin);
    }
    this._el.style.top = `${top}px`;
    this._el.style.left = `${left}px`;
  }
}
