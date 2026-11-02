import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { applyOps } from "../smoke/reference-fold.mjs";
import { trip } from "./drills/trip.mjs";
import { barkparkFold } from "./barkpark-fold.mjs";
import { createFakeHost } from "./fake-host.mjs";
import { referenceFold } from "./fold.mjs";
import { duplicateIds, foldDrift, hiddenBlocks, lights, lostKeys, sentDuplicates } from "./traps.mjs";

const light = (list, key) => list.find((l) => l.key === key);
const calm = { visibility: [true], believed: [], saved: [], batches: [], refusals: [], settled: true, reload: null };

const d01OnMain = [true, false, false, false, false, false, false, true, true];
assert.deepEqual(hiddenBlocks(d01OnMain), { doc: 9, shown: 3, hidden: 6, extra: 5 });
assert.deepEqual(hiddenBlocks([true, false, false, false, false, false, false, false, true]).extra, 6);
assert.equal(hiddenBlocks([true, false, true]).extra, 0, "one resting scaffold is not a hidden block");
assert.equal(hiddenBlocks([false, true, false, true, false]).extra, 0, "one resting scaffold per gap, at either edge too");
assert.equal(light(lights({ ...calm, visibility: d01OnMain }), "hidden-blocks").ok, false);
assert.match(light(lights({ ...calm, visibility: d01OnMain }), "hidden-blocks").words, /5 lines are in the doc but hidden on screen \(9 blocks, 3 shown\)/);
assert.equal(light(lights({ ...calm, visibility: [true, false, true] }), "hidden-blocks").ok, true);

const split = structuredClone(trip);
split[1].blocks.splice(1, 0, { id: "p-day", type: "paragraph", content: [{ type: "text", value: "Fog by eight." }] });
assert.deepEqual(duplicateIds(split), ["p-day"], "a nested split that keeps p-day is a duplicate at depth 2");
assert.deepEqual(duplicateIds(trip), []);
const nestedEnter = { seq: 1, ops: [{ op: "replace-block", id: "s-day", block: split[1] }] };
assert.deepEqual(sentDuplicates([nestedEnter]), ["p-day"], "the batch carries the duplicate even when the server refuses it");
assert.deepEqual(sentDuplicates([{ seq: 1, ops: [{ op: "replace-block", id: "s-day", block: trip[1] }] }]), [], "an op naming its own block is not a duplicate");
assert.equal(light(lights({ ...calm, batches: [nestedEnter] }), "duplicate-ids").ok, false);
assert.match(light(lights({ ...calm, saved: split }), "duplicate-ids").words, /Used twice: p-day/);

const pack = new URL("../../../../priv/portable_doc/goldens/blocks/", import.meta.url);
for (const name of readdirSync(pack)) {
  const { type, input } = JSON.parse(readFileSync(new URL(name, pack), "utf8"));
  assert.deepEqual(duplicateIds([{ id: `s-${type}`, ...input }]), [], `${type}: the pack sample opens with no duplicate ids`);
}

assert.throws(() => applyOps(trip, nestedEnter.ops), /replace-block: duplicate id p-day/, "the reference fold refuses the nested Enter batch, as patch.ex does");
const legacy = [...structuredClone(split), { id: "p-new", type: "paragraph", content: [] }];
assert.doesNotThrow(() => applyOps(split, [{ op: "patch-block", id: "p-after", patch: { content: [] } }]), "a duplicate already there stays editable");
assert.throws(() => applyOps(legacy, [{ op: "insert-after", afterId: "p-new", block: { id: "p-day", type: "paragraph", content: [] } }]), /duplicate id p-day/);

const refused = lights({ ...calm, refusals: ["replace-block: duplicate id p-day"] });
assert.equal(light(refused, "refused-batches").ok, false);
assert.match(light(refused, "refused-batches").words, /refused 1 batch: replace-block: duplicate id p-day\. Edits after it do not save\./);

const believed = applyOps(trip, [{ op: "patch-block", id: "p-after", patch: { content: [{ type: "text", value: "Home by nine." }] } }]);
assert.deepEqual(foldDrift(trip, believed), { at: 2, id: "p-after" }, "a fold that dropped the op drifts at the block it dropped");
assert.equal(foldDrift(believed, structuredClone(believed)), null);
assert.equal(foldDrift(trip, trip.slice(0, 2)).at, 2, "a block the server kept and the editor dropped is drift");
assert.equal(light(lights({ ...calm, saved: trip, believed }), "fold-drift").ok, false);
assert.equal(light(lights({ ...calm, saved: trip, believed, settled: false }), "fold-drift").ok, null, "no verdict while a batch is in flight");

assert.deepEqual(lostKeys(["Trip", "Left at six.Fog by eight.Ice"], ["Trip", "Left at six.Ice"]), { count: 13, chars: "Fog by eight." });
assert.deepEqual(lostKeys(["Alpha", "", "Beta"], ["Alpha", "Beta"]), { count: 0, chars: "" }, "an empty line is not a key");
assert.deepEqual(lostKeys(["abxc"], ["abyc"]), { count: 1, chars: "x" });
const lost = lights({ ...calm, reload: { before: ["Alphax"], after: ["Alpha"] } });
assert.equal(light(lost, "lost-keys").ok, false);
assert.match(light(lost, "lost-keys").words, /1 character you typed did not come back after the reload: "x"/);
assert.equal(light(lights(calm), "lost-keys").ok, null, "no verdict before a reload");

function stubCanvas() {
  const canvas = new EventTarget();
  canvas.calls = [];
  for (const name of ["identifyOpsRequest", "applyServerBlocks", "acknowledgeOps", "discardInflightOps"])
    canvas[name] = (...args) => canvas.calls.push([name, ...args]);
  return canvas;
}
const send = (canvas, ops, seq) => canvas.dispatchEvent(Object.assign(new Event("bp-canvas-ops"), { detail: { ops, seq } }));
const settled = () => new Promise((r) => setTimeout(r, 0));

const a = stubCanvas();
const b = stubCanvas();
const host = createFakeHost({ fold: referenceFold, blocks: trip, onChange: () => {} });
host.attach(a);
host.attach(b);
assert.equal(a.acknowledgedSaves, true);
assert.deepEqual(a.blocks, trip);
const edit = [{ op: "patch-block", id: "p-after", patch: { content: [{ type: "text", value: "Home by nine." }] } }];
send(a, edit, 1);
await settled();
assert.deepEqual(host.saved, believed, "the host keeps the folded doc");
assert.deepEqual(a.calls.map(([name]) => name), ["identifyOpsRequest", "applyServerBlocks", "acknowledgeOps"]);
assert.deepEqual(a.calls[1][2], { mode: "own", requestId: "tg-1" }, "the sender gets its own echo, correlated");
assert.deepEqual(a.calls[2].slice(1), [1, true]);
assert.deepEqual(b.calls.map(([name, blocks, meta]) => [name, blocks, meta]), [["applyServerBlocks", believed, undefined]], "the other window gets the saved doc as a remote write");

send(a, nestedEnter.ops, 2);
await settled();
assert.deepEqual(host.saved, believed, "a refused batch changes nothing");
assert.deepEqual(a.calls.slice(3).map(([name, seq]) => [name, seq]), [["identifyOpsRequest", 2], ["discardInflightOps", 2]]);
assert.deepEqual(host.refusals, ["replace-block: duplicate id p-day"]);
assert.deepEqual(host.batches.map((x) => x.answer.ok), [true, false]);
assert.equal(host.inflight, 0);

for (const origin of ["https://guerrilla.barkpark.cloud", "http://localhost.example.com:4000", "http://127.0.0.1.example.com", "http://10.0.0.5:4000"])
  assert.throws(() => barkparkFold(origin, "t"), /is not this machine/, `${origin} is refused before any request`);
for (const origin of ["http://localhost:4817", "http://127.0.0.1:4817", "http://127.0.0.2:4000", "http://[::1]:4000"])
  assert.match(barkparkFold(origin, "t").name, /^Local Barkpark at /);

console.log("PASS  testing-ground traps: each light goes red on the bug it names");
