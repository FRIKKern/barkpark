# cch-w59 — Standing Law 0 re-derivation recipes + draft discard safety (2026-08-09)

Verifier assignment `v9-law0-closes`, Cloud Console hardening wave 59. Every number below has its
producer. Do not retype a figure without re-running its recipe (D677).

## R1 — Standing Law 0, BOTH routes

    cd /Volumes/SATECHI/github/barkpark
    bp task get cloud-console-hardening-epic -o json > /tmp/e.json
    bp task ls --all -o json > /tmp/a.json

Route A (epic read):  `jq '.child_count' /tmp/e.json`
                      `jq '[.children[].lifecycle_status]|group_by(.)|map({(.[0]):length})|add' /tmp/e.json`
Route B (roster read):`jq '[.docs[]|select(.parent_id=="cloud-console-hardening-epic")]|length' /tmp/a.json`
                      `jq '[.docs[]|select(.parent_id=="cloud-console-hardening-epic")|.lifecycle_status]|group_by(.)|map({(.[0]):length})|add' /tmp/a.json`
Symmetric difference: `jq -r '.children[].doc_id' /tmp/e.json | sort > /tmp/A;
                       jq -r '.docs[]|select(.parent_id=="cloud-console-hardening-epic")|.doc_id' /tmp/a.json | sort > /tmp/B;
                       comm -3 /tmp/A /tmp/B | wc -l`

Measured 2026-08-09: **811 / 811, {open 409, done 341, cancelled 60, considering 1}, symdiff 0.**

## R2 — the 410 vs 401 split (D105)

    jq '[.docs[]|select(.parent_id=="cloud-console-hardening-epic" and (.doc_id|startswith("drafts.")|not))|.lifecycle_status]|group_by(.)|map({(.[0]):length})|add' /tmp/a.json

Published children **788** {open 400, done 341, cancelled 46, considering 1} → seal-predicate LIVE = **401**.
The 9-row gap to 410 is `drafts.*` open entries, which D105 says are duplicates, never rows.

## R3 — draft discard safety (supersedes a `rev` comparison, which is impossible)

`rev` is a content HASH, not a monotonic integer, so "twin is revision-ahead" is not derivable from it.
The decidable test is content containment + `updated_at`:

    python3 - <<'EOF'
    import json
    a=json.load(open('/tmp/a.json')); byid={r['doc_id']:r for r in a['docs']}
    for r in a['docs']:
        if not r['doc_id'].startswith('drafts.'): continue
        if r['lifecycle_status']!='open': continue
        base=r['doc_id'][7:]; p=byid.get(base)
        d=r['content']
        if not p: print("ORPHAN(no published twin):",r['doc_id']); continue
        dac=d.get('acceptance_criteria') or []; pac=(p['content'] or {}).get('acceptance_criteria') or []
        pc=[c.get('criterion') for c in pac]; pe=[c.get('evidence') for c in pac]
        only=[c for c in dac if c.get('criterion') not in pc]
        onlyev=[c.get('evidence') for c in dac if c.get('evidence') and c.get('evidence') not in pe]
        print(r['doc_id'], "uniqueCriteria=",len(only), "uniqueEvidence=",len(onlyev),
              "metD/metP=",sum(1 for c in dac if c.get('met')),"/",sum(1 for c in pac if c.get('met')),
              "pubStatus=",p['lifecycle_status'])
    EOF

Measured 2026-08-09: **6 shadow drafts, all with a published twin, all uniqueCriteria=0 uniqueEvidence=0,
published met-count >= draft met-count in all six.** Discard is content-safe.
**3 `zz-p-*` probes are ORPHANS** — no published twin anywhere in the 6255-doc roster; two carry
~4.9KB of unique prose. D124 applies to those three and NOT to the six.

## R4 — a merged PR whose branch SHA reads unmerged (Standing Law 1)

    git merge-base --is-ancestor 301452f20 origin/main; echo $?      # 1 = NOT ancestor (branch SHA)
    gh pr list --state all --limit 300 --json number,state,headRefName,mergedAt \
      --jq '.[]|select(.headRefName|test("reveal-env-var"))|[.number,.state,.mergedAt]|@tsv'
    gh pr view 11017 --json mergeCommit --jq .mergeCommit.oid
    git merge-base --is-ancestor 0239dd4ee662dd30c4d8da0c6b9a149638224b1d origin/main; echo $?  # 0

`gh pr list --state open` CANNOT see it: PR #11017 merged 2026-08-08T23:48:13Z. Filtering by `--state open`
is what produced the "no open PR carries it" non-finding.

## R5 — the arrears sweep is evidence-backed

    jq -r '.docs[]|select(.parent_id=="cloud-console-hardening-epic" and (.claim.closed_at//"")|startswith("2026-08-09"))|.doc_id' /tmp/a.json | wc -l

19 rows closed 2026-08-09 (18 done + 1 draft cancelled). Extract 9-40 hex tokens from each row's
`acceptance_criteria` + `close_reason`, then per token `git cat-file -e <s>^{commit} && git merge-base
--is-ancestor <s> origin/main`. Measured: **18/18 non-draft rows carry >=1 merged evidence SHA that is
NOT the main-head anchor 989b19577; 0 rows are anchor-only.**

## Trap recorded

`while read -r a b; do IFS=, read -ra arr <<< "$b"; done` prints a plausible all-`NONE` column under zsh
because `read -a` is a bash-ism (`(eval):read:4: bad option: -a`) and the loop body keeps going.
Every row read "NONE-ANCESTOR" until the same logic was re-run in Python, where 18/19 hit.
Do splitting in Python, not in an interactive-shell `read`.
