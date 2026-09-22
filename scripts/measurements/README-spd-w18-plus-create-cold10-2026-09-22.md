# spd-w18 c0 — ten COLD loads, BOTH desk steps, one press each

`spd-w18-plus-creates-without-navigating`, criterion c0: *"Both desk steps (Structure row select,
and the `+`) land on a SINGLE press across 10 consecutive cold runs, and the per-step latencies are
quoted."*

Data: `spd-w18-plus-create-cold10-2026-09-22.json`.

**Nothing was built for this.** The instrument is the harness PR #16603 (`41de602a0`). The sibling
row `spd-w18-desk-click-latency` measured the `#item-paper` half with it two hours earlier
(PR #19755, `38c4dfa32`, ten runs on `1b3856eed`). This adds the `"+"` half and requires BOTH steps
on one press in the same run.

## The numbers

Host `https://guerrilla.barkpark.cloud`, served **`e02e4296d`** — the harness's own PRE/POST stamp
read the same sha on all ten runs, so no deploy landed mid-measurement. Note this is **not** the
sibling's `1b3856eed`: a deploy landed on guerrilla at 04:44Z. Headless Chrome `153.0.8010.53`,
node v22.22.0. 2026-09-22 05:55:49Z → 06:21:47Z.

    run   #item-paper           "+"                  wire (each step)
      1     0.5 s   1 press     0.8 s   1 press      SENT · 1 click frame
      2     0.6 s   1 press     0.8 s   1 press      SENT · 1 click frame
      3     0.9 s   1 press     1.9 s   1 press      SENT · 1 click frame
      4     0.5 s   1 press     0.8 s   1 press      SENT · 1 click frame
      5     0.5 s   1 press     1.4 s   1 press      SENT · 1 click frame
      6     1.1 s   1 press     3.3 s   1 press      SENT · 1 click frame
      7     0.5 s   1 press     1.2 s   1 press      SENT · 1 click frame
      8     0.5 s   1 press     1.5 s   1 press      SENT · 1 click frame
      9     0.9 s   1 press     1.5 s   1 press      SENT · 1 click frame
     10     0.5 s   1 press     1.2 s   1 press      SENT · 1 click frame

Structure row: min **0.5 s** · median **0.5 s** · mean **0.65 s** · max **1.1 s**.
The `"+"`: min **0.8 s** · median **1.3 s** · mean **1.44 s** · max **3.3 s**.
**20 of 20 steps on a single press, 0 retries**, and exactly one `"type":"click"` frame per step
per run — twenty presses, twenty frames.

Compare the row's own history: `e4ed31a10` 6.1 s and 6.4 s; `4f046cce1` 15.0 s across 2 presses and
**never within 20.0 s across 3 presses**, with no flash and real drafts created anyway;
`25e69158a` 15.0 s across 2 presses on both steps.

## Three controls

**COLD is proved, not asserted.** Every run was handed its own directory, created empty by the
driver and verified `entries_before=0` immediately before launch. A separately watched eleventh run
polled that directory at 2 Hz *during* the run: the profile appeared at t=0.0 s as
`studio-journey-tighxU` with **no `Default/Cookies` file at all** and **0 cache files**, the cache
climbed 0 → 31 (t=0.6 s) → 82 (t=1.2 s) → 89 (t=3.5 s), and the directory was empty again at
t=25.4 s after teardown. `journey.mjs` also mints a fresh single-use 60 s ticket per run and the
admin discriminator passed on all ten, so each session's cookie is that run's own.

**"One press" is an absence, and an absence is never caught by inspection.** Mutation
**M-RETRY-PLUS** was applied to the *offline* fixture's `new-document` handler —
`if ((window.__mSwallowFirstPlus = (window.__mSwallowFirstPlus||0)+1) === 1) return;` — so the first
`"+"` press is swallowed. The same check line then printed **`paper-fx2 in 5.2s after 2 press(es)`**
against `paper-fx2 in 0.2s after 1 press(es)` unmutated. Latency and attempt counter both move. The
mutation was reverted; `cmp` against a copy taken before the edit is identical and it does not ship.

**A green is only a result if it could have gone red.** Offline: `self-test` executes 134 assertions
(floor 40) and exits `good=0, rot=1`. Live, on the deployed desk, a **single** `evaluate_script` —
arming and reading never split across two calls — set `data-phx-ref-src` on the `"+"` itself,
pressed, polled 8 s; then removed the attribute and pressed **the same button on the same page**.

    ARM 1  data-phx-ref-src set   answered=false   URL unchanged after 8.064 s   SWALLOWED
    ARM 2  attribute removed      answered=true    …/paper/paper-8be087501234ae2d in 1.213 s

**A side finding for c2:** the swallowed ARM 1 press **created nothing**. A drafts-perspective query
ordered `_createdAt:desc` straight afterwards showed exactly one new document in that window —
ARM 2's. On `e02e4296d` the client-side discard is a pure discard, not a silent create. That is the
opposite of what `4f046cce1` did, and it is the half of this row's title defect that has gone away.

## What this does NOT say

**This is a MEASURE case, not a FIX case.** Nothing was changed to make it pass. The defect the row
describes — both steps needing a second press, up to 15 s, no feedback, and presses that create
drafts without navigating — is **not reproducible on the build now served**. It was not fixed by
this work.

Reds not hidden: run 6's PERSIST beat FAILED (*"Autosave did not reach the server"* after 20.1 s,
44.0 s wall against ~25 s typical) — downstream of CREATE; its two desk steps still landed on one
press each. Guerrilla's `/status.json` said `status=degraded` throughout. The measuring laptop sat at
load average 35 from sibling lanes; two runs hung in Chrome's CDP attach past nine minutes and were
killed and redone serially under a 120 s timeout, and a further set was quarantined for having raced
a second driver loop. None of those contributes a number above.

## c3 is NOT satisfied here, and its premise is wrong

c3 asks for *"the three Untitled orphan drafts these runs left on guerrilla production"* to be swept
with the ids quoted. **Nothing has been deleted.** A full census (all 1084 paper documents, paged at
limit=100, 33 of them `_draft=true`) found:

| id | title | blocks | created |
|---|---|---|---|
| `drafts.paper-7780f97accedfd66` | `"Untitled"` | 0 | 2026-07-29T13:23:49Z |
| `drafts.paper-b28358ff271b260e` | `"Untitled"` | 0 | 2026-07-09T14:16:39Z |
| `drafts.paper-3149ef706e777628` | `"Untitled"` | 0 | 2026-07-06T21:57:49Z |
| `drafts.paper-3f14ad47a746ef60` | `null` | 0 | 2026-08-05T20:55:22Z |
| `drafts.paper-aec37610a3247151` | `null` | 0 | 2026-07-16T13:58:36Z |

Three by title string; **five** by the shape `sweepCandidate()` itself uses (no title of its own, no
more than the two seeded template blocks; `_updatedAt == _createdAt` on all five). The count is a
function of the predicate, which is why an enumeration was the wrong thing for the row to carry.

**None of the five can be from the runs the row names.** Those runs are on `e4ed31a10`,
`4f046cce1` and `25e69158a`, committed 2026-07-29T17:12:54Z, 2026-07-30T02:07:57Z and
2026-07-30T02:08:06Z. The newest untitled draft on the box was created 2026-07-29T13:23:49Z —
**3 h 49 m before `e4ed31a10` existed**. That agrees with the row's own description, which already
says of the `4f046cce1` orphans: *"Three of them survived and were swept by hand."* They were swept
in July. c3's subject is gone; what survives is older debris from unrelated sources.

The discrimination is not vacuous in either direction: the same census returns 28 other drafts that
are **not** candidates and are visibly human (`drafts.personal-dev-fleet-field-guide`, 53 blocks;
`drafts.paper-9cb57212fe9a1d63`, 88 blocks), a title filter for a real title returns `count=1`, and
one for `zzz-no-such-title-zzz` returns `count=0`.

## An instrument finding the self-clean cannot see

`sweepCandidate()` requires an empty-or-`"Untitled"` title. A run killed **after** its TYPE beat
leaves a draft whose title is the typed marker text — so it is permanently invisible to every later
sweep, by any run, forever. This session's own killed and quarantined runs left six such drafts.
They are catalogued and were **not** deleted; they are listed with their provenance in the task
thread pending the owner's go-ahead, exactly like the five above.
