// __source_locked.test.mjs — pdd-t11 debt fix (1): the source-mode locked-prefix
// CLAMP. Markdown SOURCE mode (Mod-Shift-m) lets the user edit the raw markdown of
// a run freely — including the locked title that opens a doctrine template. The
// SERVER already vetoes any op that removes/moves/displaces a locked block
// ({:locked_block, id, op} in patch.ex), but WITHOUT the clamp the client rich
// editor would show the user's edited/deleted/moved title until reload (the "view
// diverges" debt wave 1 pre-loaded into t11). `clampLockedPrefix` is the felt half
// of D4 for source mode — the pure twin of locks.js `transactionVetoesLock`.
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

// The head block of `blocks` IS the locked title, verbatim (id + role + locked +
// text), and it carries a `locked === true` flag the live veto can re-read.
function assertTitleRestored(blocks) {
  const head = blocks[0];
  assert.equal(head.id, "tpl-title", "locked title id at the head");
  assert.equal(head.locked, true, "locked flag restored (md round-trip drops it)");
  assert.equal(head.role, "title", "role restored");
  assert.equal(head.text, "Doctrine", "title text is the baseline's, not the edit");
}

// ── the four divergences the server vetoes, clamped client-side ──────────────

check("EDIT the locked title in source → restored verbatim, body edit kept", () => {
  const out = sourceEdit((md) => md.replace("# Doctrine", "# Hacked"));
  assertTitleRestored(out);
});

check("EDIT a body block in source → body edit survives, title untouched", () => {
  const out = sourceEdit((md) => md.replace("Body.", "Body edited."));
  assertTitleRestored(out);
  const bodyOut = out.find((b) => b.id === "tpl-body");
  assert.ok(bodyOut, "body block survives by id");
  assert.equal(bodyOut.content[0].value, "Body edited.", "the body edit is kept");
});

check("DELETE the locked title in source → restored at the head", () => {
  const out = sourceEdit((md) => md.replace("# Doctrine\n\n", ""));
  assertTitleRestored(out);
});

check("MOVE the locked title below the body → restored to the head", () => {
  const out = sourceEdit(() => "Body.\n\n# Doctrine");
  assertTitleRestored(out);
});

check("INSERT a block before the title → the locked prefix holds position 0", () => {
  const out = sourceEdit((md) => "New para\n\n" + md);
  assertTitleRestored(out);
  // the inserted paragraph lands AFTER the locked title
  assert.equal(out[1].content[0].value, "New para");
});

// ── no locked-block op ever leaves the client (matches the server veto) ──────

check("runToOps after clamp emits NO op touching the locked title id", () => {
  const clamped = sourceEdit((md) => md.replace("# Doctrine", "# Hacked"));
  const ops = runToOps(L0, runToTiptap(clamped));
  const touchesTitle = ops.some((op) => op.id === "tpl-title");
  assert.equal(touchesTitle, false, "the locked title id never appears in an op");
  // and no remove/move op at all (nothing was displaced)
  const displacing = ops.filter((op) =>
    ["remove-block", "move-block"].includes(op.op),
  );
  assert.deepEqual(displacing, [], "no remove/move op emitted for the locked run");
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
