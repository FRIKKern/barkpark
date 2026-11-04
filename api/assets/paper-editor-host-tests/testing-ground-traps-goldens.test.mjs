import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { duplicateIds } from "../paper-editor/src/testing-ground/traps.mjs";

const pack = new URL("../../priv/portable_doc/goldens/blocks/", import.meta.url);
for (const name of readdirSync(pack)) {
  const { type, input } = JSON.parse(readFileSync(new URL(name, pack), "utf8"));
  assert.deepEqual(duplicateIds([{ id: `s-${type}`, ...input }]), [], `${type}: the pack sample opens with no duplicate ids`);
}
