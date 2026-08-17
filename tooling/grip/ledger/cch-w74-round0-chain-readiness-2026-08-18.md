<!-- doc-tier: cold | canonical-for: cch-w74-round0-chain-readiness | budget: 900tok -->

# cch-w74 Round-0 chain readiness — re-derivation recipes

Verifier [round0-chain-readiness], 2026-08-18. Every fact below re-derivable by the one command.

## Required-check set on main (only these 4 block; strict:false)

    gh api repos/FRIKKern/barkpark/branches/main/protection/required_status_checks --jq '.strict, .contexts[]'
    # => False ; Elixir gate ; PR references an active task ; Cloud gate ; Console gate

## The three PRs — REQUIRED gates all green, head pinned

    for n in 12067 12068 12069; do gh pr view $n --json state,mergeable,headRefOid,statusCheckRollup; done
    # 12067 head 7ef99310c9623e313d2456f67a95525ed316a684 mergeable=MERGEABLE
    #        Elixir gate/Cloud gate/Console gate/"PR references an active task" all SUCCESS
    # 12068 head d7183176a4 mergeable=MERGEABLE — 4 required all SUCCESS
    # 12069 head 5c404e2453 mergeable=MERGEABLE — 4 required all SUCCESS

12067 tip is the STATUS-READ correction, nothing after it:

    gh pr view 12067 --json commits --jq '.commits[-1].oid[:10] + " " + .commits[-1].messageHeadline'
    # => 7ef99310c9 review(cch-w73): correct two census rows to STATUS-READ truth

## Two ADVISORY reds, identical on all three PRs (NOT required contexts → do not block)

    # "Doc budgets + anchors" (doc-gates) FAILURE — cause is repo-wide ledger hygiene, NOT the chain:
    gh run view 32074209915 --log-failed | grep "canonical-for 'none'"
    # FAIL: canonical-for 'none' has more than one owner: ./tooling/grip/ledger/felix-w26-ssrf-toctou-verdict-2026-08-17.md ./tooling/grip/ledger/cch-w35-telegram-webhook-dead-union-2026-08-17.md ./tooling/grip/ledger/cch-w35-connectors-public-route-rederive-2026-08-17.md
    # "Required-check spec gate" (required-checks-drift) FAILURE — exits 1 after the doc-gates.yml
    #   "21 (blocking)" count assertion; also advisory, identical on all three.

## 12069 = wave-73 review-log entry ONLY (no charter-body / D-law conflict)

    gh pr diff 12069 --name-only        # => .claude/workflows/bp-cloud-console-hardening-charter.md (only file)
    gh pr diff 12069 | grep '^+' | head # pure insertion at line 3755: "### 2026-08-18 — wave 73 REVIEW"
    # D873-D877 already on origin/main charter; this PR adds no new D-law, no conflict (MERGEABLE).

## Ledger closes the lead owes / already settled

    bp task get <slug> -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["doc"]["content"]["lifecycle_status"])'
    # cch-w70-bl-site-create-collapses-refusal-exit-families = open  <- STALE-OPEN, #11886 MERGED (crit3 met=False)
    gh pr view 11886 --json state,mergedAt,headRefName
    #   MERGED 2026-08-17T16:03:45Z, branch loop-epic/bp-cloud-site-create-exits-by-refusal-fa-1 (== task claim.now)
    # cch-w70-bl-cli-drops-the-readable-types-menu-on-create = done  <- ALREADY closed (#11901); D877 duty settled
    # cch-w72-bl-add-support-reachability-unpinned            = open  <- closes-by-classification on #12067 merge
    # cch-w64-bl-124-...                                      = in_progress, crit5 (PR merged w/ Cloud gate) met=False -> #12067 open
    # cch-w72-bl-no-fallback-friendly-sites-remainder         = in_progress, crit5 (PR merged w/ Console gate) met=False -> #12068 open
