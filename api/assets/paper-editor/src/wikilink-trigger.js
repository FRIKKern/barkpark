// wikilink-trigger.js — the PURE, DOM-free seam of the `[[` wikilink AND `#` tag
// autocompletes. Decides WHEN each popup should be open and what the live query
// is, given the current block-local text + caret offset. Kept DOM-free (no
// document, no TipTap, no HTMLElement) for the same reason as marks.js /
// contract.js: so it is unit-testable in plain Node (see __wikilink.test.mjs).
//
// The browser half — the caret-anchored popup, keyboard routing, and the async
// candidate request/response — lives in wikilink-menu.js (reused for both) and
// index.js wiring, and is exercised only in the live editor. This module is the
// part the trigger logic can be proven correct without a browser.

/**
 * Parse the text BEFORE the caret for an open, same-line, unfinished `[[`
 * trigger. Returns `{ query, from, to }` (the live query string and the
 * inclusive `[[`…caret range to replace on pick) when the popup should be open,
 * else `null`.
 *
 * `text` is the BLOCK-LOCAL text (a single textblock's content); `caretOffset`
 * is the caret position within it (clamped into range). Feeding whole-document
 * text with a block-local offset is a caller bug — keep them in the same frame.
 *
 * @param {string} text
 * @param {number} caretOffset
 * @returns {{query: string, from: number, to: number} | null}
 */
export function parseOpenWikilink(text, caretOffset) {
  if (typeof text !== "string" || typeof caretOffset !== "number") return null;

  const off = Math.max(0, Math.min(caretOffset, text.length));
  const before = text.slice(0, off);

  // lastIndexOf gives the NEAREST `[[` before the caret — so a closed `[[x]]`
  // earlier in the line never shadows a later open one.
  const open = before.lastIndexOf("[[");
  if (open === -1) return null;

  // Text between the nearest `[[` and the caret. A `]]` (closed), a second `[[`
  // (the query resets to the newer one), or a newline (the `[[` is not a
  // same-line, unfinished trigger) all mean: do not open.
  const between = before.slice(open + 2);
  if (between.includes("]]") || between.includes("[[") || between.includes("\n")) {
    return null;
  }

  return { query: between, from: open, to: off };
}

/**
 * Map a live `[[query` trigger to the ProseMirror document positions to replace
 * on pick. The typed span is `"[[" + query` ending exactly AT the caret, so the
 * replace range runs from `caretPos - query.length - 2` (the `[[`) up to
 * `caretPos`. Isolated here as a unit-testable seam so the off-by-one (the two
 * `[` chars) lives in ONE provable place rather than inline in index.js.
 *
 * `caretPos` is a ProseMirror document position (`selection.from`), NOT a
 * block-local offset — feed it `this._editor.state.selection.from`. `from` is
 * clamped to `>= 0` so a malformed call can never produce a negative position.
 *
 * @param {number} caretPos
 * @param {string} query
 * @returns {{from: number, to: number}}
 */
export function wikilinkReplaceRange(caretPos, query) {
  const to = typeof caretPos === "number" ? caretPos : 0;
  const len = typeof query === "string" ? query.length : 0;
  const from = Math.max(0, to - len - 2);
  return { from, to };
}

// Valid tag-query characters: letters, digits, dash, underscore, slash (slash
// for nested Obsidian tags like `#area/work`). A space, newline, or any other
// punctuation ends the query. Anchored test against the WHOLE between-string so
// one bad char anywhere in the span keeps the popup shut.
const TAG_QUERY_RE = /^[A-Za-z0-9/_-]*$/;

/**
 * Parse the text BEFORE the caret for an open `#` TAG trigger — the `#` analogue
 * of parseOpenWikilink. Returns `{ query, from, to }` (the live query string and
 * the inclusive `#`…caret range) when the tag popup should be open, else `null`.
 *
 * Trigger boundary (quality-critical — "#" is common in prose):
 *   • The `#` is the nearest one before the caret (lastIndexOf).
 *   • It must be a SIGIL: at block start, OR immediately preceded by whitespace.
 *     A mid-word "#" (e.g. `C#`, `issue #5` typed as `5#`… i.e. `#` glued to a
 *     preceding non-space char) is NOT a sigil → null.
 *   • The char right after the `#` must NOT be another `#` → `##` headings never
 *     trigger.
 *   • The query (chars between `#` and caret) must contain ONLY valid tag chars
 *     [A-Za-z0-9/_-] AND at least one letter; a bare `#`, a pure-numeric `#5`,
 *     or any whitespace/newline/other punctuation in the span → null.
 *
 * `text` is the BLOCK-LOCAL text; `caretOffset` is the caret position within it
 * (clamped). Same block-local contract as parseOpenWikilink.
 *
 * @param {string} text
 * @param {number} caretOffset
 * @returns {{query: string, from: number, to: number} | null}
 */
export function parseOpenTag(text, caretOffset) {
  if (typeof text !== "string" || typeof caretOffset !== "number") return null;

  const off = Math.max(0, Math.min(caretOffset, text.length));
  const before = text.slice(0, off);

  // Nearest `#` before the caret — so an earlier completed `#tag word` never
  // shadows a later open one.
  const hash = before.lastIndexOf("#");
  if (hash === -1) return null;

  // SIGIL boundary: the `#` must be at block start or immediately preceded by
  // whitespace. A non-space char right before it (e.g. the `C` in `C#`) means
  // it is a mid-word `#`, not a tag sigil.
  if (hash > 0) {
    const prev = before[hash - 1];
    if (!/\s/.test(prev)) return null;
  }

  // `##` (and `###…`) never trigger: a second `#` right after the sigil is a
  // heading shorthand, not a tag.
  if (before[hash + 1] === "#") return null;

  // Chars between the `#` and the caret are the live query. Reject the whole
  // span unless every char is a valid tag char (this also rejects an embedded
  // space or newline, which END the query).
  const between = before.slice(hash + 1);
  if (!TAG_QUERY_RE.test(between)) return null;

  // Require a real tag: at least one LETTER (Obsidian tags must contain a
  // non-numeric char). This suppresses the lone-`#` flash and stops common
  // prose — `press # to confirm`, `issue #5`, `PR #42` — from opening an empty
  // menu, while still accepting `#v2`, `#2024-recap`, `#area/work`, etc.
  if (!/[A-Za-z]/.test(between)) return null;

  return { query: between, from: hash, to: off };
}

/**
 * Map a live `#query` trigger to the ProseMirror positions to replace on pick.
 * The typed span is `"#" + query` ending exactly AT the caret, so the replace
 * range runs from `caretPos - query.length - 1` (the single `#`) up to
 * `caretPos`. The `#`-analogue of wikilinkReplaceRange — the off-by-one (one `#`
 * char, vs the two `[` of a wikilink) lives in ONE provable place.
 *
 * `caretPos` is a ProseMirror document position (`selection.from`), NOT a
 * block-local offset. `from` is clamped to `>= 0`.
 *
 * @param {number} caretPos
 * @param {string} query
 * @returns {{from: number, to: number}}
 */
export function tagReplaceRange(caretPos, query) {
  const to = typeof caretPos === "number" ? caretPos : 0;
  const len = typeof query === "string" ? query.length : 0;
  const from = Math.max(0, to - len - 1);
  return { from, to };
}
