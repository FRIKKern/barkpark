// The words the reader shows for a prose block, taken by the reader's own fallbacks,
// so source mode can tell when a Markdown line would show other words than the page.
//
//   readerInline(block)        -> the inline runs the reader shows, or null for a
//                                 block that is not prose
//   readerInlineKey(block)     -> the key those runs come from ("content", "text",
//                                 "slots.body"), or null
//   readerInlineDiffers(block) -> true when the reader takes those words from another
//                                 key than the one the block's Markdown line carries
//
// The reader's fallbacks, each mirrored here:
//   paragraph, blockquote  compose.ex paragraph_inline/1: `content` when a non-empty
//                          list, else `text` when a non-empty string, else nothing
//                          (compose.ex's compose_block "blockquote" reads through it)
//   heading                compose.ex compose_block "heading": `content` when a
//                          non-empty list, else `text`
//   callout                slots.ex callout_body_inline/1: the first element of
//                          slots.body when that slot is a list (slot_elements/2),
//                          else `content` as the legacy body (legacy_slot/2); that
//                          element's `content` when non-empty, else the callout's `text`
// The Markdown line carries `text` for a heading and `content` for the rest
// (serialize.js), so a paragraph, quote or callout showing `text`, a heading showing
// `content`, and a callout showing its body slot all differ.

const LINE_KEY = { paragraph: "content", blockquote: "content", callout: "content", heading: "text" };

function filled(value) {
  return Array.isArray(value) && value.length > 0;
}

function textRuns(text) {
  return typeof text === "string" && text !== "" ? [{ type: "text", value: text }] : null;
}

// [key, runs]: the key the reader takes the words from and the runs it shows.
function readerSource(block) {
  if (block.type === "heading") {
    if (filled(block.content)) return ["content", block.content];
    const text = block.text == null ? "" : typeof block.text === "object" ? "" : String(block.text);
    return ["text", [{ type: "text", value: text }]];
  }
  if (block.type === "callout" && block.slots && Array.isArray(block.slots.body)) {
    const first = block.slots.body[0];
    if (first && typeof first === "object" && filled(first.content)) return ["slots.body", first.content];
    const runs = textRuns(block.text);
    return runs ? ["text", runs] : [null, []];
  }
  if (filled(block.content)) return ["content", block.content];
  const runs = textRuns(block.text);
  return runs ? ["text", runs] : [null, []];
}

export function readerInline(block) {
  if (!block || !LINE_KEY[block.type]) return null;
  return readerSource(block)[1];
}

export function readerInlineKey(block) {
  if (!block || !LINE_KEY[block.type]) return null;
  return readerSource(block)[0];
}

export function readerInlineDiffers(block) {
  if (!block || !LINE_KEY[block.type]) return false;
  const [key] = readerSource(block);
  return key !== null && key !== LINE_KEY[block.type];
}
