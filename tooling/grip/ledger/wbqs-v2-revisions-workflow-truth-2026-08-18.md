<!-- doc-tier: cold | canonical-for: none | budget: 800tok -->
# wild-bulk-cycle-v2-revisions — workflow-truth verdict (2026-08-18)

Verifier row for the Wild-Bulk-Quality-Sweep reconciliation wave. Disposition: **FULL-UNBUILT — KEEP-OPEN** (offline-buildable, not gated). NOT closeable by evidence.

## Criteria (re-derive)

    bp task get wild-bulk-cycle-v2-revisions -o json | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print(d['criteria_progress']);[print(i,repr(c['criterion'])) for i,c in enumerate(d['content']['acceptance_criteria'])]"

- `criteria_progress = {'met':0,'total':3}` — total is **3**, not 5. The five named revisions are packed into criterion **C0**.
- C0 = "workflow.js carries all five revisions (roster reconciliation, verdict retry, no-gitignored-stand-ins builder rule, formatter in Elixir/Go builder gates, openapi-regen budgeting in cutter guidance) and node --check passes" — a SOURCE-ARTIFACT criterion.
- C1 = "next wild-bulk run completes with zero absent-builder surprises + verdict survives transient 5xx" — a LIVE-RUN observational criterion (needs an actual wave; cannot be closed by static evidence).
- C2 = "PR merged with Task: wild-bulk-cycle-v2-revisions in the body" — no such PR.

## Per-revision presence on origin/main (0/5 shipped)

    git show origin/main:.claude/workflows/wild-bulk-cycle.workflow.js | grep -niE 'format|gofmt|openapi|regen|node_modules|installable|stand-in|gitignor|retry|backoff|529|roster.*spawn'

Only hits: lines 60/82 — the `minItems`-as-retryable-tool-error COMMENT (pre-existing, not a v2 revision). None of the five revisions are present:
1. roster reconciliation (absent-builder) — the only `reconcil` match is line 877 = final reviewer reconciling LEDGER claim conflicts (pre-existing). ABSENT.
2. verdict retry / survives transient 5xx — no `5xx`/`transient`/`backoff`/`529` in code. ABSENT.
3. no-gitignored-stand-ins builder rule — no `gitignor`/`stand-in`/`installab`. ABSENT.
4. formatter in Elixir/Go builder gates — line 98 gate is `go build && go vet && go test`; no `mix format`/`gofmt`. ABSENT.
5. openapi-regen budgeting in cutter guidance — no `openapi`/`regen`. ABSENT.

## Landing check

    git log origin/main --grep='v2-revisions' --oneline    # empty
    git log origin/main -1 --format='%H %ci %s' -- .claude/workflows/wild-bulk-cycle.workflow.js
    # edec1b976d 2026-08-12  #11605 portability (no_fable/no-xhigh/wall dialect) — NOT the revisions

Last touch to the file is #11605 (portability), unrelated to the v2 revisions.

## R2 runtime nuance (does host agent() auto-retry 529?)

Moot for disposition. Even if the host `agent()` harness auto-retries 529s at runtime (host source not in this repo; not verifiable here), C0 demands the verdict-retry revision be CARRIED IN the workflow file — it is not — and C1 demands a live-run proof that has not occurred. No partial credit closes anything.

## Verdict

Keep OPEN. 0/5 revisions on origin/main, 0/3 criteria met, no merged PR. Offline-buildable (pure `.claude/workflows/` edit — NOT prod/credential/Fable/human-gated), so it IS an open above-floor buildable row: the epic cannot claim "no open offline-buildable row" while this stands. It is a spin/build candidate, not a close-by-evidence candidate. This sets the open count to **3** (with go-dead-exports and the billing leak), not 2.
