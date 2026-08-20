# W28 · Reclaim roster — mechanical vs live-proof split (re-derivation recipes)

As-of 2026-08-09, origin/main = a95bc7ca9. Every command below is the literal
command that re-derives the fact; none of them mutate anything.

## 0. The MUST-RUN git scan is TRUNCATED in this checkout

    git rev-list --count origin/main            # -> 221
    git rev-list --count main                   # -> 4868
    ls .git/shallow                             # -> exists (SHALLOW)
    git log origin/main --pretty='%ad' --date=short | sort -u   # -> 08-07 08-08 08-09 only
    git merge-base main origin/main             # -> EMPTY (no common ancestor known)

`git log origin/main --since=2026-07-20` cannot reach before 2026-08-07 here.
Any payer scan must use the UNION:

    git log main origin/main --pretty=format:'@@@%h|%ad|%s%n%b' --date=short > /tmp/w28unionfull.txt
    grep -c '^@@@' /tmp/w28unionfull.txt        # -> 5089

## 1. Roster shape

    bp task get task-fb4fb869490b4213 -o json > /tmp/w28roster.json
    python3 -c "import json;d=json.load(open('/tmp/w28roster.json'));ch=d['children'];print(len(ch), sum(1 for c in ch if c['lifecycle_status']=='open'))"
    # -> 202 122

Three of the 202 are `drafts.` twins of published rows (double-count):

    python3 -c "import json,collections;d=json.load(open('/tmp/w28roster.json'));t=collections.Counter(c['title'] for c in d['children']);print([k for k,v in t.items() if v>1])"

## 2. Per-row unmet criteria

    bp task get <slug> -o json | python3 -c "import sys,json;d=json.load(sys.stdin)['doc']['content'];[print(a['criterion']) for a in d['acceptance_criteria'] if not a.get('met')]"

## 3. Payer proof (two independent legs; both required)

Leg A — the slug is named in a non-ledger commit reachable from origin/main:

    git log main origin/main --grep '<slug>' --pretty='%h %ad %s' --date=short
    git merge-base --is-ancestor <sha> origin/main && echo ON-MAIN

Leg B — the row's own PR merged:

    gh pr list --search '<slug>' --state all --json number,state,mergeCommit --limit 3

Leg B alone over-reports: dr-w25-s4's own PR #11009 is CLOSED-not-merged, yet
its content landed via the re-land #11075 = f7a87c0a5:

    git log -1 --format=%B f7a87c0a5 | grep -o 'dr-w25-s4[a-z-]*'

Leg A alone over-reports: dr-terminal-record-prune-tie-order's ONLY naming
commit is a docs manifest, not a payer:

    git show --stat --format='%h %s' ebfab89e3 | head -4
    # -> docs(ledger): dr-w19-s6 close manifest ... 1 file changed

## 4. Criteria whose own verification command can never pass

    git show origin/main:internal/cloudclient/deliveries.go | grep -c 'Carried \*bool'   # -> 0
    git show origin/main:internal/cloudclient/deliveries.go | grep -n 'Carried'          # -> 121: Carried<multi-space>*bool
    git grep -l 'runner_queue_len\|build_slots' origin/main -- api/ cloud/ internal/ web/ js/   # -> 4 files
    git grep -l publish_clock origin/main                                                # -> 10 files (charter + 2 tests + 7 ledgers)
