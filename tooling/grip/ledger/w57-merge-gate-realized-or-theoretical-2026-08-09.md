# Wave 57 verify — is the merge-gated honour system exercised, or only exposed?

Re-derivation recipes. Every number below is reproducible from these commands alone.
Baseline: roster fetched 2026-08-09; repo at `/Volumes/SATECHI/github/barkpark`, `origin/main`.

## R1 — the roster snapshot everything else reads

    cd /Volumes/SATECHI/github/barkpark && bp task ls --all -o json > /tmp/w57roster.json
    python3 -c "import json;print(len(json.load(open('/tmp/w57roster.json'))['docs']))"   # 6186

TRAP that broke the first scan: `parent_id` holds the **doc_id slug**
(`"cloud-console-hardening-epic"`), NOT the UUID in `id`. Walking by `id` returns a
family of 2 (the two roots) and a silent zero — the exact "broken query" the
assignment warned about. Walk by `doc_id`.

## R2 — the family and the marker census

    python3 /tmp/w57_mergegate_scan.py

Family walk from `cloud-console-hardening-epic` + `cch-instruments-epic` by doc_id:

| quantity | value |
|---|---|
| family total (incl. roots) | 994 |
| live (open+considering) | 590 |
| non-live (done 338 / cancelled 66) | 404 |
| acceptance criteria carrying the MERGE-GATED marker | **453** (sanity total — the query is not broken) |
| of those, `met:true` | **215** |
| of those 215, on a LIVE row | **0** |
| live + unmet marked criteria | 202 (191 canonical-leading, 11 mere prose mention) |
| criteria carrying the STRUCTURAL `merge_gate:true` field, family-wide | **0** |

## R3 — the server autostamp never fired, anywhere

    python3 - <<'EOF'
    import json
    d=json.load(open('/tmp/w57roster.json'))['docs']
    n=0
    for t in d:
      for ac in ((t.get('content') or {}).get('acceptance_criteria') or []):
        if isinstance(ac,dict) and ac.get('merge_gate') is True and ac.get('met'):
          n+=1; print(t['doc_id'],'auto=', 'auto: lead-closed on merge' in (ac.get('evidence') or ''))
    print(n)
    EOF
    python3 -c "print(open('/tmp/w57roster.json').read().count('auto: lead-closed on merge'))"   # 1

16 structural merge-gate criteria are `met:true` ledger-wide (all on pds/felix/cd rows,
none in this epic). ZERO carry `compose_merge_gate_evidence/4`'s signature string
(`api/lib/barkpark/tasks/close.ex:741`). The single occurrence of that phrase in the
whole 55 MB roster is the *prose* of the task that BUILT the seam
(`task-felix-close-merge-gate-autostamp`). The seam has never produced a stamp.

## R4 — the flag the ledger prescribes does not exist

    bp task close cch-w55-s2-archive-does-not-stop-paying nobody 11 --merge-gated --dry-run; echo $?
    # bp: unknown flag --merge-gated for task close
    # 2

    bp task close cch-w55-s2-archive-does-not-stop-paying nobody 11 --dry-run
    # dry-run: client-side preview only … {"observed_epoch":"11","worker_id":"nobody"}

Four wave-55 rows carry a `claim.now.text` ending "LEAD CLOSES: re-claim, then close
with `--merge-gated`":

    python3 -c "
    import json;d=json.load(open('/tmp/w57roster.json'))['docs']
    for t in d:
      n=((t.get('claim') or {}).get('now') or {}).get('text','')
      if '--merge-gated' in n: print(t['doc_id'])"
    # cch-w55-s2 / s3 / s4 / s5

## R5 — the tripwire lives only in `stamp`; `close --set criteria` walks past it

    grep -rn "isMergeGatedText\|stampMergeGateBlocked" internal/ | grep -v _test
    # only internal/cli/tasks_stamp_cmd.go:44,114,119,120,123,126

`internal/cli/cli.go:597-608` dispatches the wrapper for `noun=="task" && verb=="stamp"`
only. `bp task close … --set 'criteria:=[…]'` flips the same met bit in one atomic
write with no marker check at all.

## R6 — the over-firing tripwire is realized, not theoretical

11 LIVE criteria in this epic carry the phrase in prose without being merge gates —
including `cch-w56-bl-merge-gated-override-has-no-authority-check-and-no-record`'s own
criterion "The over-firing tripwire is narrowed so a criterion that merely MENTIONS
merge-gating is not blocked." Stamping that row met requires passing `--merge-gated`
on a criterion that is not a merge gate.

## R7 — evidence quality of the 215 hand-flipped rows

168 name both a PR number and a sha; 46 name a sha only; 1 names a PR only;
**3 name neither** — `cch-w46-s2-decommission-refusal-is-terminal` #8,
`cch-w1-census-disposition` #7, `gr-bl-close-convention-unmet-criteria` #0.
The w46 claim ("content on origin/main: decommissionRefusalTerminal") is nonetheless
TRUE:

    git show origin/main:cloud/priv/static/app.js | grep -c decommissionRefusalTerminal   # 3

## R8 — already-filed rows (Standing Law 0: claim, never re-cut)

    bp search query "merge-gated override"

- `cch-w56-bl-merge-gated-override-has-no-authority-check-and-no-record` — open, p1, 0/4
- `cch-bl-merge-gated-override-cannot-tell-a-lead-from-a-builder` — open, p2, 0/4
- `cch-w49-bl-merge-gated-stamp-guard-fires-on-any-mention` — open, p3, 0/2
- `cch-w56-bl-six-free-closes-await-a-lead-attestation` — open, p0, 0/5
- `cch-w41-bl-six-merge-gated-rows-are-paid-and-await-a-lead-stamp` — open, p1, 0/4
- `cch-w41-bl-a-standing-instrument-resolves-open-merge-gated-criteria` — open, p2, 0/4
- `cch-w19-bl-stamp-merge-gated-flag-undocumented` — open, p2, 0/2
