<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-03 | budget: 1400tok -->
# Restart Survey 03 — CLI/API negative capability and evidence strength

Assignment `restart-survey-03` re-attested `cloud-console-hardening-wave-28-2026-08-03::cli_api` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **partial, decision-useful, current contradiction**.

## Direct answer

Successful outputs preserve the exact Paper and respect the requested width, but current CLI reads are intermittent and every upstream read failure is incorrectly surfaced as `not_found` with exit 4. Related discovery is deliberately fail-open, so a successful Paper body can silently omit known related records. Historical claims in the Paper remain evidence inputs, not fresh proof.

## Current observations

- Anonymous canonical source: HTTP 200, 130,346 bytes, revision `49c1534d9fb76d0d9adc7b97f25ec471`, 237 blocks.
- Successful width-80 human render: maximum 80 display cells, zero overflow.
- Five identical raw CLI reads: 3 success, 2 server-500 failures.
- Four human reads: timeout, success, server 500, success.
- Both timeout and server 500 became CLI `not_found`, exit 4; the unconditional mapping is at `internal/cli/paper_cmd.go:237-239`.
- Deliberately missing Paper: exit 4 with a structured `not_found` JSON envelope, proving the valid negative shape.
- Invalid perspective under `-o json`: exit 2 with human usage text, contradicting uniform machine-error output.
- Authenticated related read: 10 records. Anonymous related read: 403. One successful 2,337-line body omitted the Related heading because `paperRenderRelated` suppresses transport, non-2xx, decode, and empty outcomes.
- Backlinks: zero. History: 12 events, six create and six publish.
- Current source confirms `.github/workflows/console-harness.yml` uses `fetch-depth: 0`; the Paper's historical `2693/0` suite count was not rerun.

Positive control: anonymous canonical Paper source succeeds and carries the exact revision/block count. Negative control: a nonexistent Paper returns the intended structured missing-document error. Adversarial control: primary source succeeds while the unauthenticated secondary Related capability returns 403 and disappears silently from the human reader.

## Evidence ruling

Proven: exact public source identity; successful raw-read identity; width containment; history and authenticated related discovery; current full-history checkout configuration.

Contradicted: reliable CLI Paper reads; accurate separation of upstream failure from missing content; diagnostic meaning of an absent Related section; uniform JSON usage errors.

Inferred or carried: cause of transient 500s; historical full-suite count; editorial A-minus grade. No proxy pass is granted.

## Risks and unvisited scope

Automation can take the wrong recovery path because a transient failure is indistinguishable from a missing Paper. Readers cannot distinguish no related documents from lookup failure. The wider Cloud implementation and historical test suite were not exhaustively rerun; related Paper bodies were not inspected. The current worktree is campaign evidence, not an origin/main integration proof.

## Cycle payload

```json
{"assignment_id":"restart-survey-03","unit":"cloud-console-hardening-wave-28-2026-08-03::cli_api","verdict":"partial","paper":{"rev":"49c1534d9fb76d0d9adc7b97f25ec471","blocks":237},"samples":{"raw_success":3,"raw_server_500":2,"human_success":2,"human_timeout":1,"human_server_500":1,"related":10,"history":12},"proven":["exact successful reader identity","80-cell containment","history and authenticated related discovery"],"contradicted":["reader reliability","upstream error taxonomy","Related absence as evidence","uniform JSON usage errors"],"carried":["500 root cause","historical full-suite result"]}
```
