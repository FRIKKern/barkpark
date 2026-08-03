# cch-w27 — D307 detector reachability: re-derivation recipes

Measured 2026-08-02 against `origin/main` `c2affd4458f491694f38773843df43b4f66507e0`
(the commit that added the charter's `### 2026-08-02 — wave 26 DECIDE` heading).
Every row below is a command, not a claim. Ledger reads are ANONYMOUS — no `BP_TOKEN`.

## R1 — Anonymous ledger read is reachable with NO credential

    curl -sG -o /dev/null -w 'anon_query=%{http_code}\n' \
      'https://guerrilla.barkpark.cloud/v1/data/query/production/task' \
      --data-urlencode 'filter[parent_id]=cloud-console-hardening-epic' \
      --data-urlencode 'limit=3'

Reads `anon_query=200`; the body carries `result.count`, `result.documents[]` with
`_createdAt`, `parent_id`, `lifecycle_status`, `files`, `surface`, `wave_paper`.

## R2 — GitHub-runner egress to guerrilla is ESTABLISHED prior art (not console-harness)

    git show origin/main:.github/workflows/pr-task-gate.yml | grep -nE 'LEDGER_BASE|curl'
    gh run list --workflow=pr-task-gate.yml --limit 3 --json conclusion,createdAt,headBranch

`pr-task-gate.yml:179` sets `LEDGER_BASE: … || 'https://guerrilla.barkpark.cloud'` and
curls it; runs are green. `console-harness.yml` makes ZERO network calls and
`seal-predicate.mjs:757` states "This program makes no network call BY DESIGN."

## R3 — The committed wave marker is a charter heading; its granularity is a DAY

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md \
      | grep -nE '^### .*wave [0-9]+ DECIDE'
    git log -1 --format='%aI %H' origin/main -S'wave 26 DECIDE' \
      -- .claude/workflows/bp-cloud-console-hardening-charter.md

20 headings, one regex. Waves 21-26 all carry `2026-08-02` — the DATE cannot separate
same-day waves. The wave-26 heading first appears at `2026-08-02T20:37:49+02:00`
(= 18:37:49Z) — AFTER its four `-bl-` rows were created (17:23-17:32Z), so the heading's
commit time is NOT a window start.

## R4 — Ledger wave files are day-stamped too (same defect)

    git ls-tree -r --name-only origin/main tooling/grip/ledger/ | grep -E 'cch-w2[4-6]'
    for f in <those>; do git log --diff-filter=A --format='%aI %H' origin/main -- "$f" | tail -1; done

w24/w25/w26 all `-2026-08-02.md`; first-commit times 15:34:49 / 18:09:41 / 20:37:49 (+02:00).

## R5 — The classifier fields are absent on exactly the rows D307 targets

    python3 - <<'PY'
    import json,urllib.request,urllib.parse
    b='https://guerrilla.barkpark.cloud/v1/data/query/production/task'
    d=[];o=0
    while True:
        r=json.load(urllib.request.urlopen(b+'?'+urllib.parse.urlencode(
            {'filter[parent_id]':'cloud-console-hardening-epic','limit':100,'offset':o})))['result']
        d+=r['documents']
        if len(r['documents'])<100: break
        o+=100
    bl=[x for x in d if '-bl-' in x['_id']]
    for f in ('surface','files','wave_paper'):
        print(f, 'bl', sum(1 for x in bl if x.get(f)), '/', len(bl),
                 '| all', sum(1 for x in d if x.get(f)), '/', len(d))
    PY

Reads (343 children): `surface` bl 5/152, all 24/343 — and free PROSE, no enum.
`files` bl 41/152, all 132/343. `wave_paper` bl 85/152, all 234/343.
On the six wave-26-window creates: all 6 slices carry files+surface+wave_paper;
all 4 `-bl-` rows carry NONE of the three.

## R6 — The create door is `Content.apply_mutations`, which is IN FENCE

    bp capabilities -o json | python3 -c "import sys,json;d=json.load(sys.stdin);print([i[1] for i in d['commands'] if i[0]=='task'])"

Reads `['ls','ready','prime','events','get','claim','close','release','stamp','next','move','stage','pulse']`
— there is NO `task create` verb; creates go `doc create`/`doc mutate` →
`POST /v1/data/mutate/:dataset` → `Content.apply_mutations`.
`api/lib/barkpark/content/mutations.ex` + its tests are an explicit standing
dispensation in the charter's Surface fence, and the file ALREADY hosts create-time
door guards (see its "FRESH-CREATE exemption" comment block at :470-545).
