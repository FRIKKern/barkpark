// smoke/source-mode.mjs — the P5 markdown source-mode realignment gates: no-edit-zero-
// ops, edited-one-patch, insert/remove, id-uniqueness, docToBlocks L0 derivation, the
// lag model, the duplicate-signature tie-break, and the View "Toggle Markdown source"
// palette command.
//
// VERBATIM extraction from src/__smoke.mjs §P5-SOURCE-MODE: each check moved unchanged
// (same name, body, assertions), carrying its section-local helper (exitSourceOps) and
// fixture (SRC_BASELINE) with it. The shared check() runs through the harness so the
// aggregate report + exit code span all modules.
import assert from "node:assert/strict";
import { check } from "./harness.mjs";
import { runToTiptap, runToOps, docToBlocks } from "../canvas/run-convert.js";
import { blocksToMarkdown, markdownToBlocks } from "../markdown.js";
import { realignBlockIds } from "../canvas/source-realign.js";
import { buildCommandRegistry } from "../canvas/command-palette.js";

// ═══════════════════════════════════════════════════════════════════════════
// §P5 MARKDOWN SOURCE-MODE — no-edit-zero-ops + edited-one-patch, AGAINST L0.
//
// THREE doc states to keep distinct (the source-mode correctness rests on this):
//   • C  = this._blocks — the ECHO-CONFIRMED baseline. Advances ASYNC, only when the
//          server echoes bp:canvas-update. After the user types, C LAGS the live doc.
//   • L0 = the LIVE doc at source-mode ENTER, projected back to blocks via
//          docToBlocks(normalizeCanvasDoc(getJSON())). Includes the user's just-typed,
//          not-yet-confirmed edits. THIS is the source baseline + textarea content.
//   • L1 = the blocks after the user edits the markdown: markdownToBlocks(textarea),
//          then realignBlockIds against L0 to keep surviving blocks' ids.
//
// The toggle's EDITED exit emits ONLY runToOps(L0, L1) (the genuine source diff) and
// applies L1 to the editor WITHOUT auto-emit — so the in-flight pre-source edits
// (L0−C) are NOT re-emitted as duplicate structural ops. These tests pin that PURE
// pipeline (docToBlocks → markdownToBlocks → realignBlockIds → runToTiptap → runToOps):
//   • NO EDIT  → ZERO ops (round-trip op-free for an unchanged run).
//   • ONE EDIT (a heading) → EXACTLY ONE patch-block for THAT L0 id (no remove+insert).
//   • INSERT / REMOVE → one structural op, survivors untouched.
//   • LAG MODEL — L0 carries a block NOT in C (a just-typed paragraph): the source
//     diff against L0 emits only the user's source edit, never re-inserting the L0−C
//     block (that is what the explicit runToOps(L0,L1) emit, not _emitOps-from-C, buys).
//   • DUPLICATE-SIGNATURE run → a single edit does NOT churn the identical siblings.
// The WC itself (textarea swap, focus, Mod-Shift-m / palette triggers, the external-
// edit queue) needs a DOM and is covered by the Elixir LiveView paper_canvas tests;
// here we pin the pure converter+diff+projection contract that makes the WC correct.
// ═══════════════════════════════════════════════════════════════════════════

// The exit-source projection the WC runs: parse the (possibly edited) markdown, realign
// ids against the LIVE baseline (L0), then diff L0 against the projected new doc (L1).
// `baselineBlocks` here is L0 — the live-doc-derived source baseline, NOT C.
function exitSourceOps(baselineBlocks, editedMd) {
  const parsed = markdownToBlocks(editedMd);
  const realigned = realignBlockIds(baselineBlocks, parsed);
  const nextDoc = runToTiptap(realigned);
  return { ops: runToOps(baselineBlocks, nextDoc), realigned };
}

// A representative mixed run (the kinds a source edit actually touches: heading /
// paragraph / list, plus a natural code block). All ids are server-style so the
// realigner has real baseline ids to donate back.
const SRC_BASELINE = [
  { id: "s-h1", type: "heading", level: 1, text: "Status" },
  { id: "s-p1", type: "paragraph", content: [{ type: "text", value: "intro line" }] },
  {
    id: "s-l1",
    type: "list",
    ordered: false,
    items: [[{ type: "text", value: "alpha" }], [{ type: "text", value: "beta" }]],
  },
  { id: "s-h2", type: "heading", level: 2, text: "Details" },
  { id: "s-p2", type: "paragraph", content: [{ type: "text", value: "tail line" }] },
];

check("P5 source: NO-EDIT toggle is op-free (md unchanged → ZERO bp-canvas-ops)", () => {
  const md0 = blocksToMarkdown(SRC_BASELINE);
  // The WC compares textarea.value === the stashed original md and restores untouched
  // on equality; assert the underlying re-parse+realign+diff ALSO yields zero ops, so
  // the toggle can never smuggle in a normalization op even on the edited code path.
  const { ops } = exitSourceOps(SRC_BASELINE, md0);
  assert.equal(ops.length, 0, `no-edit round-trip must emit ZERO ops, got ${JSON.stringify(ops)}`);
});

check("P5 source: edited heading text → EXACTLY ONE patch-block for that block", () => {
  const md0 = blocksToMarkdown(SRC_BASELINE);
  // Edit ONLY the H2 "Details" → "Details v2" in the markdown text.
  assert.ok(md0.includes("## Details"), "baseline md contains the H2 line");
  const editedMd = md0.replace("## Details", "## Details v2");
  assert.notEqual(editedMd, md0, "the md actually changed");

  const { ops, realigned } = exitSourceOps(SRC_BASELINE, editedMd);
  // The realigner must have kept the H2's baseline id so the diff patches it in place.
  const h2 = realigned.find((b) => b.type === "heading" && b.text === "Details v2");
  assert.ok(h2, "the edited H2 is present in the realigned blocks");
  assert.equal(h2.id, "s-h2", "edited H2 inherited the baseline id (in-place edit)");

  assert.equal(ops.length, 1, `exactly one op, got ${JSON.stringify(ops)}`);
  assert.equal(ops[0].op, "patch-block", "the one op is a patch-block");
  assert.equal(ops[0].id, "s-h2", "the patch targets the edited heading's id");
});

check("P5 source: an INSERTED block → one insert/append; surviving blocks untouched", () => {
  const md0 = blocksToMarkdown(SRC_BASELINE);
  // Append a brand-new paragraph at the end of the markdown.
  const editedMd = md0 + "\n\nbrand new tail";
  const { ops } = exitSourceOps(SRC_BASELINE, editedMd);
  // The lone structural change is the inserted block (append-block or insert-after);
  // every surviving block kept its id so NONE of them patch.
  const structural = ops.filter((o) => o.op === "append-block" || o.op === "insert-after");
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.equal(structural.length, 1, `one insert op, got ${JSON.stringify(ops)}`);
  assert.equal(patches.length, 0, `no spurious patches, got ${JSON.stringify(patches)}`);
});

check("P5 source: a REMOVED block → one remove-block; survivors keep their ids", () => {
  const md0 = blocksToMarkdown(SRC_BASELINE);
  // Drop the H2 "Details" line entirely (delete that block from the source).
  const editedMd = md0.replace("## Details\n\n", "");
  assert.notEqual(editedMd, md0, "the md actually changed");
  const { ops } = exitSourceOps(SRC_BASELINE, editedMd);
  const removes = ops.filter((o) => o.op === "remove-block");
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.equal(removes.length, 1, `one remove op, got ${JSON.stringify(ops)}`);
  assert.equal(removes[0].id, "s-h2", "the removed id is the deleted heading");
  assert.equal(patches.length, 0, `survivors keep ids → no patches, got ${JSON.stringify(patches)}`);
});

check("P5 source: realignBlockIds never assigns a baseline id twice", () => {
  // Even a heavily-edited markdown (multiple in-place edits) must keep ids unique so
  // runToOps's per-id keying holds (a duplicate id would make it self-move/conflict).
  const md0 = blocksToMarkdown(SRC_BASELINE);
  const editedMd = md0
    .replace("# Status", "# Status X")
    .replace("## Details", "## Details Y");
  const { realigned } = exitSourceOps(SRC_BASELINE, editedMd);
  const ids = realigned.map((b) => b.id);
  assert.equal(new Set(ids).size, ids.length, "all realigned ids are unique");
});

check("P5 source: empty run round-trips to an empty doc with ZERO ops", () => {
  const baseline = [];
  const md0 = blocksToMarkdown(baseline);
  const { ops } = exitSourceOps(baseline, md0);
  assert.equal(ops.length, 0, "empty → empty emits no ops");
});

// ── L0 derivation: docToBlocks(live doc) is the source baseline (NOT C) ──────
//
// _enterSourceMode now captures L0 = docToBlocks(normalizeCanvasDoc(getJSON())),
// the SAME node→block projection runToOps diffs against. These assert docToBlocks
// reproduces the run faithfully (so the markdown the user sees == the live doc) and
// MINTS an id for a just-typed (bpId:null) node (so blocksToMarkdown has a stable key
// and the exit realign can donate it back).
check("P5 source: docToBlocks projects a live doc back to its run (ids preserved)", () => {
  const doc = runToTiptap(SRC_BASELINE);
  const blocks = docToBlocks(doc);
  // Round-trip is the identity on a doc that came straight from runToTiptap: same ids,
  // same kinds, same content — so a NO-EDIT enter shows exactly the confirmed run.
  assert.deepEqual(blocks.map((b) => b.id), SRC_BASELINE.map((b) => b.id), "ids preserved");
  // And diffing the baseline against this projection emits ZERO ops (the projection is
  // the diff fixed-point — entering source mode on an unedited run perturbs nothing).
  assert.equal(runToOps(SRC_BASELINE, runToTiptap(blocks)).length, 0, "L0 projection is op-free vs itself");
});

check("P5 source: docToBlocks MINTS an id for a just-typed (bpId:null) live node", () => {
  // A live doc where the 2nd top-level node was just typed (Enter-split / new para)
  // and carries bpId:null — exactly the not-yet-confirmed state on source-mode enter.
  const liveDoc = {
    type: "doc",
    content: [
      { type: "heading", attrs: { bpId: "s-h1", bpType: "heading", level: 1 }, content: [{ type: "text", text: "Status" }] },
      { type: "paragraph", attrs: { bpId: null, bpType: "paragraph" }, content: [{ type: "text", text: "fresh line" }] },
    ],
  };
  const blocks = docToBlocks(liveDoc);
  assert.equal(blocks.length, 2, "both nodes project");
  assert.equal(blocks[0].id, "s-h1", "the confirmed node keeps its id");
  assert.ok(blocks[1].id && blocks[1].id !== "s-h1" && blocks[1].id != null, "the just-typed node was minted a fresh id");
  assert.equal(blocks[1].content[0].value, "fresh line", "the just-typed text rides into the baseline (it is on screen)");
});

// ── LAG MODEL: L0 carries a block NOT in C; the source diff must not duplicate it ──
//
// The data-loss blocker scenario, modeled in pure Node. The user typed a new paragraph
// ("fresh") that the server has NOT echoed yet, so C (this._blocks) lacks it but the
// LIVE doc (L0) has it. Source mode captures L0, the user edits a DIFFERENT block in
// the textarea, and exits. The emit is runToOps(L0, L1) — so it carries ONLY the source
// edit. It must NOT re-insert "fresh" (that pre-source insert is already in flight as
// L0−C; re-emitting it would double-insert). This is precisely why the toggle diffs
// L0→L1 explicitly instead of running _emitOps (which diffs from C and WOULD re-insert).
check("P5 source: lag — an L0 block absent from C is NOT re-emitted by the source diff", () => {
  // C = the echo-confirmed run (no "fresh" yet).
  const C = [
    { id: "c-h1", type: "heading", level: 1, text: "Status" },
    { id: "c-p1", type: "paragraph", content: [{ type: "text", value: "intro" }] },
  ];
  // L0 = the LIVE doc: C plus a just-typed, not-yet-confirmed paragraph "fresh" whose
  // node still had bpId:null, so docToBlocks minted it an id (here a stable test id).
  const L0 = [
    { id: "c-h1", type: "heading", level: 1, text: "Status" },
    { id: "c-p1", type: "paragraph", content: [{ type: "text", value: "intro" }] },
    { id: "c-fresh", type: "paragraph", content: [{ type: "text", value: "fresh" }] },
  ];
  // Sanity: the L0−C delta is the in-flight insert of "fresh" (plus whatever reorder
  // anchoring needs) — and crucially it carries NO patch/remove of the existing blocks.
  // This is the batch ALREADY in flight; the source exit must NOT re-send any of it.
  const preSourceOps = runToOps(C, runToTiptap(L0));
  const inserts = preSourceOps.filter((o) => o.op === "insert-after" || o.op === "append-block");
  assert.equal(inserts.length, 1, `L0−C inserts the one fresh block, got ${JSON.stringify(preSourceOps)}`);
  assert.equal(preSourceOps.filter((o) => o.op === "patch-block" || o.op === "remove-block").length, 0, "L0−C neither patches nor removes an existing block");

  // In source mode the user edits the HEADING only; "fresh" is untouched in the md.
  const md0 = blocksToMarkdown(L0);
  assert.ok(md0.includes("# Status"), "L0 md has the heading");
  assert.ok(md0.includes("fresh"), "L0 md has the just-typed paragraph (it is on screen)");
  const editedMd = md0.replace("# Status", "# Status v2");

  // The exit emit is runToOps(L0, L1) — exactly ONE patch for the heading, and NOTHING
  // about "fresh" (no second insert, no remove, no patch). The in-flight L0−C insert is
  // left to the normal echo, never re-sent here.
  const { ops, realigned } = exitSourceOps(L0, editedMd);
  assert.equal(ops.length, 1, `exactly one source op, got ${JSON.stringify(ops)}`);
  assert.equal(ops[0].op, "patch-block", "the one op is a patch-block");
  assert.equal(ops[0].id, "c-h1", "…targeting the edited heading");
  // The fresh paragraph survived the realign with its L0 id, so the diff sees no change
  // for it → no duplicate insert.
  const fresh = realigned.find((b) => b.content && b.content[0] && b.content[0].value === "fresh");
  assert.ok(fresh && fresh.id === "c-fresh", "the fresh block kept its L0 id (no re-mint, no re-insert)");
});

// ── DUPLICATE-SIGNATURE run: a single edit must not churn identical siblings ──
//
// Two byte-identical paragraphs share a per-block markdown signature, so they are
// LCS-indistinguishable. realignBlockIds breaks the tie POSITIONALLY (nearest
// unconsumed baseline id within the equal-signature run), so editing ONE near them
// emits exactly ONE patch and the identical sibling keeps its id (no spurious move /
// patch / remove). Each baseline id is donated at most once.
check("P5 source: a duplicate-signature run does NOT churn on a single in-place edit", () => {
  const para = (id, t) => ({ id, type: "paragraph", content: [{ type: "text", value: t }] });
  const L0 = [
    para("d-h", "Top"),
    para("d-p1", "identical"),
    para("d-p2", "identical"), // byte-identical signature to d-p1
    para("d-tail", "tail"),
  ];
  const md0 = blocksToMarkdown(L0);
  // Edit the SECOND identical paragraph only.
  let seen = 0;
  const editedMd = md0.replace(/identical/g, (m) => (++seen === 2 ? "identical EDITED" : m));
  assert.notEqual(editedMd, md0, "md changed");

  const { ops, realigned } = exitSourceOps(L0, editedMd);
  // Exactly one patch; survivors keep ids; no moves/removes/inserts.
  assert.equal(ops.length, 1, `exactly one op, got ${JSON.stringify(ops)}`);
  assert.equal(ops[0].op, "patch-block", "the one op is a patch-block");
  assert.equal(ops[0].id, "d-p2", "the patch targets the edited sibling's id (positional tie-break)");
  // ids stay unique (no double-donation) and both originals are present.
  const ids = realigned.map((b) => b.id);
  assert.equal(new Set(ids).size, ids.length, "all realigned ids unique");
  assert.ok(ids.includes("d-p1") && ids.includes("d-p2"), "both duplicate ids survived, donated once each");

  // And editing the FIRST instead is symmetric: one patch on d-p1, no churn.
  let seen2 = 0;
  const editedFirst = md0.replace(/identical/g, (m) => (++seen2 === 1 ? "identical FIRST" : m));
  const r2 = exitSourceOps(L0, editedFirst);
  assert.equal(r2.ops.length, 1, `editing the first → one op, got ${JSON.stringify(r2.ops)}`);
  assert.equal(r2.ops[0].id, "d-p1", "the patch targets the first sibling's id");
});

// ── DOM-bound contract (documented, asserted at the converter level) ─────────
//
// The WC marks source mode as "busy": while this._mode === 'source', _isEditingNow()
// returns true, so applyServerBlocks QUEUES an external echo (_pendingServerBlocks)
// onto the HIDDEN editor instead of applying it — the source-exit setContent would
// otherwise clobber it. The queue is flushed on return to rich (_flushPendingServerBlocks,
// the same flush blur/compositionend run). This behavior is DOM-bound (it needs a live
// editor + textarea) and is exercised by the Elixir LiveView paper_canvas tests; here we
// only DOCUMENT it and pin the underlying invariant it relies on: an external echo and a
// source edit are diffed against the SAME L0 baseline, so neither loses the other's work.
check("P5 source: (documented) external echo + source edit are both expressed against L0", () => {
  // L0 with two blocks; the user edits the first in source mode (→ L1), while an external
  // echo confirms a change to the SECOND. Both diffs key off L0 ids, so applying the
  // queued external echo after exit and the source patch never target the same datum.
  const para = (id, t) => ({ id, type: "paragraph", content: [{ type: "text", value: t }] });
  const L0 = [para("q-1", "mine"), para("q-2", "theirs")];
  const md0 = blocksToMarkdown(L0);
  const { ops } = exitSourceOps(L0, md0.replace("mine", "mine v2"));
  assert.equal(ops.length, 1, "source edit is one patch on q-1");
  assert.equal(ops[0].id, "q-1", "…targeting the user's block, not the externally-changed one");
  // The external echo (a confirmed change to q-2) is a SEPARATE applyServerBlocks the WC
  // queues during source mode and flushes on exit — orthogonal to this q-1 patch.
});

check("P5 palette: View 'Toggle Markdown source' command appears only with onToggleSource", () => {
  // Without the callback (pure build): no View group.
  const plain = buildCommandRegistry();
  assert.ok(!plain.some((c) => c.id === "view-toggle-source"), "no View command without callback");
  // With the callback: the command is present, in a "View" group, and run() invokes it.
  let called = 0;
  const reg = buildCommandRegistry(undefined, { onToggleSource: () => { called++; } });
  const view = reg.find((c) => c.id === "view-toggle-source");
  assert.ok(view, "View command present when onToggleSource wired");
  assert.equal(view.group, "View", "command is in the View group");
  assert.equal(view.label, "Toggle Markdown source", "command label matches the spec");
  view.run({});
  assert.equal(called, 1, "run() calls the toggle callback");
});
