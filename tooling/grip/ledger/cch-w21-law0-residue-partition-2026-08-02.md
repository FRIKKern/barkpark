# CCH wave 21 — Law 0 residue partition (re-derivation recipe)

Timestamped denominator, orphan partition, and disposal schedule. Every number below
is re-derivable by the command printed beside it. Read at **2026-08-01T23:46:21.344Z**
(the seal predicate's own `read at` line).

## 1. The denominator (quote THIS, never `bp task get`'s child_count)

```sh
BP_TOKEN=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['token'])") \
  node cloud/priv/static/__preview__/seal-predicate.mjs \
  --epic cloud-console-hardening-epic --successor cch-instruments-epic 2>&1 | head -8
```

```
read at 2026-08-01T23:46:21.344Z  (live ledger)
roster: 258 children  {"in_progress":1,"open":91,"done":139,"cancelled":26,"considering":1}
CLAUSE (a) forwarding — residue 93 (live 92, considering 1)
  forwarded under successor : 0
  permanent human gate      : 3
  UNNAMED RESIDUE (orphans) : 90
```

Law 0 cap for wave 21 = **93**. `bp task get` says 261/94 — that is the LIFETIME
child_count plus `drafts.*`; the 3-row gap is drafts, not rows (D105).

## 2. Orphan partition (90 rows)

Classified by BODY/selector, never by title. Law 0's instrument classes are
gate / generator / harness / required-checks / ledger-hygiene.

| class | count | destination |
|---|---|---|
| INSTRUMENT-class (belongs under `cch-instruments-epic`) | **43** | `bp task move <id> cch-instruments-epic` |
| PERSON-FACING console rows (stay on the parent) | **34** | stay |
| NEITHER — backend / API / ops / bp-CLI, no console surface and no instrument | **13** | DISCLOSE by name (D94: never invent an address) |

Re-derive the roster the partition was cut from:

```sh
TOKEN=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['token'])")
curl -sG "https://guerrilla.barkpark.cloud/v1/data/query/production/task" \
  --data-urlencode "filter[parent_id]=cloud-console-hardening-epic" --data-urlencode "limit=500" \
  -H "Authorization: Bearer $TOKEN" | python3 -c "
import json,sys
GATES={'cch-hg-compose-network-recreation','gr-ops-platform-admin-emails','gr-backlog-qr-live-scan-proof'}
d=json.load(sys.stdin)['result']['documents']
o=[x for x in d if x.get('lifecycle_status') in ('open','in_progress','considering') and x['_id'] not in GATES]
print(len(o))
for x in sorted(o,key=lambda y:y['_id']): print(x['_id'],'|',x.get('lifecycle_status'),'|',(x.get('title') or '')[:110])"
```

### NEITHER bucket, named in full (13)

`cch-bl-lifecycle-token-reaper`, `cch-cloud-static-gzip-html`,
`cch-w12-bl-events-422-overstamps-session`, `cch-w12-bl-redact-env-secrets-opt-in-on-3-of-24`,
`cch-w12-bl-session-touch-has-no-rescue`, `cch-w15-bl-publish-wall-rationale-length-opaque`,
`cloud-console-operator-audit-log` (considering), `gr-backlog-compose-env-passthrough-audit`,
`gr-backlog-console-redaction-allowlist`, `gr-backlog-operator-digest-send`,
`gr-backlog-tfa-confirm-throttle`, `gr-bl-cli-test-send`, `gr-blk-cp-deploy-rollback-stale-env`.

These are structurally permanent orphans: neither charter owns them, and D94 forbids
inventing a destination. They are a hard floor of 13 under clause (a).

## 3. Disposal schedule — what the wave must do to hold ≤93

Filing 4 person-facing slices takes residue 93 → 97, so **≥4 rows must close or forward**.
Ten dispositions need no engineering at all:

| # | rows | action | evidence | residue |
|---|---|---|---|---|
| A | `cch-w20-s3` `cch-w20-s6` `cch-w20-s7` `cch-w20-s8` | CLOSE | PRs #8984/#8985/#8988/#8986 MERGED (`405f6ebae`, `3c6d1540a`, `99ea46c1b`, `c25466dac`); each row sits at N-1/N with only its merge-gated criterion owed | 93 → 89 |
| B | `cch-w19-s3` `cch-w19-s6` `cch-w19-s7` `cch-w19-s8` | CANCEL into the w20 twin, MIGRATING unique content first | same defect + same selectors as the w20 rows; all four at 0/N and unclaimed; `cch-w20-s6`'s own claim note says "cancels cch-w19-s6-attention-row-wrap" | 89 → 85 |
| C | `task-802585b77fc136b1`, `cch-w18-bl-tablet-attention-row-worst-cell-misnamed` | CLOSE | named as also-closed by `cch-w20-s6`'s claim note, whose PR #8985 is merged | 85 → 83 |
| D | the 43 INSTRUMENT-class rows | FORWARD (`bp task move <id> cch-instruments-epic`) | D83: forwarding is membership in `fetchRoster(SUCCESSOR)` (seal-predicate.mjs:351) | 83 → 40 (ceiling) |

Unique content to migrate before cancelling in B (selectors present in the w19 row and
absent from its w20 twin): w19-s3 — `.fleet-main`, `.instance-card-head`, `.instances-grid`;
w19-s6 — `.status-pill-detail`; w19-s7 — `.status-pill-label`.

## 4. Claims: `bp task claim`, not `bp task release`

Every wave-19/20 slice claim has `"worker": null` and an `expired_at` in the past
(w19 rows 2026-08-01T20:11–20:15Z, w20 rows 22:28–22:40Z). Expired ≠ held; `bp task release`
requires a live `worker_id` + `observed_epoch` and has nothing to release.

```sh
bp task get cch-w19-s1-guard-loses-in-ci -o json | python3 -c "import json,sys;print(json.load(sys.stdin)['doc']['claim'])"
```

Exactly ONE row epic-wide is live-held: `cch-w19-bl-baseline-one-integer-assertion`
(`in_progress`, worker `loop-lead`, epoch 1, ts 2026-08-01T23:04:12Z, no `expired_at`) —
possibly a concurrent session. That one, and only that one, is a `release` candidate.

## 5. `bp task stamp --merge-gated` does not exist

```sh
bp capabilities -o json | grep -c 'merge-gated'   # -> 0
bp task stamp --help | grep -i 'merge\|gated'      # -> no match, rc=1
```

Merge-gating is criterion PROSE. `cch-w19-bl-stamp-merge-gated-flag-undocumented` asserts the
flag EXISTS and is merely undocumented — that premise is refuted; the row needs amending, not
a manifest entry.

## 6. D83 vs Law 0 — no tension, disjoint populations

Both reduce to one predicate: `forwarded = new Set(fetchRoster(SUCCESSOR).map(c => c._id))`
at `cloud/priv/static/__preview__/seal-predicate.mjs:351`. Membership in the successor's
roster is the only thing the instrument reads, and `parent_id` is the only thing that
produces membership.

- **Law 0's filing half governs rows that do not exist yet.** "File with `parent_id:
  cch-instruments-epic` AT CREATE TIME (legal on every constraint at once: it is a create,
  never a re-parent…)". The constraint being dodged is #8500's unmerged branch — a create
  touches Postgres only. It says nothing about existing rows.
- **D83 governs rows that already exist.** "forwarding is MEMBERSHIP IN THE SUCCESSOR'S
  ROSTER, so the residue must be RE-PARENTED." After birth, `parent_id` can only change by
  `bp task move <doc_id> <new_parent_id>` ("Re-parent a task (rail-l3) … Emits a
  task.reparented event").

So: **create-with-parent for new instrument rows, `bp task move` for the 43 existing ones.**
Neither rule ever applies to the same row. The one live hazard both share is D94's:
`.claude/workflows/bp-cloud-console-instruments-charter.md` is STILL absent from origin/main
(`git cat-file -e` → 128), so a forwarded row's destination charter is unreadable — the
forward is legal to the predicate and illegible to a cold agent, and forwarding all 43 takes
the successor from 78 live to 121 live under a charter that still declares no health
predicate (D172 conditions 1 and 3).
