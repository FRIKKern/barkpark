import assert from "node:assert/strict";

import { docToBlocks, runToOps, runToTiptap } from "./run-convert.js";

const body = [{
  type: "paragraph",
  content: [{ type: "text", value: "Card body" }],
}];

function card(id, media) {
  return {
    id,
    type: "card",
    qa: { preserve: true },
    slots: {
      body,
      media: [{
        src: "/media/cover.jpg",
        alt: "Authored cover",
        qa: { assetId: "asset-1" },
        ...media,
      }],
      future: [{ opaque: true }],
    },
  };
}

for (const [name, media, expectedNode] of [
  ["type absent", {}, "bpCard"],
  ["exact image", { type: "image" }, "bpCard"],
  ["explicit null", { type: null }, "bpOpaque"],
  ["wrong paragraph type", { type: "paragraph" }, "bpOpaque"],
  ["wrong case", { type: "Image" }, "bpOpaque"],
  ["non-string type", { type: 1 }, "bpOpaque"],
]) {
  const source = card(`card-${name}`, media);
  const projected = runToTiptap([source]);
  const node = projected.content[0];

  assert.equal(node.type, expectedNode, `${name} follows the reader's exact media admission`);
  if (expectedNode === "bpOpaque") {
    assert.deepEqual(node.attrs.bpBlock, source,
      `${name} is carried as the exact authored fallback source`);
  } else {
    assert.deepEqual(node.attrs.media, source.slots.media[0],
      `${name} keeps all admitted image metadata outside the editable source field`);
  }
  assert.deepEqual(docToBlocks(projected), [source],
    `${name} round-trips without normalizing the media carrier or sibling slots`);
  assert.deepEqual(runToOps([source], projected), [],
    `${name} emits no operation when the projected fallback remains untouched`);
}

console.log("PASS Card media admission: absent/image exact; null and malformed preserved opaque");
