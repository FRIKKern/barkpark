# Re-derivation recipe — the closable merge-gated set (wave 13 verify, 2026-08-07)

Verifier V-satisfied-rows-closable-set. No mutations were made. Every row below was
re-derived by the commands in this file, not read off a prior wave's count.

## 0. The count D187 published is an UNDERCOUNT, by wording

D187 says 31 merge-gated one-short rows / 28 satisfied. That census filtered on the
literal string `MERGE-GATED (the LEAD closes this)`. The true set is **38**, because the
same gate is written seven ways across waves 1-12 (`… (the LEAD closes this one)`,
`… (the lead closes this)`, `… (lead closes)`, `PR merged. Closed by the lead.`, …).
A literal-substring census over hand-authored criteria is a bespoke check that
under-reports; re-derive with the wording-agnostic form in §2.

## 1. The corpus

    gh pr list --state merged --limit 300 --json number,title,mergedAt \
      --jq '.[]|"\(.number)\t\(.mergedAt)\t\(.title)"' > /tmp/merged.tsv   # 300 lines
    bp task get task-fb4fb869490b4213 -o json > /tmp/epic.json             # 230 children

## 2. The one-short set, wording-agnostic

Criteria live at `doc.content.acceptance_criteria`. A top-level read returns empty and
reads indistinguishably as "this task has no criteria".

    python3 - <<'PY'
    import json
    d=json.load(open('/tmp/epic.json'))['children']
    one=[c for c in d if c.get('criteria_progress')
         and c['criteria_progress']['total']-c['criteria_progress']['met']==1]
    print(len(one))            # 50 one-short overall
    PY

Then per row `bp task get <id> -o json`, take the single `met:false` criterion, and keep
it if its text matches `MERGE-GATED` **or** `PR merged` / `PR is merged`. → **38**.
The other 12 are genuinely non-merge work (8 `dr-w11-bl-*` disposition rows, 2 `dr-w4-bl-*`,
`dr-terminal-record-prune-tie-order`, `task-3b69c3e24bf3d8ca`) — do NOT bulk-close them.

## 3. Row → its own PR (task-id search, run FROM THE REPO)

    gh pr list --state all --limit 10 --search "\"<doc_id>\"" \
      --json number,state,mergedAt,title

TRAP THAT BIT THIS VERIFIER: run from a non-git cwd (e.g. `/tmp`), `gh pr list --search`
dies with `failed to run git: fatal: not a git repository` on **stderr** and prints an
empty result on stdout. With `2>/dev/null` in the loop, all 38 rows read as
"no PR references this task" — a uniform, comforting, entirely fabricated absence.
Never suppress stderr on a `gh` sweep; a uniform zero is the tell.

## 4. Merged, ancestor of main, four required contexts green

    gh pr view <n> --json number,state,mergedAt,mergeCommit,title
    git merge-base --is-ancestor <mergeCommit.oid> origin/main   # exit 0
    gh pr view <n> --json statusCheckRollup --jq \
      '[.statusCheckRollup[]?|select((.name//"")|test("^(Elixir gate|Cloud gate|Console gate|PR references an active task)$"))
        |"\(.name)=\(.conclusion // .state)"]|sort|join(" ")'

33 distinct merge commits, all ancestors of origin/main, all four contexts SUCCESS.

## 5. The migration-conditional rows, proved on the box (L1)

`dr-w1-s3` / `dr-w11-s1` / `dr-w11-s6` each require their migration APPLIED, not merged:

    ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud \
      "docker exec cloud-db-1 sh -c 'psql -U \$POSTGRES_USER -d \$POSTGRES_DB -Atc \
       \"select version from schema_migrations where version in \
       (20260805190000,20260807130000,20260807140000,20260807150000) order by 1;\"'"

(`-U postgres` FAILS — the role does not exist; read the creds out of the container env.)
All four present; head = `20260807150000`. All three conditions discharged.

## 6. The verdict

- **31 closable outright** (28 plain + the 3 migration rows of §5).
- **3 conditional**: `dr-w3-s5` and `dr-w5-s1` each carry a SECOND clause — an independent
  second review — and `gh pr view 9827|9887 --json reviews` prints NOTHING on both.
  `dr-w11-s7` gates on re-running the census AFTER wave 13 files its tasks: a future condition.
- **4 not closable**: `dr-w10-s1` (#10129 CONFLICTING), `dr-w8-s6` (#10019 CONFLICTING +
  Console gate FAILURE), `dr-w12-s3` (#10245) and `dr-w12-s4` (#10246) — but those last two
  are `MERGEABLE/CLEAN` with all four required contexts SUCCESS **right now**; merging them
  converts two blocked rows into two closable ones for zero engineering.

## 7. Every close needs a RE-CLAIM first

37 of 38 rows carry `claim.worker = null` with an `expired_at` in the past — the lease was
swept. The 38th, `dr-w2-s4-scrub-knows-our-own-token`, carries a stamped claim
(`worker: dr-w6-s3-ledger-repair`, `epoch: 7`) with **no `expired_at`** while
`lifecycle_status` is `open` — a claim stamp with no live lease.

`bp task close` fences on holder + `observed_epoch`. Per `docs/setup/TASK-SYSTEM.md:189`
a stale epoch is a **409 `fenced_off`**, not a silent no-op — but only a caller that reads
the response body learns that. Recipe, per row:

    bp task claim <doc_id> <worker>        # open → in_progress, epoch bumps, digest re-stamped
    bp task close <doc_id> <worker> <NEW-epoch> \
      --set 'criteria:=[…merge criterion met:true, evidence = the merge commit sha…]'

Do NOT reuse the epoch printed by `bp task get`, and do NOT reuse the epoch from the epic
children listing: `dr-w12-s6` and `dr-w12-s7` read `in_progress` in the children listing and
`open` in their own documents fetched ~90 seconds later. Leases were expiring live during
this verification.
