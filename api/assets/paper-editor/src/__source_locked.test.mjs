// __source_locked.test.mjs — pdd-t11 debt fix (1): the source-mode locked-prefix
// CLAMP. Markdown SOURCE mode (Mod-Shift-m) lets the user edit the raw markdown of
// a run freely — including the locked title that opens a doctrine template. The
// SERVER already vetoes any op that removes/moves/displaces a locked block
// ({:locked_block, id, op} in patch.ex), but WITHOUT the clamp the client rich
// editor would show the user's deleted/moved title until reload (the "view
// diverges" debt wave 1 pre-loaded into t11). `clampLockedPrefix` is the felt half
// of D4 for source mode — the pure twin of locks.js `transactionVetoesLock`.
//
// Locks are PLACEMENT locks (doctrine rule 2): the server ACCEPTS a patch-block on
// a locked block (it strips only `locked`/`role`), and the rich editor passes a
// pure content edit too. So the clamp pins placement + template identity while a
// same-type CONTENT edit (a retitle) rides through — one consistent surface.
//
// These are all pure-Node (no DOM / TipTap): the clamp operates on block arrays,
// and the round-trip drives the real markdown + realign + runToOps converters.
//
// Run: node src/__source_locked.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { blocksToMarkdown, markdownToBlocks } from "./markdown.js";
import {
  realignBlockIds,
  clampLockedPrefix,
} from "./canvas/source-realign.js";
import { runToTiptap, runToOps } from "./canvas/run-convert.js";

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.stack || e.message}`);
  }
}

// The forced template prefix (locked title @0) + a free body block. Matches the
// canvas RUN a paper opens with: the locked title leads the run, body follows.
const lockedTitle = {
  id: "tpl-title",
  type: "heading",
  level: 1,
  role: "title",
  locked: true,
  text: "Doctrine",
};
const body = {
  id: "tpl-body",
  type: "paragraph",
  content: [{ type: "text", value: "Body." }],
};
const L0 = [lockedTitle, body];

// The FULL source-mode edited-exit pipeline, minus the DOM: serialize the baseline
// to markdown, apply the user's textarea edit as a string transform, parse it back,
// realign ids against the baseline, then clamp the locked prefix — exactly what
// `_exitSourceMode` runs before setContent + dispatch.
function sourceEdit(mutateMd) {
  const md = mutateMd(blocksToMarkdown(L0));
  return clampLockedPrefix(L0, realignBlockIds(L0, markdownToBlocks(md)));
}

// The head block of `blocks` IS the locked title: id + role + locked at position 0
// (the template identity the md round-trip drops), with `text` — the baseline's
// unless the check expects a ridden-through content edit.
function assertTitlePinned(blocks, expectedText = "Doctrine") {
  const head = blocks[0];
  assert.equal(head.id, "tpl-title", "locked title id at the head");
  assert.equal(head.locked, true, "locked flag restored (md round-trip drops it)");
  assert.equal(head.role, "title", "role restored");
  assert.equal(head.type, "heading", "template type pinned");
  assert.equal(head.text, expectedText, "title text");
}

// ── placement divergences the server vetoes, clamped client-side ─────────────

check("EDIT the locked title in source → the retitle RIDES THROUGH, placement pinned", () => {
  // Locks are placement locks: the server accepts patch-block {text} on a locked
  // block (strip_template_keys drops only locked/role) and the rich editor allows
  // the same retitle — source mode must not silently revert it.
  const out = sourceEdit((md) => md.replace("# Doctrine", "# Renamed"));
  assertTitlePinned(out, "Renamed");
});

check("EDIT a body block in source → body edit survives, title untouched", () => {
  const out = sourceEdit((md) => md.replace("Body.", "Body edited."));
  assertTitlePinned(out);
  const bodyOut = out.find((b) => b.id === "tpl-body");
  assert.ok(bodyOut, "body block survives by id");
  assert.equal(bodyOut.content[0].value, "Body edited.", "the body edit is kept");
});

check("DELETE the locked title in source → restored verbatim at the head", () => {
  const out = sourceEdit((md) => md.replace("# Doctrine\n\n", ""));
  assertTitlePinned(out);
});

check("MOVE the locked title below the body → pinned back to the head", () => {
  const out = sourceEdit(() => "Body.\n\n# Doctrine");
  assertTitlePinned(out);
});

check("INSERT a block before the title → the locked prefix holds position 0", () => {
  const out = sourceEdit((md) => "New para\n\n" + md);
  assertTitlePinned(out);
  // the inserted paragraph lands AFTER the locked title
  assert.equal(out[1].content[0].value, "New para");
});

check("DELETE the title + type a NEW paragraph at the top → BOTH survive", () => {
  // The new paragraph positionally inherits the locked id in realignBlockIds
  // (type mismatch) — it is user content, never the locked block: it must be
  // re-minted and kept, and the locked title restored verbatim. Silent data
  // loss here is worse than any veto.
  const out = sourceEdit(() => "My new intro.\n\nBody.");
  assertTitlePinned(out);
  const intro = out.find(
    (b) => b.type === "paragraph" && b.content?.[0]?.value === "My new intro.",
  );
  assert.ok(intro, "the user's new paragraph survives");
  assert.notEqual(intro.id, "tpl-title", "under its own id, not the locked one");
  assert.equal(out[1], intro, "…directly after the restored locked prefix");
});

check("RETYPE the title to a paragraph → title restored, user text kept as content", () => {
  const out = sourceEdit((md) => md.replace("# Doctrine", "Doctrine, but prose"));
  assertTitlePinned(out);
  const kept = out.find((b) => b.content?.[0]?.value === "Doctrine, but prose");
  assert.ok(kept, "the retyped text survives as an ordinary block");
  assert.notEqual(kept.id, "tpl-title", "under a fresh id");
});

// ── the emitted ops match what the server accepts (no veto round-trip) ───────

check("runToOps after a retitle emits EXACTLY one patch-block, no remove/move", () => {
  const clamped = sourceEdit((md) => md.replace("# Doctrine", "# Renamed"));
  const ops = runToOps(L0, runToTiptap(clamped));
  const titleOps = ops.filter((op) => op.id === "tpl-title");
  assert.equal(titleOps.length, 1, "one op for the locked title");
  assert.equal(titleOps[0].op, "patch-block", "…and it is a patch (server-accepted)");
  assert.equal(titleOps[0].patch.text, "Renamed", "…carrying the retitle");
  const displacing = ops.filter((op) =>
    ["remove-block", "move-block"].includes(op.op),
  );
  assert.deepEqual(displacing, [], "no remove/move op emitted for the locked run");
});

check("runToOps after a pure displacement emits NO op touching the locked id", () => {
  const clamped = sourceEdit(() => "Body.\n\n# Doctrine"); // move only, text same
  const ops = runToOps(L0, runToTiptap(clamped));
  assert.deepEqual(ops, [], "a clamped-away displacement is a zero-op exit");
});

// ── D3: additive — a template-free run is byte-identical ─────────────────────

check("no locked prefix → realigned blocks returned untouched (D3 additive)", () => {
  const nolock = [{ id: "p", type: "paragraph", content: [] }];
  const realigned = [{ id: "p2", type: "paragraph", content: [] }];
  assert.equal(
    clampLockedPrefix(nolock, realigned),
    realigned,
    "same reference back — no clamp on a template-free run",
  );
});

check("non-array inputs degrade to a safe empty/passthrough", () => {
  assert.deepEqual(clampLockedPrefix(null, null), []);
  assert.deepEqual(clampLockedPrefix(undefined, [{ id: "x" }]), [{ id: "x" }]);
});

if (failures > 0) {
  console.log(`\n${failures} FAILING`);
  process.exit(1);
}
console.log("\nAll source-locked clamp checks passed.");
