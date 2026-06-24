// wikilink-trigger.js — the PURE, DOM-free seam of the `[[` wikilink
// autocomplete. Decides WHEN the popup should be open and what the live query
// is, given the current block-local text + caret offset. Kept DOM-free (no
// document, no TipTap, no HTMLElement) for the same reason as marks.js /
// contract.js: so it is unit-testable in plain Node (see __wikilink.test.mjs).
//
// The browser half — the caret-anchored popup, keyboard routing, and the async
// candidate request/response — lives in the (forthcoming) wikilink-menu.js and
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
