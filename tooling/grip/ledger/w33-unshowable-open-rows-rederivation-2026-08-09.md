# W33 verify — unshowable open rows: re-derivation recipe

as_of 2026-08-09, origin/main = `4ca033f502f407a6e33624759f576b725f4277df`, installed `bp` = /Users/pelle/.local/bin/bp

## 0. Materialise the population (163 rows: 160 open + 3 in_progress)

```
mkdir -p /tmp/rows
bp task get task-fb4fb869490b4213 -o json > /tmp/rows/_goal.json
python3 -c "
import json
d=json.load(open('/tmp/rows/_goal.json'))
ids=[c['doc_id'] for c in d['children'] if c['lifecycle_status'] in ('open','in_progress')]
open('/tmp/rows/_ids.txt','w').write('\n'.join(ids))"
while read -r id; do bp task get \"\$id\" -o json > /tmp/rows/\$id.json; sleep 0.4; done < /tmp/rows/_ids.txt
```

NOTE: `xargs -P 8` over `bp task get` triggers HTTP 429 on /v1/capabilities and writes
EMPTY .json files that `json.load` rejects — a parallel fetch here silently truncates the
population. Fetch serially, or validate every file parses before counting.

Criteria live at `doc.content.acceptance_criteria` (a list of {criterion, evidence, met}).
`doc.acceptance_criteria` is ALWAYS null — reading that key reports 163 zero-criteria rows.

## 1. The headline numbers

| measure | value |
|---|---|
| children of the goal | 300 (done 125 / open 160 / cancelled 12 / in_progress 3) |
| rows with ZERO acceptance criteria | **6** (not 79) |
| rows with all criteria met but still open | 2 |
| `drafts.*` twin rows inside the open set | **7** |
| unmet criteria across all 163 rows | **447** |
| unmet criteria carrying a backticked shell command | 41 |

## 2. The six proven-broken criterion commands (run against origin/main)

```
git show origin/main:internal/cloudclient/deliveries.go | grep -c 'Carried \*bool'   # -> 0  (dr-w26-s3 #9 demands 1)
git show origin/main:internal/cloudclient/deliveries.go | grep -cE 'Carried +\*bool' # -> 1  (the field IS there, col-padded)
git grep -c publish_clock origin/main                                                 # -> 13 files (dr-w26-s6 #11; the charter alone holds 17 lines)
git grep -c 'runner_queue_len\|build_slots' origin/main -- api/ cloud/ internal/ web/ js/  # -> 4 files, ALL prose (dr-w26-s7 #10)
grep -n '|| true' .github/workflows/deploy.yml   # -> 3 hits (dr-w24-s7 #3, dr-w25-s8 #7 both demand zero)
grep -n 'grep -qE'  .github/workflows/deploy.yml # -> 3 hits (dr-w25-s8 #8 demands zero)
```

deploy.yml:413 is a COMMENT that reads "There is NO `|| true` … anywhere in this job" — so the
criterion's own literal command is defeated by the prose written to satisfy it.

## 3. Runnable criterion commands that PASS today and are still stamped unmet

```
bash scripts/stale-verdict-watch.test.sh                                   # 87 passed, 0 failed   (dr-w29-bl #3)
bash scripts/cloud-path-escape-check.sh --check                            # OK                    (dr-w24-s7 #7)
printf '.github/workflows/deploy.yml\n' | bash scripts/cloud-path-escape-check.sh --match cloud   # true
cd <origin/main archive> && CGO_ENABLED=0 go build ./... && CGO_ENABLED=0 go vet ./internal/cli/... \
  && CGO_ENABLED=0 go test ./internal/cli/ -run 'Deliver'                  # ok 0.585s             (dr-w24-s8 #7)
git grep -l publish_clock origin/main -- cloud/lib internal api/lib cloud/priv   # empty, rc 1      (dr-w27-bl #2)
git rev-parse --is-shallow-repository                                      # false                 (dr-w30-bl #2)
```

## 4. Reader commands that do NOT exist on the operator's machine

```
bp cloud deployments   # {"error":{"code":"usage","message":"unknown cloud command \"deployments\""}}
bp cloud deliveries    # {"error":{"code":"usage","message":"unknown cloud command \"deliveries\""}}
bp cloud deploy census # host-resolution error, NOT the 'unknown verb' the criterion demands
git grep -n '"deliveries"\|"deployments"' origin/main -- internal/cli/   # both verbs DO exist on main
```
The installed bp is stale, not the code. Six criteria across four rows cite these verbs.

## 5. The 7 draft twins

```
python3 -c "print([i for i in open('/tmp/rows/_ids.txt').read().split() if i.startswith('drafts.')])"
```
All seven carry `status=draft`, `lifecycle_status=open`, `inserted_at 2026-08-09`.
Six have a `done`/`published` twin at the un-prefixed slug (verified for
dr-w26-s5, dr-w28-s2, dr-w28-s5, dr-w30-s6, dr-w31-s1, dr-w31-s2).
`dr-w26-hg-gyldendal-operator-packet-corrected` resolves to itself, still draft — the
genuine 409-dedup-wall blocker, not duplication.

## 6. The crown reconciler's five description checks (all PASS, run 31333565555)

```
gh run view 31333565555 --log | awk -F'\t' '$2!~/test.sh/' | grep -E 'RE-ASK LIST|RECONCILED|written back'
```
The write-back notice's `wc -l` is always reconciler-entries **+1** (a header line): "wrote 0
entry(ies)" pairs with "(1 line(s))" and "wrote 1" with "(2 line(s))" across runs 31332716688,
31332806984, 31333052697, 31333565555. Benign, but that notice can never print 0 lines.
