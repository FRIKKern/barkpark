import {
  duplicateTopLevel,
  moveTopLevel,
  topLevelIndexAtSelection,
  turnTopLevelInto,
} from "./block-handle.js";
import { insertSlashTypeAtSelection } from "./command-palette.js";
import { isFigureSingletonCanvas } from "./figure-context.js";
import { slashTriggerAllowsParent } from "./slash-insert.js";

// Only a bare Enter closes an empty picker; Shift/Mod/Alt+Enter stay with it.
const hasModifier = (event) => event.shiftKey || event.metaKey || event.ctrlKey || event.altKey;

  // ── P4 autocomplete: keyboard routing + caret rect ─────────────────────────
  //
  // Keyboard handler installed via editorProps.handleKeyDown. Only ACTS when a
  // popup is open; otherwise returns false so TipTap handles the key (so Enter
  // still splits a block, ArrowUp still moves the caret, etc.). The three popups
  // (wikilink / tag / slash) are mutually exclusive — at most one branch ever owns
  // the keystroke. Ported from ../index.js:_onKeyDown (all three branches).
  export function _onKeyDown(event) {
    // Mod-Alt-c makes a code block (Tiptap's chord for it; StarterKit's codeBlock node is
    // off, so the canvas's own code node answers). event.code, because Alt+C types "ç" on a Mac.
    if (this._editable && this._editor && (event.metaKey || event.ctrlKey) && event.altKey && !event.shiftKey &&
        event.code === "KeyC" && !this._slash?.isOpen?.()) {
      event.preventDefault();
      // A top-level paragraph or heading is REPLACED by the code block, so its text moves
      // in; anywhere else the block lands after and the text stays where it was.
      const { $from } = this._editor.state.selection;
      const value = slashTriggerAllowsParent($from.depth, $from.parent.type.name)
        ? $from.parent.textBetween(0, $from.parent.content.size, "\n", "\n")
        : undefined;
      insertSlashTypeAtSelection(this._editor, "code", undefined, { value });
      return true;
    }
    if (this._editable && this._editor && (event.metaKey || event.ctrlKey) && !event.altKey) {
      const key = event.key;
      if (event.shiftKey && (key === "ArrowUp" || key === "ArrowDown")) {
        const index = topLevelIndexAtSelection(this._editor);
        event.preventDefault();
        moveTopLevel(this._editor, index, key === "ArrowUp" ? index - 1 : index + 1);
        return true;
      }
      if (!event.shiftKey && (key === "d" || key === "D")) {
        event.preventDefault();
        duplicateTopLevel(this._editor, topLevelIndexAtSelection(this._editor));
        return true;
      }
      // (Backspace handling sits below, outside the modifier branch.)
      // Turn-into chords: Mod-Shift-0 text, 1..3 headings, 4 checklist, 5 and 8 bulleted
      // (Notion's 5; Google Docs' and Tiptap's 8), 6 numbered. 7 is left to Tiptap's
      // ordered-list keymap. Code is Mod-Alt-c, above. event.code keeps them working on
      // layouts where Shift+digit yields a symbol.
      // Mod-Shift-4..6 are taken, so H1–H6 are ALSO on Mod-Alt-1..6 (StarterKit's heading
      // keymap for the six configured levels; Alt chords skip this branch).
      const digit = /^Digit([0-9])$/.exec(event.code || "")?.[1] ?? (/^[0-9]$/.test(key) ? key : null);
      if (event.shiftKey && digit != null && !this._slash?.isOpen?.()) {
        const kind = { 0: "paragraph", 1: "h1", 2: "h2", 3: "h3", 4: "task", 5: "bullet", 6: "ordered", 8: "bullet" }[digit];
        if (kind) {
          event.preventDefault();
          turnTopLevelInto(this._editor, topLevelIndexAtSelection(this._editor), kind);
          return true;
        }
      }
      if (!event.shiftKey && (key === "k" || key === "K") && this._bubble && !this._editor.state.selection.empty) {
        event.preventDefault();
        this._bubble.update();
        this._bubble.openLink();
        return true;
      }
      // No bubble: the host's toolbar edits the link (bp-canvas-link-request).
      if (!event.shiftKey && (key === "k" || key === "K") && !this._bubble && this._editable && !this._editor.state.selection.empty) {
        event.preventDefault();
        this._requestHostLink();
        return true;
      }
    }
    // Backspace at the very start of a block: a list item lifts out one level (a top-level item
    // becomes a paragraph) and a quote turns back into a paragraph, instead of merging into the
    // block above. Notion and Tiptap 3's list keymap behave this way.
    if (event.key === "Backspace" && !event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey && this._editable && this._editor) {
      const { $from, empty } = this._editor.state.selection;
      if (empty && $from.parentOffset === 0) {
        // Only the FIRST item of a list lifts; a later item keeps ProseMirror's join into the
        // item above, which is how an Enter-split is undone without losing nested children.
        const itemType = $from.depth >= 3 ? $from.node(-1).type.name : null;
        if ((itemType === "listItem" || itemType === "taskItem") && $from.index(-1) === 0 && $from.index(-2) === 0) {
          if (this._editor.commands.liftListItem(itemType)) { event.preventDefault(); return true; }
        }
        if ($from.depth === 1 && $from.parent.type.name === "pullquote") {
          event.preventDefault();
          this._editor.commands.setNode("paragraph");
          return true;
        }
        // A plain quote turns back into text the same way, keeping its id
        // (owner ruling 2026-10-03 #62), instead of joining the block above.
        if ($from.depth === 1 && $from.parent.type.name === "blockquote") {
          event.preventDefault();
          turnTopLevelInto(this._editor, $from.index(0), "paragraph");
          return true;
        }
      }
    }
    // P5 MARKDOWN SOURCE-MODE — Mod-Shift-m (Cmd-Shift-M on mac / Ctrl-Shift-M
    // elsewhere) ENTERS source mode from the rich editor. Detected FIRST, before the
    // palette/popup branches: it is a deliberately FREE combo (Mod-p = palette, Mod-b
    // = bold, Mod-i = italic, Mod-Shift-m collides with nothing in StarterKit or the
    // canvas). Only when editable. preventDefault + return true so ProseMirror does
    // not also act on the key. The toggle-BACK (source → rich) is handled by the
    // textarea's own keydown listener (_onSourceKeyDown), since while in source mode
    // ProseMirror's handleKeyDown never fires (the textarea owns input).
    if (
      this._editable &&
      (event.metaKey || event.ctrlKey) &&
      event.shiftKey &&
      !event.altKey &&
      (event.key === "m" || event.key === "M")
    ) {
      event.preventDefault();
      this.toggleSourceMode();
      return true;
    }

    // P5 command palette — Mod-p (Cmd-P on mac / Ctrl-P elsewhere) OPENS the palette.
    // Detected here, BEFORE the popup-routing branches, so the mutual-exclusion guard
    // can see whether any text-triggered popup is open. NOT shift (Cmd-Shift-P stays
    // free). Only when editable, and only when NO other popup ([[ / # / slash) is open
    // — if one is, Mod-p no-ops (mutual exclusion). On open we preventDefault (so the
    // browser's own Ctrl-P print / Cmd-P does not fire) and return true (ProseMirror
    // does not also act on the key).
    if (
      this._editable &&
      (event.metaKey || event.ctrlKey) &&
      !event.shiftKey &&
      !event.altKey &&
      (event.key === "p" || event.key === "P")
    ) {
      const anyPopupOpen =
        (this._wikilink && this._wikilink.isOpen()) ||
        (this._tag && this._tag.isOpen()) ||
        (this._emoji && this._emoji.isOpen()) ||
        (this._slash && this._slash.isOpen());
      // If the palette is ALREADY open, Mod-p closes it (toggle); else open it — but
      // never co-open alongside a text-triggered popup.
      if (this._palette && this._palette.isOpen()) {
        event.preventDefault();
        this._dismissPalette();
        return true;
      }
      if (!anyPopupOpen) {
        event.preventDefault();
        this._openPalette();
        return true;
      }
      // A text-triggered popup owns the moment — no-op (do NOT co-open). Still
      // preventDefault + return true so the browser's Ctrl-P print never fires and
      // ProseMirror does not act on the key; the open popup keeps its keystroke.
      event.preventDefault();
      return true;
    }

    // While the palette is open it OWNS the nav keys (↑/↓/Enter/Tab/Esc) — same
    // contract as the three text-triggered popups. Checked first among the routing
    // branches; it is mutually exclusive with them (only one popup ever open).
    if (this._palette && this._palette.isOpen()) {
      switch (event.key) {
        case "ArrowDown":
          this._palette.move(1);
          return true;
        case "ArrowUp":
          this._palette.move(-1);
          return true;
        case "Enter":
        case "Tab":
          this._palette.choose();
          return true;
        case "Escape":
          this._dismissPalette();
          return true;
        default:
          return false;
      }
    }

    if (this._wikilink && this._wikilink.isOpen()) {
      switch (event.key) {
        case "ArrowDown":
          this._wikilink.move(1);
          return true;
        case "ArrowUp":
          this._wikilink.move(-1);
          return true;
        case "Enter":
          if (this._wikilink.isEmpty() && !hasModifier(event)) {
            this._closeWikilink();
            return false;
          }
          this._wikilink.choose();
          return true;
        case "Tab":
          this._wikilink.choose();
          return true;
        case "Escape":
          this._dismissWikilink();
          return true;
        default:
          return false;
      }
    }

    // `:` emoji picker owns the nav keys while open — the same contract.
    if (this._emoji && this._emoji.isOpen()) {
      switch (event.key) {
        case "ArrowDown":
          this._emoji.move(1);
          return true;
        case "ArrowUp":
          this._emoji.move(-1);
          return true;
        case "Enter":
        case "Tab":
          this._emoji.choose();
          return true;
        case "Escape":
          this._dismissEmoji();
          return true;
        default:
          return false;
      }
    }

    // `#` tag menu owns the nav keys while open — same contract as the wikilink
    // branch above. The two are mutually exclusive (only one ever open), so the
    // order here is immaterial, but tag follows wikilink for symmetry.
    if (this._tag && this._tag.isOpen()) {
      switch (event.key) {
        case "ArrowDown":
          this._tag.move(1);
          return true;
        case "ArrowUp":
          this._tag.move(-1);
          return true;
        case "Enter":
          if (this._tag.isEmpty() && !hasModifier(event)) {
            this._closeTag();
            return false;
          }
          this._tag.choose();
          return true;
        case "Tab":
          this._tag.choose();
          return true;
        case "Escape":
          this._dismissTag();
          return true;
        default:
          return false;
      }
    }

    // `/` slash menu owns the nav keys while open — same contract. Mutually
    // exclusive with the two autocompletes (only one ever open), so order is
    // immaterial; slash follows tag for symmetry with onUpdate's chain. Enter must
    // pick the active item (NOT split the doc) while the menu is open.
    if (this._slash && this._slash.isOpen()) {
      switch (event.key) {
        case "ArrowDown":
          this._slash.move(1);
          return true;
        case "ArrowUp":
          this._slash.move(-1);
          return true;
        case "Enter":
        case "Tab":
          this._slash.choose();
          return true;
        case "Escape":
          this._dismissSlash();
          return true;
        default:
          return false;
      }
    }

    // Enter in the locked title (owner ruling 2026-10-03 #54, charter D6 amended):
    // still no split, no new block and no op — the caret moves to the first body
    // block, so the author keeps writing in the body instead of the title.
    if (
      this._editable &&
      event.key === "Enter" &&
      !event.shiftKey &&
      !event.metaKey &&
      !event.ctrlKey &&
      !event.altKey &&
      !event.isComposing &&
      this._enterFromLockedTitle()
    ) {
      event.preventDefault();
      return true;
    }

    if (
      this._editable &&
      isFigureSingletonCanvas(this) &&
      event.key === "Enter" &&
      !event.metaKey &&
      !event.ctrlKey &&
      !event.altKey &&
      this._editor.state.selection.$from.depth === 1 &&
      ["paragraph", "heading"].includes(
        this._editor.state.selection.$from.parent.type.name,
      )
    ) {
      event.preventDefault();
      this._showFigureConstraint();
      return true;
    }

    return false;
  }
