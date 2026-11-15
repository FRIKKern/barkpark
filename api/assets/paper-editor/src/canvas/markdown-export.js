// toMarkdown() (contract 1.23.0): Markdown for a file the writer takes away
// (../markdown/export.js), not the round-trip Markdown of source mode.
//
// With `blocks` it converts those and needs no mount. Without, it converts the
// run as it is on screen, unsaved typing included (recoverySnapshot's read; in
// source mode, the textarea's text as blocks), or the saved baseline before
// mount. It only reads: no op, no flush, and it works in a read-only canvas.
import { blocksToExportMarkdown } from "../markdown.js";

export function canvasToMarkdown(canvas, options) {
  const opts = options && typeof options === "object" ? options : {};
  const baseUrl = typeof opts.baseUrl === "string" ? opts.baseUrl : (typeof document !== "undefined" && document.baseURI) || "";
  let blocks = opts.blocks;
  if (!Array.isArray(blocks)) {
    const live = canvas._editor && !canvas._editor.isDestroyed ? canvas.recoverySnapshot() : null;
    blocks = live && Array.isArray(live.blocks) ? live.blocks : canvas.blocks;
  }
  return blocksToExportMarkdown(blocks, { baseUrl, placeholder: opts.placeholder });
}
