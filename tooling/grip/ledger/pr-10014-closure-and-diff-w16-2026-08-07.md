# Re-derivation recipes — PR #10014: does its branch survive, what did its emitter do, and why was it closed?

Wave 16 verifier `v9-10014-diff-and-closure`. Taken 2026-08-07 against `origin/main` and GitHub.

## 1. The head branch still resolves on origin

    git ls-remote origin 'loop-epic/the-deploy-ledger-names-the-cause-it-alr-0'
    # => 92f96f7ba2ffe31d562da4fe6f88b85d4e504dbc  refs/heads/loop-epic/...-0

Fetch it without touching a working tree:

    git fetch origin 'refs/heads/loop-epic/the-deploy-ledger-names-the-cause-it-alr-0:refs/remotes/origin/pr10014head'
    git rev-list --left-right --count origin/main...origin/pr10014head   # => 61  2  (branch is 61 behind)
    git diff --stat $(git merge-base origin/main origin/pr10014head) origin/pr10014head
    # => deploy_ledger.ex 137 | deploy_ledger_test.exs 271 | deploy/site-deploy-node.sh 11

Textual mergeability into TODAY's main (no worktree, no checkout):

    git merge-tree --write-tree origin/main origin/pr10014head ; echo RC=$?
    # => prints ONE tree oid and RC=0  ==> zero conflicts

## 2. Nothing of the emitter is on main

    git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex | grep -n 'def rate\|terminal_failure_rate\|basis'
    # => only `def rate(numerator, denominator)` x2 (682, 693). No basis, no live, no terminal rate.
    git grep -c CONTENT_API origin/main -- cloud/ ; echo RC=$?   # => RC=1 (absent)

The READER half IS on main (asymmetry):

    git grep -n 'TerminalFailureRate\|Live \*int' origin/main -- internal/cloudclient/client.go

The three phantom allowlist rows naming #10014 by number:

    git show origin/main:cloud/test/barkpark_cloud/payload_key_set_census_test.exs | sed -n '548,555p'

## 3. Closure was a merge sweep, not a ruling

    gh pr view 10014 --json state,mergedAt,closedAt,comments
    # => CLOSED, mergedAt null, closedAt 2026-08-07T12:21:18Z, comments: []
    gh api repos/FRIKKern/barkpark/issues/10014/timeline --paginate \
      --jq '.[] | select(.event=="closed") | {actor:.actor.login, created_at}'
    # => FRIKKern, 2026-08-07T12:21:18Z

Same-minute merge sweep (its own unblocker among them):

    gh pr list --state all --search 'closed:2026-08-07T12:15:00Z..2026-08-07T12:30:00Z' \
      --json number,mergedAt,closedAt,title
    # => #10268 12:21:10, #10299 12:21:17 (the CLOUD_PATHS unblock), #10300 :23, #10301 :30, #10302 :36 — all MERGED

Charter law at the time of closure (and still, on origin/main):

    git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | sed -n '3814,3824p'
    # D198 — "#10014 IS NOT SUPERSEDED ... Closing #10014 as superseded costs 162 failures a day their cause."
    git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | grep -n '10014' | tail -1
    # => 4065, a STATUS line ("#10014 is CLOSED"), not a ruling. No D-number orders the closure.

Its task is still open, 8/10 criteria met:

    bp task get dr-w8-s1-ledger-names-cause-and-denominator -o json   # lifecycle_status: open

## 4. The trap in reusing the diff verbatim

`#10014` implements `def rate(numerator, denominator, basis \\ @basis_attempted)` — a DEFAULT ARG.
Charter D199 (same file, ~line 3833) rules that shape a TRIPLE red for the payload key-set census:
"thread `basis` as a real argument or use two named wrappers". And its classifier half is superseded
in DESIGN by open PR #10400 (`CONTENT_API_403` as its own `:ambiguous` class vs #10014 folding 403
into `FORBIDDEN_403`):

    gh pr diff 10400 --patch | grep -E '^\+.*CONTENT_API_403'
