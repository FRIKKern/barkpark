# cch wave 67 — Standing Law 0 executed: four closes, three integers

Read timestamp (UTC): `2026-08-10T01:09:20Z`. Executed by the wave-67 verifier lane `law-0-execute`.
Re-derive, do not re-discover.

## Required contexts (re-derived live, never quoted)

```
gh api repos/:owner/:repo/branches/main/protection -q '.required_status_checks.contexts[]'
Elixir gate
PR references an active task
Cloud gate
Console gate
```

Exactly FOUR. Every merge-gate criterion below was scored against this live read.

## The four rows

Each closed on its OWN stored `claim.previous_worker` (53 chars, byte-for-byte — the short slugs
`cch-w66-s2/s3/s4` do NOT resolve as task ids) and on the epoch returned by its self-resume claim.

| row (doc_id) | PR | merge sha | compare→main | head sha | prev_worker (53) | epoch stored → claimed | close |
|---|---|---|---|---|---|---|---|
| `cch-w59-bl-font-pin-refuses-on-every-cloud-pr-about-one-run-in-eight` | #11530 | `6546f72b4a711186dab48e770049b969cfbe4d28` | ahead | `1b4dc14b09096ec6faf82792fb146691bc9b0334` | `epic-builder-the-font-pin-stops-refusing-about-a-docu` | 7 → 8 | done 5/5 |
| `cch-w66-s2-the-autostamp-records-what-it-actually-observed` | #11531 | `8a8a2fdd7fdf8e7c814af8ffd61fa26935c6e0b2` | ahead | `fe163c9a8d7f96b149011ae38976cf8fd3ba4ae7` | `epic-builder-an-auto-stamped-merge-gate-records-what-` | 6 → 7 | done 7/7 |
| `cch-w66-s3-the-site-card-stops-asserting-a-deletion-it-never-observed` | #11532 | `ef82a20aaded5cf6707cb80aded3928bc3f9ad50` | ahead | `479b8c38d4bc9d8b37623f14fe4e070963a30992` | `epic-builder-the-site-card-stops-asserting-a-deletion` | 6 → 7 | done 7/7 |
| `cch-w66-s4-law-0-nine-closes-and-three-integers` | #11533 | `74b2b3d4cba42d1b00902e588be2ede96f63f327` | ahead | `97ba7d315728074eea531a8351d14876548c0ca1` | `epic-builder-law-0-nine-closes-three-integers-on-each` | 6 → 7 | done 7/7 |

All four heads: `Cloud gate`, `Console gate`, `Elixir gate`, `PR references an active task` = `success`,
**exactly one instance of each**, **zero duplicated and zero cancelled siblings** (`uniq -c` = 1 per name).
Read-back proves **zero** of the four minted a `close_override`.

Re-derive:

```
for s in 1b4dc14b09096ec6faf82792fb146691bc9b0334 fe163c9a8d7f96b149011ae38976cf8fd3ba4ae7 \
         479b8c38d4bc9d8b37623f14fe4e070963a30992 97ba7d315728074eea531a8351d14876548c0ca1; do
  echo "== $s"
  gh api "repos/:owner/:repo/commits/$s/check-runs?per_page=100" \
    -q '.check_runs[]|select(.name=="Elixir gate" or .name=="Cloud gate" or .name=="Console gate" or .name=="PR references an active task")|"\(.name)\t\(.conclusion)"' | sort | uniq -c
done
```

## Three mechanisms that would have silently broken this run — measured, not assumed

1. **THE MERGE SHA MANUFACTURES A FALSE RED.** `74b2b3d4…` (#11533's merge commit) carries only FOUR
   check-runs — `Break-glass harness` (skipped), `Break-glass watch` (success), `Stale verdict harness`
   (skipped), `Stale verdict watch` (**failure**) — and **none of the four required contexts**. Reading it
   instead of the head would have reported #11533 red on a job that is not even required.
2. **STAMP DEMANDS `in_progress`; CLOSE'S SELF-RESUME DOES NOT COVER IT.** A released row (`worker: null`,
   `lifecycle_status: open`) refuses `bp task stamp` with `not_in_progress:open`. The working order is
   **claim (self-resume, epoch bumps) → stamp → close on the NEW epoch**, not close-on-stored-epoch.
3. **TWO GUARDS FIRED AND WERE OBEYED, NOT ROUTED AROUND.** `bp task close --set criteria:=…` refused the
   merge-gated flip ("criteria flipped in this very close command do not count — that would be the closer
   grading its own homework"), and `bp task stamp` refused it again with `merge_gated_criterion` until
   `--merge-gated` was passed by the lead-role closer. Both refusals are correct; neither was overridden
   with `criteria_override`.

## Draft twin

`drafts.cch-w66-s2-the-autostamp-records-what-it-actually-observed` existed at `lifecycle_status: open`,
`status: draft`, 5/7 — a stale DRAFT revision of a published row that is now `done` 7/7. Cancelled on its
own stored `previous_worker` + epoch 5. **s3, s4 and the w59 row have NO draft twin** (`not_found`).
It never inflated the census: the epic's children list returns the published row for a doc that has both,
so the 9 `drafts.` children are only drafts with no published counterpart.

## Three integers

Denominator re-derived AFTER all writes, with a truncation guard and a drafts exclusion:

```
bp task get cloud-console-hardening-epic -o json | python3 -c "
import json,sys,collections
d=json.load(sys.stdin); ch=d['children']; cc=d['doc']['child_count'] if d['doc'].get('child_count') is not None else d.get('child_count')
print('guard', cc==len(ch))
pub=[k for k in ch if not k['doc_id'].startswith('drafts.')]
print(len(pub), dict(collections.Counter(k['lifecycle_status'] for k in pub)))"
```

```
child_count(field)= 885  len(children)= 885  TRUNCATION_GUARD_OK= True
published= 876 drafts_excluded= 9
{'done': 383, 'considering': 1, 'open': 425, 'cancelled': 67}
LIVE_final= 425
```

- **CLOSES = 4** (published rows; the draft cancel is not counted — it is not a published child)
- **MOVES = 0** (no `bp task stage`, no reparent, no reopen this lane)
- **SELF-FILED = 0** (this lane filed nothing; the verifier role forbids it)

Scored against **LIVE_final − self_filed = 425 − 0 = 425** → **4 / 425**.

Wave 66 opened at LIVE 429 and, before this run, still read 429 (425 open + 4 in_progress). After this
lane: **425 open + 0 in_progress = 425**. The honest movement is **−4**, and it is the ledger being paid,
not new code — every one of the four PRs had already merged.

## Advisory reds on main — named, not closed over

Main tip `f53167087a4d4b588bafa73db522e2cab521e139`:

- `Crown reconcile` — **success** on the tip. It was `failure` on `8a8a2fdd` and `a34dd993` earlier in the
  wave; it has since cleared. Do not carry it forward as an open red.
- `Stale verdict watch` — **failure**, and it is failing for a real reason that has nothing to do with
  wave 66: NINETEEN conflicted (DIRTY) PRs are still asserting green required verdicts main has moved past
  and can dispatch nothing to refresh them — #6028 #6057 #6086 #10054 #10085 #10086 #10129 #10173 #10256
  #10400 #10404 #10407 #10496 #10522 #10523 #10720 #10722 #10811 #10944. Its own error text: *"it will keep
  failing every 30 minutes"* until those are rebased or closed. It is not in the required set, so it blocks
  nothing — but it is a standing red that will mask a future real one.

## One naming lie worth a row

#11531's head carries `gofmt drift ceiling (blocking)` = **failure** alongside `gofmt -l (advisory)` =
**failure**. Neither is in the protection required set, so the word **"blocking"** in that job name asserts
an authority the branch protection does not grant it — exactly this epic's thesis defect, living inside its
own CI vocabulary.
