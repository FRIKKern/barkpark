// smoke/echo.mjs — S4a server-echo reconcile + baseline-reset gates: own-echo match,
// cumulative→incremental baseline reset, external-edit detection, and the id-tolerant
// new-block echo reconcile (id-stamp writebacks).
//
// VERBATIM extraction from src/__smoke.mjs §S4a: each check moved unchanged (same name,
// body, assertions). The shared check()/applyOps run through the harness so the
// aggregate report + exit code span all modules.
import assert from "node:assert/strict";
import { check, applyOps } from "./harness.mjs";
import { runToTiptap, runToOps, reconcileServerEcho } from "../canvas/run-convert.js";

// S4a-a) THE MATCH CHECK: an echo of the SAME blocks is a no-op.
//   runToOps(serverBlocks, runToTiptap(serverBlocks)) === []  — so applyServerBlocks
//   detects an own-echo (the live doc already equals the confirmed blocks) and
//   takes the pure-baseline-reset path (zero editor mutation, zero caret move).
check("S4a runToOps: an echo of the same blocks is a NO-OP (own-echo match gate)", () => {
  const serverBlocks = [
    { id: "h-1", type: "heading", level: 1, text: "Title" },
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "alpha" }] },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "beta" }] },
  ];
  // The live doc IS the projection of the confirmed blocks (the own-echo case:
  // the server confirmed exactly what the canvas already holds).
  const liveDoc = runToTiptap(serverBlocks);
  const ops = runToOps(serverBlocks, liveDoc);
  assert.equal(ops.length, 0, "echo of the same blocks emits ZERO ops → own-echo no-op");
});

// S4a-b) BASELINE RESET SHRINKS THE DIFF: prove cumulative → incremental.
//   Without the echo (S1), every batch diffs from the MOUNTED run, so the 2nd
//   edit's batch re-includes the 1st edit (CUMULATIVE). With the echo (S4a), the
//   baseline advances to the server-confirmed blocks after edit 1, so the 2nd
//   batch carries ONLY edit 2 (INCREMENTAL).
check("S4a baseline reset: the 2nd batch is INCREMENTAL, not cumulative (echo shrinks the diff)", () => {
  const mounted = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "one" }] },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "two" }] },
  ];

  // EDIT 1 — change p-1's text. The doc after edit 1:
  const doc1 = runToTiptap(mounted);
  doc1.content[0] = {
    ...doc1.content[0],
    content: [{ type: "text", text: "ONE" }],
  };
  const batch1 = runToOps(mounted, doc1);
  assert.equal(batch1.length, 1, "edit 1 → one patch-block (p-1)");
  assert.equal(batch1[0].id, "p-1");

  // The server confirms edit 1 → it echoes back the new blocks. The canvas resets
  // its baseline to these (applyServerBlocks own-echo path). Build the confirmed
  // blocks by folding batch1 over the mounted run (what the server persisted).
  const confirmed1 = applyOps(mounted, batch1);
  assert.deepEqual(
    confirmed1[0].content,
    [{ type: "text", value: "ONE" }],
    "server-confirmed blocks carry edit 1",
  );

  // EDIT 2 — now change p-2's text. The doc after edit 2 (built on the confirmed
  // doc, both edits present in the LIVE doc as they always are):
  const doc2 = runToTiptap(confirmed1);
  doc2.content[1] = {
    ...doc2.content[1],
    content: [{ type: "text", text: "TWO" }],
  };

  // S1 (NO echo) — diffing from the ORIGINAL mounted run re-emits BOTH edits.
  const cumulative = runToOps(mounted, doc2);
  assert.equal(cumulative.length, 2, "WITHOUT echo: cumulative batch carries BOTH edits");
  assert.deepEqual(
    cumulative.map((o) => o.id).sort(),
    ["p-1", "p-2"],
    "cumulative batch touches p-1 (edit 1) AND p-2 (edit 2)",
  );

  // S4a (echo) — diffing from the RESET baseline (confirmed1) carries ONLY edit 2.
  const incremental = runToOps(confirmed1, doc2);
  assert.equal(incremental.length, 1, "WITH echo: incremental batch carries ONLY edit 2");
  assert.equal(incremental[0].id, "p-2", "incremental batch touches only p-2 (edit 2)");

  // The baseline reset strictly SHRANK the diff.
  assert.ok(
    incremental.length < cumulative.length,
    "echo-advanced baseline shrinks the op count (incremental < cumulative)",
  );
});

// S4a-c) EXTERNAL EDIT IS DETECTED: a confirmed-blocks echo that DIFFERS from the
//   live doc yields a NON-EMPTY runToOps → applyServerBlocks takes the
//   external-edit path (setContent the confirmed content, addToHistory:false).
check("S4a runToOps: a confirmed echo that DIFFERS from the live doc is detected (external edit)", () => {
  const liveBlocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "local" }] },
  ];
  const liveDoc = runToTiptap(liveBlocks);

  // The server confirms DIFFERENT content for p-1 (an external edit from another
  // tab / agent / ingest). applyServerBlocks diffs the confirmed blocks against
  // the live doc — a non-empty result means "not my echo, re-render".
  const externalBlocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "external" }] },
  ];
  const ops = runToOps(externalBlocks, liveDoc);
  assert.ok(ops.length > 0, "an external edit (confirmed != live) is NOT an own-echo");
});

// S4a-d) THE NEW-BLOCK ECHO (the bug this fix closes). The naive own-echo gate —
//   runToOps(serverBlocks, liveDoc) === [] — MISDETECTS a NEW-block echo as
//   EXTERNAL. When the user Enter-splits, the live new-block node carries
//   bpId:null; the server mints an id ("srv-9") and echoes it. runToOps mints a
//   FRESH id for the null node and reports remove("srv-9") + insert-after(fresh) —
//   a NON-EMPTY diff → misdetected external → setContent yanks the caret AND, since
//   the live node never learns "srv-9", every later batch re-mints it (op size
//   never shrinks; the server id churns). reconcileServerEcho closes this: a live
//   bpId:null is a WILDCARD for the server id at that index → ownEcho true + the
//   id-writebacks. After the (simulated) writeback the next diff is [] (no churn),
//   and a SECOND edit emits a single INCREMENTAL op (not a re-mint of block 1).
check("S4a-d new-block echo: id-tolerant reconcile recognizes the OWN echo + makes the next diff incremental", () => {
  // The mounted baseline (the canvas's prev) — one paragraph.
  const mountedBaseline = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "alpha" }] },
  ];

  // The user Enter-splits: p-1 keeps "alpha"; a NEW 2nd paragraph "beta" carries
  // bpId:null (a freshly-typed block has no id yet) — the REAL new-block shape.
  const liveDoc = runToTiptap(mountedBaseline);
  liveDoc.content = [
    {
      type: "paragraph",
      attrs: { bpId: "p-1", bpType: "paragraph" },
      content: [{ type: "text", text: "alpha" }],
    },
    {
      type: "paragraph",
      attrs: { bpId: null, bpType: "paragraph" }, // NEW block — no id yet
      content: [{ type: "text", text: "beta" }],
    },
  ];

  // The emitted ops: a single insert-after with a CLIENT-minted id for the new
  // block (the batch the canvas sends to the server).
  const batch1 = runToOps(mountedBaseline, liveDoc);
  assert.equal(batch1.length, 1, "the split emits exactly one insert-after");
  assert.equal(batch1[0].op, "insert-after");
  assert.equal(batch1[0].afterId, "p-1");

  // The server applies it and mints "srv-9" for the new block, then echoes the
  // CONFIRMED blocks (the new block now carrying a concrete id).
  const serverBlocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "alpha" }] },
    { id: "srv-9", type: "paragraph", content: [{ type: "text", value: "beta" }] },
  ];

  // (a) THE NAIVE GATE WAS WRONG — runToOps against the live doc that STILL has
  //     bpId:null reports a NON-empty diff (the misdetection this fix kills).
  const naive = runToOps(serverBlocks, liveDoc);
  assert.ok(
    naive.length > 0,
    "REGRESSION GUARD: the OLD runToOps gate misdetects the new-block echo as external",
  );

  // (a') THE ID-TOLERANT RECONCILE IS RIGHT — it recognizes the OWN echo (NOT
  //      external) and returns the id-writeback for the just-minted null node.
  const { ownEcho, idWrites } = reconcileServerEcho(serverBlocks, liveDoc.content);
  assert.equal(ownEcho, true, "the new-block echo is recognized as an OWN echo");
  assert.deepEqual(
    idWrites,
    [{ index: 1, id: "srv-9", bpType: undefined }],
    "the writeback stamps srv-9 onto the live null-bpId node at index 1",
  );

  // (b) AFTER THE (simulated) ID WRITEBACK — runToOps(serverBlocks, stampedLive)
  //     is [] (NO churn: the live node now carries srv-9, so it diffs incremental).
  const stamped = {
    type: "doc",
    content: liveDoc.content.map((node, i) => {
      const w = idWrites.find((x) => x.index === i);
      if (!w) return node;
      const attrs = { ...node.attrs, bpId: w.id };
      if (w.bpType !== undefined) attrs.bpType = w.bpType;
      return { ...node, attrs };
    }),
  };
  const afterStamp = runToOps(serverBlocks, stamped);
  assert.equal(
    afterStamp.length,
    0,
    "after the id writeback the echo NO-OPS (no remove/insert churn)",
  );

  // (b') A SECOND edit (change the new block's text) emits ONE INCREMENTAL op —
  //      a patch-block keyed by srv-9, NOT a re-mint of the first new block.
  const doc2 = {
    type: "doc",
    content: stamped.content.map((node, i) =>
      i === 1 ? { ...node, content: [{ type: "text", text: "beta EDIT" }] } : node,
    ),
  };
  const batch2 = runToOps(serverBlocks, doc2);
  assert.equal(batch2.length, 1, "the 2nd edit emits exactly one incremental op");
  assert.equal(batch2[0].op, "patch-block", "incremental: a patch, not a re-insert");
  assert.equal(batch2[0].id, "srv-9", "the patch is keyed by the server id (no re-mint)");
  assert.equal(
    batch2.filter((o) => o.op === "insert-after" || o.op === "append-block").length,
    0,
    "no re-mint of the first new block on the 2nd edit",
  );
});
