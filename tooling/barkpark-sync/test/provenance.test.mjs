#!/usr/bin/env node
// Proof for the publish-boundary gate — tooling/barkpark-sync/provenance.mjs
//
//   node --test tooling/barkpark-sync/test/provenance.test.mjs
//
// The three things this file exists to prove, because they are the three ways
// the slice could ship as decoration:
//
//   1. A node with no provenance is REFUSED, by a named reason. Not warned
//      about, not annotated — refused, so the corpus cannot grow while the
//      label is missing.
//   2. A node an agent panel judged renders a marker a reader can SEE. A gate
//      that passes silently and prints the same body as before has changed
//      nothing that matters.
//   3. The word "importance" never appears over a deterministic prior. That was
//      the live mislabel: combined-report.json has no `importance` key, so
//      `c.importance ?? s.prior` resolved to the prior on every single file and
//      the paper still called it importance.
//
// HERMETIC — pure functions only, no server, no filesystem.

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  checkNode, gateNodes, checkRendered,
  measuredLine, judgedLine, renderFileBlocks, renderIntentionBlocks,
  MEASURED_MARK, JUDGED_MARK, PUBLISHABLE_TIERS, proseText,
} from "../provenance.mjs";
import { bareNode, priorNode, agentNode, intentionNode } from "./fixture.mjs";

// Includes code-block values, which checkRendered deliberately does NOT read —
// so a test asserting on the re-run recipe sees it, and the gate still cannot be
// tripped by the word "importance" appearing inside a file's own source.
const bodyText = (blocks) => blocks.map((b) => b.text ?? b.value ?? (b.content || []).map((c) => c.value).join("") ?? "").join("\n");

// ─────────────────────────────────────────────────────────────────────────────
// (a) missing provenance is a refusal with a name
// ─────────────────────────────────────────────────────────────────────────────

test("the shipped specimen — metrics and prose, no provenance — is refused", () => {
  const reasons = checkNode(bareNode());
  assert.deepEqual(reasons, ["missing-provenance"],
    "the exact node shape that published 1,666 papers must not pass the gate");
});

test("gateNodes names the offending file, not just a count", () => {
  const g = gateNodes([agentNode(), bareNode()]);
  assert.equal(g.ok, false);
  assert.equal(g.checked, 2);
  assert.equal(g.failures.length, 1, "the labelled node must NOT be swept up with the unlabelled one");
  assert.equal(g.failures[0].path, "api/lib/barkpark/accounts.ex");
  assert.ok(g.failures[0].reasons.includes("missing-provenance"));
});

test("a tier merge.mjs marks MISSING cannot carry a blended score", () => {
  const n = agentNode({ provenance: { tier: "MISSING", prior: 51, agentCrit: 73, votes: 1, agreement: "", contested: false, confidence: "", proseTier: "agent" } });
  assert.ok(checkNode(n).includes("blended-under-unadjudicated-tier:MISSING"));
});

test("claiming a blend with no agent criticality is refused", () => {
  const n = agentNode({ provenance: { tier: "agent", prior: 51, agentCrit: "", votes: 0, agreement: "", contested: false, confidence: "", proseTier: "agent" } });
  assert.ok(checkNode(n).includes("blended-without-agent-input"),
    "a 45/55 blend with nothing on the 55 side is the mislabel inverted");
});

test("agent prose with no prose tier is refused, and the reason names the fields", () => {
  const n = priorNode({ provenance: { tier: "auto", prior: 58, agentCrit: "", votes: 0, agreement: "", contested: false, confidence: "", proseTier: "" } });
  const r = checkNode(n);
  const hit = r.find((x) => x.startsWith("unadjudicated-agent-prose:"));
  assert.ok(hit, `expected an unadjudicated-agent-prose reason, got ${JSON.stringify(r)}`);
  for (const k of ["role", "description", "why", "whatBreaks"]) assert.ok(hit.includes(k), `${k} is agent prose and must be named`);
});

test("a node with NO prose needs no prose tier — the gate is not a blanket refusal", () => {
  const n = priorNode({
    role: "", description: "", why: "", whatBreaks: "",
    provenance: { tier: "auto", prior: 58, agentCrit: "", votes: 0, agreement: "", contested: false, confidence: "", proseTier: "" },
  });
  assert.deepEqual(checkNode(n), [], "pure measurement publishes without an agent tier because there is no agent in it");
});

test("an unstamped importance basis is refused", () => {
  const n = priorNode();
  delete n.fields.importanceBasis;
  assert.ok(checkNode(n).some((r) => r.startsWith("missing-importance-basis")));
});

test("an unknown tier is refused rather than waved through", () => {
  const n = priorNode({ provenance: { ...priorNode().fields.provenance, tier: "vibes" } });
  assert.ok(checkNode(n).includes("unknown-importance-tier:vibes"));
  assert.ok(!PUBLISHABLE_TIERS.has("vibes"));
});

test("a well-formed node of every publishable tier passes", () => {
  for (const tier of PUBLISHABLE_TIERS) {
    const blended = tier !== "auto";
    const n = blended ? agentNode({ provenance: { ...agentNode().fields.provenance, tier } }) : priorNode();
    assert.deepEqual(checkNode(n), [], `tier ${tier} should publish`);
  }
  assert.deepEqual(checkNode(intentionNode()), []);
});

// ─────────────────────────────────────────────────────────────────────────────
// (b) tier=agent renders a marker in the body
// ─────────────────────────────────────────────────────────────────────────────

test("an agent-judged node renders the L6 marker and its vote record", () => {
  const n = agentNode();
  const text = bodyText(renderFileBlocks(n));
  assert.ok(text.includes(JUDGED_MARK), "a reader must SEE that a judgment is a judgment");
  assert.ok(text.includes("tier agent"));
  assert.ok(text.includes("3 vote(s)"), "the vote count merge.mjs computed must reach the page");
  assert.ok(text.includes("agreement 0.91"));
  assert.ok(text.includes("self-reported confidence high"));
  assert.deepEqual(checkRendered(n, renderFileBlocks(n)), []);
});

test("a contested panel says CONTESTED on the page", () => {
  const n = agentNode({ provenance: { ...agentNode().fields.provenance, tier: "contested", contested: true } });
  assert.ok(judgedLine(n).includes("CONTESTED (panel disagreed)"));
});

test("the two registers are separate blocks, never one sentence", () => {
  const n = agentNode();
  const blocks = renderFileBlocks(n);
  const measured = blocks.filter((b) => bodyText([b]).includes(MEASURED_MARK));
  const judged = blocks.filter((b) => bodyText([b]).includes(JUDGED_MARK));
  assert.ok(measured.length >= 1 && judged.length >= 1);
  for (const b of blocks) {
    const t = bodyText([b]);
    assert.ok(!(t.includes(MEASURED_MARK) && t.includes(JUDGED_MARK)),
      `one block claimed both registers: ${t.slice(0, 120)}`);
  }
});

test("the fused reach heading is gone — the number and the prose are separate blocks", () => {
  const blocks = renderFileBlocks(agentNode());
  for (const b of blocks) {
    const t = bodyText([b]);
    assert.ok(!/transitive dependents.*why reusable/i.test(t),
      "the old heading certified agent prose with a measured parenthetical");
  }
  const reach = blocks.find((b) => (b.text || "").startsWith("Reach "));
  const why = blocks.find((b) => (b.text || "").startsWith("Why it is reusable"));
  assert.ok(reach && reach.text.includes(MEASURED_MARK));
  assert.ok(why && why.text.includes(JUDGED_MARK));
});

test("whatBreaks is rendered, under the judgment marker", () => {
  const n = agentNode();
  const text = bodyText(renderFileBlocks(n));
  assert.ok(text.includes("every authenticated route 401s"),
    "computed-but-undisclosed is the same defect one step further from view");
  const h = renderFileBlocks(n).find((b) => (b.text || "").startsWith("What breaks if this is wrong"));
  assert.ok(h && h.text.includes(JUDGED_MARK));
});

test("a body carries a re-run recipe, so a number is walkable back to a command", () => {
  const text = bodyText(renderFileBlocks(agentNode()));
  assert.ok(text.includes("tooling/file-importance/merge.mjs"));
  assert.ok(text.includes("tooling/usefulness/usefulness.mjs"));
});

test("an unverified consistency candidate says UNVERIFIED, not just a question mark", () => {
  const n = agentNode({ consistency: "layering?", consistencyUnverified: true });
  assert.ok(judgedLine(n).includes("UNVERIFIED candidate"),
    "combine.mjs's trailing '?' was published as punctuation and read as none");
});

test("an intention hub declares its register too", () => {
  const n = intentionNode();
  const blocks = renderIntentionBlocks(n);
  assert.ok(bodyText(blocks).includes(JUDGED_MARK));
  assert.deepEqual(checkRendered(n, blocks), []);
});

test("checkRendered catches a renderer that drops a marker", () => {
  const n = agentNode();
  const stripped = renderFileBlocks(n).filter((b) => !bodyText([b]).includes(JUDGED_MARK));
  assert.ok(checkRendered(n, stripped).includes("body-missing-judgment-marker"),
    "the artefact check must fail on a body a well-formed node produced");
});

// ─────────────────────────────────────────────────────────────────────────────
// (c) importance is never rendered from a prior
// ─────────────────────────────────────────────────────────────────────────────

test("a prior-based node prints `prior`, and the word importance appears nowhere", () => {
  const n = priorNode();
  const blocks = renderFileBlocks(n);
  // proseText, not bodyText: the re-run recipe cites tooling/file-importance/,
  // so a whole-document grep would red on a directory name and prove nothing.
  const text = proseText(blocks);
  assert.ok(/\bprior 58\b/.test(text), "the deterministic priorScore must be called what it is");
  assert.ok(!/\bimportance\b/i.test(text),
    "the shipped body said `importance 58` over a number that was always s.prior");
  assert.deepEqual(checkRendered(n, blocks), []);
});

test("only a real blend earns the word importance, and it shows its terms", () => {
  const n = agentNode();
  const text = bodyText(renderFileBlocks(n));
  assert.ok(text.includes("importance 63 = blend(prior 51 × 45% · agent criticality 73 × 55%)"),
    "if the page says importance it must show both sides of the blend");
  assert.ok(measuredLine(n).includes("prior 51"), "the measured line carries the prior, not the blend");
  assert.ok(!measuredLine(n).includes("importance"), "the measured register never speaks the blended word");
});

test("checkRendered refuses a prior-based body that regained the word importance", () => {
  const n = priorNode();
  const tampered = [...renderFileBlocks(n), { type: "paragraph", content: [{ type: "text", value: "importance 58" }] }];
  assert.deepEqual(checkRendered(n, tampered), ["importance-rendered-from-prior"],
    "this is the tripwire on the exact regression the epic was filed for");
});
