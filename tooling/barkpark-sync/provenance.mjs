// The publish-boundary provenance gate for tooling/barkpark-sync.
//
// WHY THIS FILE EXISTS. The pipeline already COMPUTES the discriminator this
// gate needs and then throws it away one hop before publication: merge.mjs
// tracks tier/prior/agentCrit/votes/agreement/contested/confidence per file and
// emits them only to a spreadsheet; combine.mjs marks unverified issue verdicts
// with a trailing "?" and carries a severity; the research ledger stamps a tier
// on every piece of prose it hands out. generate.mjs read none of it, so
// push.mjs could not render it, so a published paper put an agent's L6 opinion
// and a git commit count in the same sentence, in the same typeface, with the
// same air of measurement. That is the laundering step.
//
// Everything here is PURE and side-effect free so it can be proven without a
// server: push.mjs calls gateNodes() before its first mutation and renderBlocks()
// for every body it ingests, and the suite under test/ calls the same functions.
//
export const GATE_VERSION = 1;

// Tiers as merge.mjs writes them. "MISSING" is merge.mjs's own marker for a
// code/test file that NO agent ever judged; it is a legitimate tier to compute
// and an illegitimate one to publish prose under, which is why it is listed
// separately from the publishable set rather than simply left out.
export const PUBLISHABLE_TIERS = new Set(["agent", "contested", "auto"]);
export const UNADJUDICATED_TIERS = new Set(["MISSING", "missing", ""]);

// The two registers a paper body is allowed to speak in. Every rendered
// paragraph belongs to exactly one of them and says so in its own text.
export const MEASURED_MARK = "MEASURED · re-runnable";
export const JUDGED_MARK = "AGENT JUDGMENT (L6) · not measured";

// Fields whose value is an agent's opinion in prose form. If any of these are
// non-empty the node MUST carry a prose tier, or the gate refuses it.
export const AGENT_PROSE_FIELDS = ["role", "description", "why", "whatBreaks"];

// How the published importance number was arrived at. There is no third option:
// either the 45/55 blend from merge.mjs is available, or the number is the
// deterministic priorScore and must be called `prior` in the body.
export const IMPORTANCE_BASES = new Set(["blended", "prior"]);

const nonEmpty = (v) => v != null && String(v).trim() !== "";
const isIntention = (n) => n?.kind === "intention" || n?.fields?.kind === "intention";

/**
 * Named reasons a single node may not be published. Empty array = publishable.
 * Reason strings are part of the contract: push.mjs prints them and the suite
 * asserts on them, so a silent rename would be caught.
 */
export function checkNode(node) {
  const reasons = [];
  const f = node?.fields || {};
  const p = f.provenance;

  if (!p || typeof p !== "object") {
    reasons.push("missing-provenance");
    return reasons; // nothing below can be judged without it
  }

  if (isIntention(node)) {
    // A taxonomy hub publishes an objective title + description an agent wrote.
    // It has no importance and no metrics, but it still has a register.
    if (p.proseTier !== "taxonomy") reasons.push(`unknown-prose-tier:${p.proseTier ?? "(none)"}`);
    return reasons;
  }

  // ---- the importance label ----
  if (!IMPORTANCE_BASES.has(f.importanceBasis)) {
    reasons.push(`missing-importance-basis:${f.importanceBasis ?? "(none)"}`);
  } else if (f.importanceBasis === "blended" && !nonEmpty(p.agentCrit)) {
    // Claiming a blend of prior and agent criticality while holding no agent
    // criticality is the mislabel this gate was written for, inverted.
    reasons.push("blended-without-agent-input");
  }

  // ---- the importance tier ----
  if (UNADJUDICATED_TIERS.has(p.tier ?? "")) {
    if (f.importanceBasis === "blended") reasons.push(`blended-under-unadjudicated-tier:${p.tier || "(empty)"}`);
  } else if (!PUBLISHABLE_TIERS.has(p.tier)) {
    reasons.push(`unknown-importance-tier:${p.tier}`);
  }

  // ---- the prose ----
  const prose = AGENT_PROSE_FIELDS.filter((k) => nonEmpty(f[k]));
  if (prose.length) {
    if (!nonEmpty(p.proseTier)) reasons.push(`unadjudicated-agent-prose:${prose.join(",")}`);
    else if (!PUBLISHABLE_TIERS.has(p.proseTier)) reasons.push(`unknown-prose-tier:${p.proseTier}`);
  }

  return reasons;
}

// Gate a whole batch. `failures` carries the id/path so a refusal names a file.
// This is the one door tooling/barkpark-sync publishes through.
// @canonical capability:published-paper-provenance-gate aka:agent-tier,evidence-tier,L6,importance-prior-mislabel,launder,barkpark-sync-gate
export function gateNodes(nodes) {
  const failures = [];
  for (const n of nodes || []) {
    const reasons = checkNode(n);
    if (reasons.length) failures.push({ id: n.id, path: n.path, reasons });
  }
  return { ok: failures.length === 0, failures, checked: (nodes || []).length };
}

// ---------------------------------------------------------------------------
// Rendering. Two lines, two registers, never one sentence spanning both.
// ---------------------------------------------------------------------------

/**
 * Programmatic facts only. Every term here re-derives from a parser, the git
 * log or the dependency graph with no agent in the loop — including the
 * importance number, which under basis "prior" IS the deterministic priorScore
 * and is therefore named `prior`, not `importance`.
 */
export function measuredLine(node) {
  const f = node.fields || {};
  const basis = f.importanceBasis;
  const head = basis === "blended"
    ? `prior ${f.provenance?.prior ?? "?"}`
    : `prior ${f.importance ?? "?"}`;
  const parts = [
    head,
    `reach ${f.reach ?? "?"}/100 (transitive dependents)`,
    `${f.sizeClass || "?"} ${f.tokens ?? "?"}tok/${f.loc ?? "?"}loc`,
    `churn ${f.churn ?? "?"}`,
    `depends-on ${(node.deps || []).length}`,
    `depended-on-by ${f.dependentCount ?? 0}`,
    `owners ${f.authorCount ?? "?"} (top ${f.primaryAuthorShare ?? "?"}%)`,
    `test ${f.testScore ?? "?"}`,
    `defect ${f.defectDensity ?? "?"}`,
  ];
  if (f.seam) parts.push("🔗seam");
  return `${MEASURED_MARK} · ${parts.join(" · ")}`;
}

/**
 * Everything an agent decided, with the tier and the vote record that decided
 * it. The word "importance" appears in a published body ONLY from here, and
 * only when the 45/55 blend actually happened.
 */
export function judgedLine(node) {
  const f = node.fields || {};
  const p = f.provenance || {};
  const parts = [];
  if (f.importanceBasis === "blended") {
    parts.push(`importance ${f.importance ?? "?"} = blend(prior ${p.prior ?? "?"} × 45% · agent criticality ${p.agentCrit ?? "?"} × 55%)`);
  }
  parts.push(`tier ${p.tier || "auto"}`);
  if (nonEmpty(p.votes)) parts.push(`${p.votes} vote(s)${nonEmpty(p.agreement) ? ` · agreement ${p.agreement}` : ""}${p.contested ? " · CONTESTED (panel disagreed)" : ""}`);
  if (nonEmpty(p.confidence)) parts.push(`self-reported confidence ${p.confidence}`);
  if (nonEmpty(f.consistency)) parts.push(`consistency ${f.consistency}${f.consistencyUnverified ? " (UNVERIFIED candidate — run issue-judgment)" : ""}`);
  if (nonEmpty(f.priority)) parts.push(`priority ${f.priority} (formula over the agent consistency verdict)`);
  if (nonEmpty(p.proseTier)) parts.push(`prose tier ${p.proseTier}`);
  return `${JUDGED_MARK} · ${parts.join(" · ")}`;
}

const para = (value) => ({ type: "paragraph", content: [{ type: "text", value }] });

/**
 * The paper body for one file node. `all` maps node id → path for the deps list
 * and `tax` maps intention id → title; both are supplied by push.mjs.
 */
export function renderFileBlocks(node, { lang = "text", depsList = "", intentions = "(none)" } = {}) {
  const f = node.fields || {};
  const p = f.provenance || {};
  const blocks = [
    { type: "heading", level: 1, text: node.path },
    para(measuredLine(node)),
    para(judgedLine(node)),
  ];
  const role = (f.role || "") + (f.description ? " — " + f.description : "");
  if (nonEmpty(role)) {
    blocks.push({ type: "heading", level: 2, text: `Role and description — ${JUDGED_MARK}` });
    blocks.push(para(role));
  }
  // The old body fused a measured number and agent prose into ONE heading —
  // "Reach N/100 (transitive dependents) · why reusable" — so the parenthetical
  // certified the number and the prose inherited the certification. Split.
  blocks.push({ type: "heading", level: 2, text: `Reach ${f.reach ?? "?"}/100 — transitive dependents, ${MEASURED_MARK}` });
  blocks.push({ type: "heading", level: 3, text: `Why it is reusable — ${JUDGED_MARK}` });
  blocks.push(para(f.why || "(no agent description on file)"));
  // whatBreaks was computed into nodes.json and never rendered: a judgment
  // sitting even further from view than an unlabelled one. Rendered, marked.
  if (nonEmpty(f.whatBreaks)) {
    blocks.push({ type: "heading", level: 2, text: `What breaks if this is wrong — ${JUDGED_MARK}` });
    blocks.push(para(f.whatBreaks));
  }
  blocks.push(
    { type: "heading", level: 2, text: `Intentions it serves (${(f.intentions || []).length})` },
    { type: "code", language: "text", value: intentions },
    { type: "heading", level: 2, text: `Depends on (${(node.deps || []).length}) — ${MEASURED_MARK}` },
    { type: "code", language: "text", value: depsList },
    { type: "heading", level: 2, text: `Depended on by (${f.dependentCount ?? 0}) — ${MEASURED_MARK}` },
    { type: "code", language: "text", value: (f.dependents || []).slice(0, 50).map((x) => "← " + x).join("\n") + ((f.dependents || []).length > 50 ? `\n… (+${f.dependents.length - 50} more)` : "") || "(nothing in the graph depends on this)" },
    { type: "heading", level: 2, text: `Git history (${f.git?.commitCount ?? 0} commits · ${f.git?.authors?.length ?? 0} authors · ${f.git?.firstDate || "?"} → ${f.git?.lastDate || "?"}) — ${MEASURED_MARK}` },
    { type: "code", language: "text", value: (f.git?.commits || []).map((c) => `${c.date}  ${c.hash}  ${(c.author || "").split(" ")[0]}  ${c.subject}`).join("\n") || "(no history)" },
    { type: "heading", level: 2, text: "How to re-derive these numbers" },
    { type: "code", language: "bash", value: rerunRecipe(p) },
    { type: "heading", level: 2, text: "Source" },
    { type: "code", language: lang, value: node.content || "(empty)" },
  );
  return blocks;
}

export function renderIntentionBlocks(node) {
  const f = node.fields || {};
  return [
    { type: "heading", level: 1, text: `🎯 ${f.title}` },
    para(`${f.scale === "epic" ? "Epic intention" : "Intention"} · ${f.members} files advance this.`),
    para(`${JUDGED_MARK} · the objective and its description are an agent taxonomy, not a measurement.`),
    para(f.description || ""),
    { type: "heading", level: 2, text: "Files advancing this intention" },
    { type: "code", language: "text", value: (node.content || "").split("Files advancing")[1]?.split(":").slice(1).join(":").trim() || "" },
  ];
}

function rerunRecipe(p) {
  return [
    "# measured signals (no agent in the loop)",
    "node tooling/file-importance/build-signals.mjs   # prior, churn, loc, fanIn, seam",
    "node tooling/usefulness/usefulness.mjs           # reach",
    "node tooling/risk/risk.mjs                       # owners, test, defect",
    "node tooling/ergonomics/ergonomics.mjs           # tokens, loc, sizeClass",
    "",
    "# agent judgments (re-running these re-asks the agents; verdicts may move)",
    "node tooling/file-importance/merge.mjs           # tier, agentCrit, votes, agreement",
    "node tooling/combined/combine.mjs                # consistency, severity, priority",
    "",
    `# rendered under gate version ${GATE_VERSION} · score tier "${p.tier || "auto"}" · prose tier "${p.proseTier || "(none)"}"`,
  ].join("\n");
}

/**
 * The prose surface of a body: headings and paragraph text, never a code
 * block's value. This is the exact scope checkRendered judges, exported so the
 * suite asserts on the same surface the gate reads — a test that greps the
 * whole document instead would red on the word "importance" appearing in the
 * re-run recipe's own file path, which measures nothing about the render.
 */
export function proseText(blocks) {
  return (blocks || []).map((b) => b.text ?? (b.content || []).map((c) => c.value).join("") ?? "").join("\n");
}

/**
 * The last line of defence, run over the blocks that are ABOUT to be posted.
 * checkNode() judges the data; this judges the artefact, so a future edit to
 * the renderer that reintroduces the mislabel is refused even though the node
 * itself is well-formed.
 *
 * It reads headings and paragraph text ONLY, never a code block's value. A code
 * block holds the file's own source and the re-run recipe; scanning those for
 * the word "importance" would red every paper about a file that happens to
 * contain it — merge.mjs above all — which is a scan of the wrong thing, not a
 * stricter gate. The register claims live in prose, so prose is what is judged.
 */
export function checkRendered(node, blocks) {
  const reasons = [];
  const texts = proseText(blocks);
  if (isIntention(node)) {
    if (!texts.includes(JUDGED_MARK)) reasons.push("intention-body-unmarked");
    return reasons;
  }
  if (!texts.includes(MEASURED_MARK)) reasons.push("body-missing-measured-marker");
  if (!texts.includes(JUDGED_MARK)) reasons.push("body-missing-judgment-marker");
  if (node.fields?.importanceBasis !== "blended" && /\bimportance\b/i.test(texts)) {
    reasons.push("importance-rendered-from-prior");
  }
  return reasons;
}
