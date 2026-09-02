// Shared node fixtures for the barkpark-sync suite.
//
// `bareNode()` is deliberately the shape generate.mjs produced BEFORE this
// slice: metrics, prose, no provenance, importance holding a deterministic
// prior. It is the specimen, so every test that asserts a refusal starts from
// the artefact that actually shipped rather than from an invented one.

export function bareNode(over = {}) {
  return {
    id: "api-lib-barkpark-accounts-ex",
    path: "api/lib/barkpark/accounts.ex",
    title: "api/lib/barkpark/accounts.ex",
    deps: [],
    content: "defmodule Barkpark.Accounts do\nend\n",
    fields: {
      path: "api/lib/barkpark/accounts.ex", basename: "accounts.ex", dir: "api/lib/barkpark", ext: "ex",
      stack: "elixir", importance: 58, priority: 0,
      role: "account lifecycle", description: "registration, login, sessions",
      tokens: 3644, loc: 456, sizeClass: "ideal", defs: 12,
      churn: 5, fanIn: 3, seam: false,
      testScore: 91, hasTest: true, defectDensity: 0,
      consistency: "intentional", whatBreaks: "every authenticated route 401s",
      reach: 0, why: "reusable across every surface",
      primaryAuthorShare: 60, authorCount: 2,
      intentions: [], accidentalCoupling: false, cochangePartners: [],
      git: { commits: [], commitCount: 5, firstDate: "2026-01-01", lastDate: "2026-08-01", authors: ["a", "b"] },
      dependents: [], dependentCount: 0,
      ...over,
    },
  };
}

/** The same node as generate.mjs emits it today: labelled, prior-based. */
export function priorNode(over = {}) {
  return bareNode({
    importanceBasis: "prior",
    provenance: { tier: "auto", prior: 58, agentCrit: "", votes: 0, agreement: "", contested: false, confidence: "", proseTier: "agent" },
    consistencyUnverified: false, severity: 0,
    ...over,
  });
}

/** A file an agent panel actually judged: the blend happened, tier is `agent`. */
export function agentNode(over = {}) {
  return bareNode({
    importance: 63,
    importanceBasis: "blended",
    provenance: { tier: "agent", prior: 51, agentCrit: 73, votes: 3, agreement: "0.91", contested: false, confidence: "high", proseTier: "agent" },
    consistencyUnverified: false, severity: 0,
    ...over,
  });
}

export function intentionNode(over = {}) {
  return {
    id: "intent-auth", path: "intent-auth", title: "Authentication", kind: "intention",
    deps: [], depPaths: [], intentRefs: [],
    content: "Authentication\n\nKeep every surface behind one identity.\n\nScale: epic\n\nFiles advancing this intention (2):\n  • a\n  • b",
    fields: { kind: "intention", scale: "epic", title: "Authentication", description: "Keep every surface behind one identity.", members: 2, provenance: { proseTier: "taxonomy" }, ...over },
  };
}

export const wrap = (nodes) => ({ generatedFrom: "test", nodes, stats: { nodes: nodes.length, edges: 0, avgDegree: 0, orphans: 0 } });
