/**
 * Tests for the REAL truncation law (`lib/graph-truncation.ts`) that
 * `lib/graph.ts` reads the `/v1/graph` payload through and
 * `components/graph-landing.tsx` renders (task-b1d01077c255c335). Like
 * `paginate.test.ts` and unlike `listings.test.ts` these are NOT hand-kept
 * mirrors: `graph-truncation.ts` imports nothing, so `node --test` loads the
 * shipped code directly.
 *
 * The defect class under pin: `lib/graph.ts` declared `UpstreamGraph` as
 * `{ nodes?, edges? }` and dropped the `truncated` / `truncation_reason` pair
 * the endpoint has emitted all along, so the Next.js finder landing drew a
 * capped subset of the corpus with nothing saying so. `/v1/graph?dataset=
 * production` answers `truncated: true, truncation_reason: "per_type_cap"`
 * today.
 *
 * NAMED MUTANTS each test kills:
 *   • drop-the-pair            → every readTruncation test reds (flag never set)
 *   • trust-any-truthy         → the "only a literal true" test reds
 *   • keep-reason-without-flag → the orphan-reason test reds
 *   • one-sentence-for-all     → the per-reason tests red (wrong ceiling named)
 *   • notice-on-a-clean-graph  → the no-false-partial test reds
 *   • silent-on-unnamed-reason → the unnamed-ceiling test reds
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  readTruncation,
  truncationNotice,
  TRUNCATION_REASONS,
} from "../lib/graph-truncation.ts";

/* ── readTruncation ─────────────────────────────────────────────────────── */

test("carries a real upstream truncation out of the payload instead of dropping it", () => {
  // The live production shape, verbatim.
  assert.deepEqual(
    readTruncation({ truncated: true, truncation_reason: "per_type_cap" }),
    { truncated: true, truncationReason: "per_type_cap" },
  );
});

test("a complete corpus stays complete — no manufactured partial claim", () => {
  assert.deepEqual(readTruncation({ truncated: false, truncation_reason: null }), {
    truncated: false,
    truncationReason: null,
  });
  // An endpoint that omits the pair entirely (an older server) must not be
  // read as "partial" — absence is not a truncation.
  assert.deepEqual(readTruncation({}), { truncated: false, truncationReason: null });
  assert.deepEqual(readTruncation(null), { truncated: false, truncationReason: null });
  assert.deepEqual(readTruncation(undefined), { truncated: false, truncationReason: null });
});

test("only a LITERAL true sets the flag — no truthy coercion", () => {
  for (const v of ["true", 1, {}, [], "yes"]) {
    assert.deepEqual(
      readTruncation({ truncated: v, truncation_reason: "node_budget" }),
      { truncated: false, truncationReason: null },
      `truthy value ${JSON.stringify(v)} must not manufacture a truncation claim`,
    );
  }
});

test("a reason WITHOUT the flag is discarded, never promoted into a claim", () => {
  assert.deepEqual(
    readTruncation({ truncated: false, truncation_reason: "node_budget" }),
    { truncated: false, truncationReason: null },
  );
  assert.deepEqual(readTruncation({ truncation_reason: "per_type_cap" }), {
    truncated: false,
    truncationReason: null,
  });
});

test("a truncation with a junk or blank reason keeps the FLAG and drops the reason", () => {
  for (const junk of [null, "", "   ", 42, {}]) {
    assert.deepEqual(
      readTruncation({ truncated: true, truncation_reason: junk }),
      { truncated: true, truncationReason: null },
      `reason ${JSON.stringify(junk)} is unusable but the truncation is still real`,
    );
  }
});

test("a reason is trimmed, not reshaped", () => {
  assert.deepEqual(
    readTruncation({ truncated: true, truncation_reason: "  node_budget  " }),
    { truncated: true, truncationReason: "node_budget" },
  );
});

/* ── truncationNotice ───────────────────────────────────────────────────── */

test("a complete graph shows NO notice (no false-partial noise)", () => {
  assert.equal(truncationNotice(false, null), null);
  // Even if a reason somehow rides along, the flag is what gates the copy.
  assert.equal(truncationNotice(false, "node_budget"), null);
});

test("every reason the server can emit gets its own sentence", () => {
  const seen = new Set<string>();
  for (const reason of TRUNCATION_REASONS) {
    const notice = truncationNotice(true, reason);
    assert.ok(notice, `${reason} must produce a notice`);
    assert.ok(!seen.has(notice), `${reason} must not reuse another ceiling's sentence`);
    seen.add(notice);
  }
  assert.equal(seen.size, TRUNCATION_REASONS.length);
});

test("per_type_cap does NOT claim the reader is seeing 'the first N'", () => {
  const notice = truncationNotice(true, "per_type_cap");
  assert.ok(notice);
  // The per-type ceiling cuts EACH TYPE at its own limit — it is a sample
  // across types, not a prefix of one list. Copy that says "the first N" names
  // the wrong ceiling (the mistake the search-starter fork shipped).
  assert.ok(
    !/\bfirst\b/i.test(notice),
    `per_type_cap copy must not describe a prefix: ${notice}`,
  );
  assert.match(notice, /per-type/i);
});

test("node_budget names the whole-graph ceiling", () => {
  const notice = truncationNotice(true, "node_budget");
  assert.ok(notice);
  assert.match(notice, /whole-graph|node ceiling/i);
});

test("the combined reason names BOTH ceilings", () => {
  const notice = truncationNotice(true, "per_type_cap+node_budget");
  assert.ok(notice);
  assert.match(notice, /per-type/i);
  assert.match(notice, /node ceiling|whole-graph/i);
});

test("a truncation with an UNNAMED ceiling still says the corpus was cut", () => {
  // Silence is the one outcome this module exists to prevent: a server that
  // declares a truncation without a reason (or ships a reason string this
  // build has never heard of) must still produce a visible notice.
  for (const reason of [null, "some_future_ceiling"]) {
    const notice = truncationNotice(true, reason);
    assert.ok(notice, `truncated:true with reason ${reason} must still notify`);
    assert.match(notice, /partial/i);
  }
});

test("every notice opens by naming the graph as partial", () => {
  for (const reason of [...TRUNCATION_REASONS, null, "unknown"]) {
    const notice = truncationNotice(true, reason);
    assert.ok(notice);
    assert.match(notice, /^Partial graph\b/);
  }
});

/* ── shipped wiring ─────────────────────────────────────────────────────────
 *
 * The law above is only worth anything if the three files that carry it are
 * actually wired to it. `lib/graph.ts` imports `server-only` + `next/cache` +
 * `@/` aliases and the two React files are JSX, so none of them loads under
 * bare `node --test` — the same constraint `template-webhook-lazy.test.ts`
 * solves by reading the shipped bytes from disk. Without these, deleting the
 * `readTruncation(json)` call would leave every test above GREEN while the
 * landing went silent again, which is exactly the defect this row is about.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const shipped = (rel: string) =>
  readFileSync(fileURLToPath(new URL(`../${rel}`, import.meta.url)), "utf8");

test("SHIPPED (lib/graph.ts): the upstream pair is declared, read, and returned", () => {
  const src = shipped("lib/graph.ts");
  // Assert the CALL, not the identifier: an `import { readTruncation }` left
  // behind by a gutted body would satisfy a bare /readTruncation/ match, and
  // did — that mutant survived the first draft of this test.
  assert.match(
    src,
    /=\s*readTruncation\(json\)/,
    "graph.ts must read the pair OFF THE PAYLOAD through the law",
  );
  assert.match(src, /truncation_reason\?:\s*unknown/, "UpstreamGraph must declare the reason");
  assert.match(src, /truncated\?:\s*unknown/, "UpstreamGraph must declare the flag");
  assert.match(
    src,
    /truncated:\s*boolean/,
    "CorpusGraph must expose truncated to its consumers",
  );
  assert.match(src, /truncationReason:\s*string \| null/);
  // The degrade path must still RETURN the pair — a `CorpusGraph` missing it
  // would not typecheck, but the honest VALUE there is false/null (an
  // unreadable corpus is not a truncated one).
  assert.match(
    src,
    /rootId:\s*null,\s*truncated:\s*false,\s*truncationReason:\s*null/,
    "the catch-all degrade must return an explicit non-truncated pair",
  );
});

test("SHIPPED (graph-landing.tsx): the notice is VISIBLE copy, not a tooltip", () => {
  const src = shipped("components/graph-landing.tsx");
  assert.match(src, /truncationNotice\(truncated, truncationReason\)/);
  assert.match(src, /data-testid="graph-truncation-notice"/);
  // A `title=` carrying the reason is the shape this fix deliberately does not
  // ship: invisible to touch, to screen readers reading the caption, and to
  // anyone who never hovers.
  assert.ok(
    !/title=\{truncationReason/.test(src),
    "the reason must not be hidden behind a title attribute",
  );
});

test("SHIPPED (app/(finder)/page.tsx): the landing is handed the pair", () => {
  const src = shipped("app/(finder)/page.tsx");
  assert.match(src, /truncated,\s*truncationReason\s*\}\s*=\s*\n?\s*await fetchCorpusGraph\(\)/);
  assert.match(src, /truncated=\{truncated\}/);
  assert.match(src, /truncationReason=\{truncationReason\}/);
});
