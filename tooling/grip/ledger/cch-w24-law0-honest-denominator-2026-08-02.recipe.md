# cch-w24 — Law 0 with an honest denominator (re-derivation recipe)

Written by the wave-24 slice `cch-w24-s6-law0-repayment-counts-its-own-filings`, worker
`epic-builder-law-0-is-executed-with-an-honest-denomin`, on 2026-08-02, from a worktree at
`origin/main` `20d61d1874a260fec273942dd32d7b4e29d86eb5`.

**Re-derive every number below before quoting it.** They are dated observations, not constants.
This file exists so the next wave RE-DERIVES rather than INHERITS — the failure mode it was written
against is a wave quoting a predecessor's `orphans` as its own baseline.

## 1. The command, and the three ways to get a wrong number

```
node cloud/priv/static/__preview__/seal-predicate.mjs --successor cch-instruments-epic \
  | grep -E 'roster:|forwarded|UNNAMED|VERDICT-TOKEN'
```

Three traps, all of which have actually produced wrong numbers in this epic:

1. **Do not run it from the primary checkout.** It is hundreds of commits behind and its copy of the
   predicate DIFFERS, so `--repo` there yields a wrong `b=`. Run it from a worktree whose HEAD equals
   `origin/main`, and verify that equality (`git rev-parse HEAD; git rev-parse origin/main`) rather
   than assuming it.
2. **Do not pass `--ladder-only`.** That path prints `a=NOT-READ c=NOT-READ` and carries **no
   `orphans=` field at all** — it silently produces no number rather than a wrong one.
3. **Do not inherit a predecessor's number.** See §2.

## 2. The denominator moves while you work — count your OWN wave's filings against yourself

Measured this wave, both reads from the same worktree and command:

| moment | UTC | roster | orphans |
|---|---|---|---|
| direction's quoted number | 12:03Z | 300 | 97 |
| **s6 FIRST CLAIM** | **12:37:56Z** | **313** | **109** |
| **s6 DEBRIEF** | **12:59:41Z** | **318** | **111** |

`VERDICT-TOKEN` at first claim:

```
SEAL-PREDICATE NO-SEAL a=FAIL b=PASS c=PASS orphans=109 considering=1
  successor=cch-instruments-epic epic=cloud-console-hardening-epic mode=live stubbed=0 waived=0
```

The brief pinned 97 and the first claim read 109. **The 12 extra rows are this wave's own slices and
backlog**, filed between 12:03Z and the first claim (13 rows created, minus one cancel —
`cch-w24-law0-repayment-as-a-claimed-slice`, the placeholder this very slice superseded). A wave that
quotes a pre-filing number as its baseline is crediting itself for a denominator it already grew.
**The baseline is whatever the predicate says at YOUR first claim, after your wave has filed.**

### The 11:18Z drop is NOT this wave's, and here is how that was settled

`102 -> 97` was five WAVE-23 slices closed by worker `loop-lead` in a 17-second window, **79 minutes
before this wave claimed anything**:

```
2026-08-02T11:18:28.224906Z  loop-lead  done  cch-w23-s1-status-pill-detail-token-bounded
2026-08-02T11:18:31.356898Z  loop-lead  done  cch-w23-s3-site-row-second-domain-visible
2026-08-02T11:18:35.594411Z  loop-lead  done  cch-w23-s6-cred-remediation-reachable
2026-08-02T11:18:41.501227Z  loop-lead  done  cch-w23-s4-cruelty-ledger-per-family-shape
2026-08-02T11:18:45.524634Z  loop-lead  done  cch-w23-s5-w12-leg-corpus-and-deciding-numbers
```

Quoting 102 as first-claim and 97 as progress would manufacture a `-5` this wave did not pay — the
phantom-delta error D256 forbids. Re-derive the closing worker and timestamps with:

```
curl -sG "https://guerrilla.barkpark.cloud/v1/data/query/production/task" \
  --data-urlencode "filter[parent_id]=cloud-console-hardening-epic" \
  --data-urlencode "limit=500" -H "Authorization: Bearer $BP_TOKEN" \
| python3 -c "import json,sys;[print(c['claim']['closed_at'],c['claim']['closed_by'],c['_id']) \
for c in json.load(sys.stdin)['result']['documents'] if (c.get('claim') or {}).get('closed_at')]" | sort
```

## 3. A cancel is not automatically a repayment — check it against the PUBLISHED roster

**This wave's most expensive lesson.** Two of four cancellations earned ZERO credit, and neither was
visible from the CLI:

- `task-c64f2a37d7f97bd8` was a **draft**. Drafts are not in the published roster, so they were never
  orphans. Cancelling one lowers nothing. (Cancelling it was still right — publishing it would have
  grown the denominator for zero information.)
- `cchi-w20-bl-modal-oracle-runs-nowhere` had **already been forwarded**. Its PUBLISHED `parent_id` is
  `cch-instruments-epic`, so it was never among the 109 — even though `bp task get` shows it under
  `cloud-console-hardening-epic`, because **that is the DRAFT**.

> `bp task get <id>` can report a different `parent_id` than the published row the predicate reads.
> The predicate reads `GET /v1/data/query/production/task`. So must you.

```
curl -sG "https://guerrilla.barkpark.cloud/v1/data/query/production/task" \
  --data-urlencode "filter[_id]=<row>" -H "Authorization: Bearer $BP_TOKEN" \
| python3 -c "import json,sys;[print(d['parent_id'],d['lifecycle_status']) for d in json.load(sys.stdin)['result']['documents']]"
```

**Check every row you intend to count BEFORE you count it**, against the published roster you
measured the baseline from — not against the list of rows you wrote to.

## 4. Forwarding is shut, on two independent grounds

**Ground 1 — D172's precondition is ABSENT.**

```
git cat-file -e origin/main:.claude/workflows/bp-cloud-console-instruments-charter.md; echo rc=$?
# fatal: path ... does not exist in 'origin/main'
# rc=128
```

**Ground 2 — forwarding is mechanically incapable of credit.** `forwarded` and `children` are two
separate `filter[parent_id]` reads (`seal-predicate.mjs:346`) and a task carries exactly ONE parent,
so the sets cannot overlap. Measured 2026-08-02:

```
parent    (cloud-console-hardening-epic) : 316
successor (cch-instruments-epic)         : 104
INTERSECTION                             : 0
```

`forwarded under successor : 0` is a structural identity, not a bug. A re-parent lowers `orphans` by
**leaving the denominator**, which is numerically identical to an evidence close and leaves **no
trace** in the predicate's output. That indistinguishability IS the laundering risk, and it is why
`F` must be reported as its own component rather than folded into a bare net.

**Ceiling for any future wave that does forward: `F <= C`.**

## 5. Report the net with its components separated

A bare `-N` reads as work. Report `C` / `D` / `F` separately, because the predicate prints no trace
of which mechanism moved the number.

- **C** — evidence-closes (a row closed because its work is genuinely done)
- **D** — dedup-cancels (a duplicate collapsed into a survivor; the defect stays live)
- **F** — forwards (must be 0; see §4)

### Wave 24 slice s6, measured

| component | count | rows |
|---|---|---|
| C evidence-closes | **1** | `cch-w23-s2-account-modal-identity-bounded` (merge `80c198415`, ancestor rc=0) |
| D dedup-cancels (with credit) | **2** | `task-0b23fb7452aa457a`, `cchi-w22-bl-am-name-unbounded-every-width` |
| D dedup-cancels (ZERO credit, §3) | 2 | `cchi-w20-...` (already forwarded), `task-c64f2a37d7f97bd8` (draft) |
| F forwards | **0** | — |
| **s6 repayment** | **−3** | |

### The wave's net, which is the number that matters

```
97  (pre-wave)
+12 this wave's own filings, by s6's first claim      -> 109
+5  other slices' filings during s6's run             -> 114
-3  s6's repayment (C=1, D=2, F=0)                    -> 111  (measured 12:59:41Z)
```

**NET FOR THE WAVE: +14. POSITIVE, and stated plainly rather than hidden.** Standing Law 0's own
protocol requires this: *a wave that nets positive states the number and names what it repays.*

> **The roster is LIVE and it moved again while this file was being written**: a gate re-run at
> ~13:01Z read `roster: 319 / orphans 112`, one higher than the 12:59:41Z debrief, because another
> wave-24 slice filed a backlog row in the interval. That is not noise to be smoothed away — it is
> the thesis. **Every number here is only true at its timestamp**, which is why each one carries one,
> and why the next wave must re-derive at its OWN first claim rather than quote this file.
>
> A corollary worth stating: a wave cannot know its final net until its last slice stops filing, so
> the honest debrief number is the one read at the debrief, labelled as such — not the smallest number
> observed during the run.

**WHAT THE NEXT WAVE REPAYS.** The five criteria-less rows this slice perfected are now stampable and
are the honest first call — they were unbuildable before, which is why they accumulated:

- `cch-w23-bl-cruel-leg-blind-to-status-pill-detail` (9 criteria) — the flagship
- `cch-w23-bl-site-meta-320-line-guard` (9 criteria)
- `task-696a2fcf95e9c4da` (11 criteria) — prior art for `cch-w24-s7`; close it on THAT merge or not at all
- `cch-bl-cloudflare-identity-echo-no-surface` (6 criteria) — a DECISION row; outcome (c) cancel is legitimate
- `cch-w22-s1-residue-modal-oracle-uninvoked` (5 criteria) — survivor of the 4-row modal-oracle collapse

Two adjudications recorded ON the rows this wave, deliberately WITHOUT closing them:

- `cch-w21-bl-cred-remediation-scrolls-above-the-viewport` — substantially paid by `cch-w23-s6`'s
  merge (same 275-char azure string, same 390x390, axis-pinned) but the shipped leg clicks WITHOUT
  the `scrollIntoView({block:'center'})` the finding's −21 depends on (`grep -n scrollIntoView` on
  `overflow-guard.mjs` returns ONE hit, line 1126, a different leg). Settle it by re-driving with the
  original gesture; do not close it on the leg's existing green.
- The `.detail-url-text` trio is NOT a duplicate cluster — it is ORDERED.
  `cch-w15-bl-detail-url-fixture-never-overflows` is a strict PRECONDITION of
  `cch-w20-bl-detail-url-text-ellipsised-on-phone`, whose "if it reads 0 clipped, close as
  measured-clean" clause would otherwise be discharged on a corpus that measured
  `clientWidth 240, scrollWidth 240, truncated=false` in every cell.

## 6. Two client facts worth not re-learning

- **`--merge-gated` exists on `bp task stamp` and NOT on `bp task close`.** Both prior reports were
  half-right. `bp task close ... --merge-gated` returns `unknown flag`; the stamp accepts it. The
  flag does not appear in `--help` output, so grepping `--help` genuinely does under-report it —
  **probe the binary with `--dry-run` instead of grepping its help.**
- **A criterion cannot be flipped inside the close that consumes it.** The server refuses:
  *"criteria flipped in this very close command do not count — that would be the closer grading its
  own homework."* Stamp first, then close. This is a real guard; do not route around it.
- **A printed `rev` is not persistence.** One stamp this wave reported
  `stamp sent but NOT confirmed ... status 500` and had in fact **landed**. The read-back is the
  truth in both directions — re-GET and compare the stored value before believing either a success
  or a failure.
