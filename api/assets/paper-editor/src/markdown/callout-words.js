// THE CALLOUT WORDS ANSWER (task-6a8137419e0153e4):
//
//   A callout's words are its content, then every block of its body slot, in that
//   order; reader, rich editor, source mode and export each show and write exactly
//   that.
//
// This is the one place the answer is written; code and tests that follow it name
// this file instead of saying it again. The Markdown export follows it (export.js).
// Not yet, for a callout holding both content and a body:
//   reader: shows the body's first block in place of content (Slots.callout_body_inline/1).
//   rich editor: shows the body's first block in place of content, and saves an edit over content (calloutBlockToNode).
//   source mode: shows the body's first block in place of content, and opens the Paper read-only (sourceSaved).

const isMap = (value) => value !== null && typeof value === "object" && !Array.isArray(value);

// The callout's body slot blocks, in order: what follows its content.
export function calloutBodyBlocks(block) {
  return isMap(block) && isMap(block.slots) && Array.isArray(block.slots.body) ? block.slots.body : [];
}
