// The fast path matches full projection across the real pd-parity inventory.
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { paragraphs } from "../paper-editor/src/canvas/__emit_bench.mjs";
import { script } from "../paper-editor/src/canvas/__emit_fast_path_support.mjs";

const GOLD = new URL("../../test/support/fixtures/pd-parity/", import.meta.url);
const inventory = [];
for (const f of readdirSync(GOLD).sort()) {
  const g = JSON.parse(readFileSync(new URL(f, GOLD), "utf8"));
  const input = Array.isArray(g.input) ? g.input[0] : g.input;
  if (!input || !input.type) continue;
  inventory.push({ ...structuredClone(input), id: `inv-${input.type}` });
}
assert.ok(inventory.length > 0, "the pd-parity inventory contributes at least one valid block");
const mixed = [];
paragraphs(inventory.length + 1).forEach((p, i) => { mixed.push(p); if (inventory[i]) mixed.push(inventory[i]); });
await script(mixed, "inventory");

console.log("emit_fast_path inventory: ok");
process.exit(0);
