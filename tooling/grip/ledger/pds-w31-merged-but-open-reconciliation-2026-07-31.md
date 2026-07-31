# PDS wave 31 — merged-but-open ledger reconciliation (re-derivation recipes)

Derived at `origin/main 8b2018bc0`. Every line below is a command that re-derives
the fact from scratch. No stamps were applied by the verifier (VERIFIER fence:
no bp mutations); these are the payloads Decide applies.

## 0. The population (the mandated proof)

```
cd /Volumes/SATECHI/github/barkpark && for t in pds-w29-pay-lb pds-w29-registry-postcondition-invariant pds-w30-live-proof-runner pds-w30-board-envelope-poison-parity pds-w29-taskboard-envelope-fence; do echo "== $t"; bp task get $t -o json | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];c=d['content'];ac=c.get('acceptance_criteria') or [];print(c.get('lifecycle_status'), sum(1 for a in ac if a.get('met')),'/',len(ac));print(' claim:',json.dumps(d.get('claim'))[:120])"; done
```

Result: FOUR merged-but-open rows, not five. `pds-w29-taskboard-envelope-fence`
is already `done 8/8` (closed by loop-lead 2026-07-31T21:11:12Z, epoch 8).

## 1. Merge facts (PR -> squash sha on main)

```
for n in 8644 8645 8647 8648; do printf "#%s " $n; git log origin/main --oneline --grep="(#$n)" -1; done
```

    #8644 9a1811da4  pds-w29-pay-lb
    #8645 f84f4ac93  pds-w29-registry-postcondition-invariant
    #8647 1cef6eed3  pds-w30-live-proof-runner
    #8648 8b2018bc0  pds-w30-board-envelope-poison-parity

## 2. Per-criterion verdicts

### pds-w29-pay-lb c10 (merge-gated) -> STAMP
Evidence: `git log origin/main --oneline --grep="(#8644)" -1` => `9a1811da4`;
`git merge-base --is-ancestor 9a1811da4 origin/main` exits 0.

### pds-w29-pay-lb c13 -> STAYS UNMET (two literal violations, do not stamp)
```
git show --stat 9a1811da4 -- internal/cli/hetzner_net_cmd_test.go
git show origin/main:internal/cli/hetzner_lb_cmd_test.go | grep -nE 'getPath:|postPath:'
```
(a) The merged commit DID edit `internal/cli/hetzner_net_cmd_test.go` (+13:
one `GET /load_balancers/7`, one `GET /floating_ips/11`) — the criterion
forbids exactly that (PDS-D414 ownership).
(b) Single-resource GET fixtures exist for `/load_balancers/7`,
`/floating_ips/11`, `/primary_ips/9` — there is NO `/placement_groups/{id}`
or `/certificates/{id}` GET. The file itself declares the deviation at
`hetzner_lb_cmd_test.go:365-368` ("observe from the create response object
rather than re-reading"), which is criterion 3's class-A2 ruling. So (b) is a
criterion-vs-design conflict, (a) is a real breach.

### pds-w29-registry-postcondition-invariant c9 -> STAYS UNMET (half-satisfied)
Merge half is TRUE (`f84f4ac93`). The closure half is FALSE:
```
for t in pds-w27-bl-support-run-registry-rows-vacuous pds-bl-hzresdone-registry-row-vacuous; do bp task get $t -o json | python3 -c "import json,sys;c=json.load(sys.stdin)['doc']['content'];ac=c['acceptance_criteria'];print(c['lifecycle_status'], sum(1 for a in ac if a.get('met')),'/',len(ac))"; done
```
=> `open 0 / 6` and `open 0 / 4`. Both are substantive (post-condition repairs,
derived population check, `backup restore` exemption), not closure formalities.

### pds-w30-live-proof-runner c10 (merge-gated) -> STAMP
Evidence: `#8647` => `1cef6eed3` on origin/main.

### pds-w30-board-envelope-poison-parity c6 -> STAMP (all three clauses true)
```
git log origin/main --oneline --grep="(#8648)" -1     # 8b2018bc0
bp task get pds-bl-board-tui-reader-honesty -o json   # done 4/4, criteria 2+3 amended and stamped
bp task get pds-w29-taskboard-envelope-fence -o json  # done 8/8
```

## 3. Claims (assignment item b)

```
bp task ls --all -o json > /tmp/all.json
python3 -c "import json;rows=json.load(open('/tmp/all.json'))['docs'];[print(r['doc_id'],(r.get('claim') or {}).get('epoch'),(r.get('claim') or {}).get('expired_at')) for r in rows if r['doc_id'].startswith('pds') and (r.get('claim') or {}) and not (r.get('claim') or {}).get('closed_at')]"
```
PDS family: exactly ONE open claim with `expired_at: null` —
`pds-bl-repull-into-populated-target-500`, epoch 3, worker null. There is NO
epoch-8 non-expiring loop-lead claim in the PDS family. The four merged-but-open
rows all carry EXPIRED claims (worker null, expired_at in the past) — lapsed
leases, not locks. Repo-wide the null-expiry population is 105 of 4498 rows,
which makes it a ledger-wide property, not a PDS defect.

## 4. Not-taken work (assignment item c) — derived numbers

- func-value shrinkage vector: ALREADY FILED as
  `pds-bl-census-ast-scan-blind-to-func-values` (open, criteria present).
  Do not file a duplicate.
- duplicated pds-live runners: `scripts/pds-live-hetzner-placement-group.sh`
  (635 lines) and `scripts/pds-live-bp-write-receipt.sh` (609). LCS identical
  lines = 228 (186 non-blank), NOT 215. Re-derive:
  ```
  python3 -c "import difflib,subprocess as s;a=s.check_output(['git','show','origin/main:scripts/pds-live-hetzner-placement-group.sh'],text=True).splitlines();b=s.check_output(['git','show','origin/main:scripts/pds-live-bp-write-receipt.sh'],text=True).splitlines();m=difflib.SequenceMatcher(None,a,b,autojunk=False).get_matching_blocks();print(sum(x.size for x in m))"
  ```
- narration near-duplicate:
  `internal/provisioner/support.go:448` `"%s reads %s with capacity %s"` vs
  `internal/cli/cloud_support_cmd.go:799`
  `"%s reads %s with capacity %s on the main's roster"`.
  ```
  git show origin/main:internal/provisioner/support.go | sed -n '448p'
  git show origin/main:internal/cli/cloud_support_cmd.go | sed -n '799p'
  ```
