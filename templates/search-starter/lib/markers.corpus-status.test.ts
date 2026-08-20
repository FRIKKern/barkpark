import assert from "node:assert/strict";
import { test } from "node:test";

import {
  CORPUS_STATUS_MARKER_MAX,
  corpusStatusMarkerValue,
  sanitizeMarkerValue,
} from "./markers.ts";

/**
 * The `bp-corpus-status` marker is an INTERFACE, not a log line: the SSR writes
 * it into the served HTML, `deploy/site-deploy-node.sh` reads it back with a
 * `sed` over `content="…"` and folds it into HEALTH_DETAIL, and that string
 * becomes the deployment row's `failure_reason` — the thing an operator reads
 * when a build could not see its content.
 *
 * The shell self-test proves the ENGINE half against a fixture that hard-codes
 * the marker text. That is the wrong direction to prove this half: if the
 * template's wording drifted, the fixture would keep passing and the two ends of
 * the contract would part company in silence. These tests pin the template half.
 */

const failed = (reason: string) => ({ upstreamReason: reason, nodeCount: 0 });

test("a healthy render records NOTHING — no doc id, no marker, no invented cause", () => {
  assert.equal(
    corpusStatusMarkerValue({ upstreamReason: null, nodeCount: 42 }, "barkpark"),
    "",
  );
  // Even a failed read is silent once the page DID anchor a document: the marker
  // exists to explain an empty bp-doc-id, never to decorate a working one.
  assert.equal(corpusStatusMarkerValue(failed("graph 403: nope"), "barkpark"), "");
});

test("an unreadable corpus names the upstream condition VERBATIM", () => {
  // The exact bytes deploy/site-deploy-node.sh's `.no-corpus` fixture asserts on.
  const reason =
    "graph 403: public-read tokens may only read published public documents";

  assert.equal(corpusStatusMarkerValue(failed(reason), ""), reason);
  assert.equal(
    corpusStatusMarkerValue(failed("graph 401: missing bearer token"), ""),
    "graph 401: missing bearer token",
  );
  // Network/timeout/parse — status 0, still legible, still not blank.
  assert.equal(
    corpusStatusMarkerValue(failed("graph 0: fetch failed"), ""),
    "graph 0: fetch failed",
  );
});

test("a read that SUCCEEDED and had nothing to anchor says so, and never claims a failure", () => {
  const value = corpusStatusMarkerValue(
    { upstreamReason: null, nodeCount: 0 },
    "",
  );

  assert.equal(
    value,
    "graph 200: corpus read OK but carried 0 node(s), none usable as a content anchor",
  );
  // The distinction the whole slice exists for: an empty corpus is NOT a 403.
  assert.ok(!value.includes("403"));
  assert.ok(!value.includes("401"));
});

test("the value stays sed-safe: single line, no quotes or angle brackets", () => {
  const hostile = `graph 500: <script>alert("x")</script>\nsecond 'line'\there`;
  const value = corpusStatusMarkerValue(failed(hostile), "");

  for (const forbidden of ['"', "'", "<", ">", "\n", "\r", "\t"]) {
    assert.ok(
      !value.includes(forbidden),
      `marker leaked ${JSON.stringify(forbidden)}: ${value}`,
    );
  }
  assert.ok(value.startsWith("graph 500:"));
});

test("the value is BOUNDED — one chatty upstream body cannot bloat the SSR head", () => {
  const value = corpusStatusMarkerValue(
    failed(`graph 500: ${"x".repeat(5_000)}`),
    "",
  );

  assert.equal(value.length, CORPUS_STATUS_MARKER_MAX);
  assert.ok(value.endsWith("…"), "a truncated marker says it was truncated");
});

test("sanitizeMarkerValue collapses runs of whitespace rather than leaving ragged gaps", () => {
  assert.equal(sanitizeMarkerValue("  graph   403:    nope  "), "graph 403: nope");
});
