<!-- doc-tier: cold | canonical-for: (none — ledger recipe row) | budget: 600tok -->
# ACRC Wave 1 — charter-merge-premise re-derivation (2026-08-18)

Verifier lane [charter-merge-premise] for wave `api-content-render-correctness-wave-2026-08-18`.
Every claim below re-derives from these exact commands.

## The gate's read endpoint (what actually decides)
pr-task-gate reads `${LEDGER_BASE}/v1/data/doc/production/task/<slug>`, Bearer added
ONLY when `BARKPARK_TASK_TOKEN` is set (unprovisioned today). A token-absent 404 = exit 2
"outage", which is a REQUIRED-context RED.

    git show origin/main:scripts/pr-task-gate.sh | sed -n '205,246p'   # url + 404 handling

## Trailer target of #12390 is a DRAFT → 404 unauthenticated
    B=https://guerrilla.barkpark.cloud/v1/data/doc/production/task
    curl -s -o /dev/null -w '%{http_code}\n' "$B/api-content-render-correctness-audit-wave-1-log"  # 404 (draft, doc_id drafts.*)
    curl -s -o /dev/null -w '%{http_code}\n' "$B/acrc-w1-render-children-nil-guard"                # 200 (published build task)
    bp task get api-content-render-correctness-audit-wave-1-log | python3 -c "import sys,json;d=json.load(sys.stdin)['doc'];print(d['status'],d['doc_id'],d['labels'],(d.get('claim') or {}).get('worker'))"
    # -> draft  drafts.api-content-render-correctness-audit-wave-1-log  []  None

## The four epic children (published vs draft)
    bp task get api-content-render-correctness-audit | python3 -c "import sys,json;[print(c['doc_id']) for c in json.load(sys.stdin)['children']]"
    # acrc-w1-render-children-nil-guard            (published)  <- crown BUILD
    # acrc-dedup-toctou-serialize                  (published)  FILE
    # acrc-publish-atomicity-txn-boundary          (published)  FILE
    # drafts.api-content-render-correctness-audit-wave-1-log  (DRAFT)  <- #12390 trailer

## #12390 is CONFLICTING (not rebased)
    gh pr view 12390 --json mergeStateStatus,mergeable,files
    # DIRTY / CONFLICTING; sole file .claude/workflows/bp-cloud-epic-charter.md (charter collision)

## Unblock recipes
- #12390 (docs charter): PUBLISH the wave-log task (or repoint trailer to a published+live-claimed
  task), OR provision BARKPARK_TASK_TOKEN, OR admin break-glass; THEN rebase onto origin/main.
- crown-fix PR: set `Task: acrc-w1-render-children-nil-guard` (reads 200) AND re-claim that task
  in_progress with a LIVE worker before opening — its claim is currently lapsed (epoch 3, worker null),
  which would red as "no active claim" (a DIFFERENT red than #12390's 404-outage).
