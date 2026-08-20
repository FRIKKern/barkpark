# Re-derivation recipe — wave-38 RECORD-PARITY, both axes, canonical extractor

Derived 2026-08-02 (UTC ~00:00) against `origin/main` **f85188bdf17819dddb886b45447d65b33a9d04aa**
and the live ledger `https://guerrilla.barkpark.cloud`. Every integer below is a MEASUREMENT AT A
SHA AND A CLOCK, not a standing invariant — the merged-PR window slides ~65 PRs/day.

## 0. The briefed MUST-RUN command does not parse

`gh`'s embedded gojq rejects the one-liner in the wave-38 verifier brief:

    gh pr list --state merged --limit 400 --json number,body,mergedAt \
      --jq '.[] | "\(.number)\t\(.mergedAt)\t\((.body//"") | capture("(?im)^\\s*Task:\\s*(?<t>[^ \n]+)").t // "-")'
    # → failed to parse jq expression (line 1, column 103) ... unexpected EOF

The `\n` escape inside a nested string inside a string-interpolation is the break. Fetch to a file
and use system `jq` (1.7.1) instead:

    gh pr list --state merged --limit 400 --json number,body,mergedAt,mergeCommit,title > merged400.json

## 1. Reach of `--limit 400`

    jq -r 'sort_by(.mergedAt)|"\(.[0].number) \(.[0].mergedAt) .. \(.[-1].number) \(.[-1].mergedAt)"' merged400.json
    # 6288 2026-07-26T20:42:26Z .. 8994 2026-08-01T23:05:23Z   → 146.4h ≈ 6.1 days

    gh api graphql -f query='{repository(owner:"<owner>",name:"<name>"){pullRequests(states:MERGED){totalCount}}}' \
      --jq '.data.repository.pullRequests.totalCount'   # 3083

400 of 3083 = 13% of merged history. The window is COUNT-bounded, not TIME-bounded.

## 2. Canonical extractor vs the ad-hoc jq capture

Feed each body to the shipped extractor (`PR_BODY` env, `scripts/pr-task-gate.sh --extract-task-id`).
Over the same 400 PRs:

| lens | PRs carrying a task ref | distinct ids | disagreements |
|---|---|---|---|
| canonical `--extract-task-id` | 389 | 297 | — |
| ad-hoc `capture("(?im)^\\s*Task:\\s*(?<t>[^ \n]+)")` | 389 | 298 | 7 |

All 7 disagreements are backtick-wrapped ids the ad-hoc lens keeps and the canonical lens strips
(#6305, #6332, #6497, #7747, #8458, #8459, #8989). Consequence is real, not cosmetic:

    curl -o /dev/null -w '%{http_code}\n' '.../task/%60task-e4836038babf7cc0%60'  # 404
    curl -o /dev/null -w '%{http_code}\n' '.../task/task-e4836038babf7cc0'        # 200

i.e. the ad-hoc lens manufactures 7 false NOT_FOUND findings.

## 3. Axis B — merged PR whose ledger row is not closed

297 distinct canonical ids, serial reads with bounded retry:

    HTTP: {200: 296, 404: 1}
    STATUS: {done: 215, open: 81, NOT_FOUND: 1}, in_progress: 0
    DIVERGENT = 82   (81 open + 1 not-found)
      · 13 have parent_id NULL (epic/goal roots, 10 of them multi-PR)
      · 69 are leaf slices
      · 10 carry main_tag=pds
    tasks with >1 merged PR: 27 (16 done, 11 open)
    the single NOT_FOUND: PR #6371 body says literally `Task: n/a (probe)`

A first pass with 8 concurrent readers and NO retry returned 75/297 non-decisive; the same 8-way
read over a 120-id subset later returned 120/120 200. Treat non-200 as transient, retry, then
UNCHECKED — never as a finding.

## 4. Axis A — PDS-D citations resolve in origin/main's charter

    git show origin/main:.claude/workflows/bp-pds-charter.md   # 10133 lines / 901810 bytes
    # NOTE: the primary checkout's working copy is 5035 lines / 435549 bytes — HALF. Never quote it.

    commits reachable from origin/main citing PDS-Dnnn: 124, distinct D cited: 187, max 525
    charter D numbers, "mentioned anywhere":                 537 (max 537)
    charter D numbers, "^[-*]? **PDS-Dnnn" (real entry form): 537 (max 537)
    charter D numbers, "markdown heading":                      9

    UNRESOLVED — loose:      0
    UNRESOLVED — bold-lead:  0
    UNRESOLVED — heading:  183

The charter's entry form is `- **PDS-Dnnn — …**` (541 sites). No D is ever a markdown heading, so a
literal heading test reds on 183 of 187 citations and measures the lens, not the record.

## 5. #8971

    gh pr view 8971 --json state,mergedAt   # MERGED 2026-08-01T23:54:01Z

Axis A's 4 unresolved citations self-healed on that merge, exactly as the digest predicted. Any
wave-38 arm pinned to axis A ships already-green.
