<!-- doc-tier: cold | canonical-for: legendary-paper-verify-29-evidence | budget: 1800tok -->
# Verify 29 — deployed route availability and error taxonomy

Verdict: narrowly `proven`, broadly `refuted`, with historical root cause `carried`. Correct capabilities, OpenAPI/schema, Paper reader/source, document get/query, history, and revision routes are not deterministically absent. Wrong paths, missing resources, missing authentication, and Paper-source content negotiation produce stable 401/404/406 controls rather than availability failures. Earlier 500s and timeouts are compatible with transient deployment trouble, but their cause cannot be proven without retained request IDs and server/proxy logs.

The verifier pinned repository commit `82f1b5e79ae0bc4e8189ae1692a652c0529c3e20`. The deployed build identified itself as commit `2154e695f`, release `0.2.25`, version `0.2.25.2433`, built `2026-08-05T21:16:53Z`.

The labeled core matrix ran 26 variants across three rounds with two immediate identical attempts per round: 156 total requests, 108×200, 18×401, 18×404, and 12×406. It observed zero 5xx responses, timeouts, request-ID echo mismatches, or paired-status mismatches. Every valid surface succeeded 6/6: public/authenticated capabilities, public OpenAPI and legacy schema, authenticated flat/scoped runtime schemas, flat/scoped Paper HTML and source with `Accept: */*`, and authenticated flat/scoped document get/query/history/revision.

Every deterministic control repeated 6/6: missing get/source/revision returned 404, schema/history without valid authentication returned 401, and explicit `Accept: application/json` on Paper source returned 406. Representative paired requests varied from 251ms to 5,166ms while both returned 200, proving substantial latency variability without route disappearance.

A separate matrix against the previously problematic `cloud-console-hardening-wave-28-2026-08-03` ran 120 requests over HTML, source, get, query, history, and revision, flat and scoped. All 120 returned 200 with zero timeout, 5xx, or paired-status mismatch. Additional wrong-path and negotiation controls repeated identical results twice. Capabilities and OpenAPI conditional reads returned 304 with zero-byte bodies. Flat/scoped canonical hashes agreed for source, get, query, history, revision, and schema after documented volatile timing fields were removed.

Historical ledgers show a genuinely intermittent pattern: Survey 43 recorded broad 500s followed by a 20/20 pass; Survey 45 recorded an HTML 500 followed by an immediate 200; Survey 55 recorded initial 500s and a capabilities timeout followed by 12/12 200s; Verify 06 recorded two Wave 28 500s that recovered immediately. These records refute deterministic absence but lack the request-ID/log correlation needed to assign an operational cause.

The relevant router and capabilities, OpenAPI, schema, Paper-source, history, and query controller files are byte-identical between deployed commit `2154e695f` and the verifier commit. Current behavior is therefore not attributable to source/deployment skew in those seams.

Two deterministic defects were proven:

1. Paper source is routed through an HTML-accepting browser pipeline even though its controller returns JSON. `Accept: */*` succeeds; explicit `Accept: application/json` returns 406. The 406 body misleadingly calls this an internal error and recommends retrying.
2. `internal/cli/paper_cmd.go` maps every Paper read error—including 500, timeout, 406, and 422—to `not_found`/exit-not-found. Existing rejection tests assert only non-success, so they do not protect the taxonomy. Missing Paper source likewise returns plain-text `404 not found` instead of the structured request-ID envelope.

Fresh focused Go tests passed for history/revision request shape, Paper source, schema loading, Paper-view rejection, capability reads, and schema-fetch failure envelopes. ExUnit could not run because API test dependencies/build artifacts were absent; no API-suite pass is claimed.

Required repair seams are status/code/request-ID preservation in `bp paper view`, explicit 500/timeout/401/406/422 taxonomy tests, JSON-compatible Paper-source negotiation, structured missing-source errors, and durable request-ID/build-identity retention for future reliability probes. Current probes prove route presence and stable contracts, not uninterrupted production availability across time.

The verifier inspected PDS 44 and Cloud Console 28, Surveys 43/45/55, Verifies 06/20/27, the relevant routing/controllers, Go client/CLI, and contract tests. Probe artifacts were moved to Trash. No repository or Barkpark mutation occurred.
