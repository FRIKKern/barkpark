# CCH wave 25 — Law 0 at FIRST CLAIM, and the expired-lease question

Read live 2026-08-02T14:11:04Z. Every number below is re-derived by the command under it;
none is quoted from a prior wave.

## 1. The denominator, the predicate's own way

    BP_TOKEN=$(python3 -c 'import json;print(json.load(open("/Users/pelle/.config/barkpark/config.json"))["token"])') \
      node cloud/priv/static/__preview__/seal-predicate.mjs --successor cch-instruments-epic

    roster: 321 children  {"done":177,"open":110,"cancelled":33,"considering":1}
    CLAUSE (a) forwarding — residue 111 (live 110, considering 1)
      forwarded under successor : 0
      permanent human gate      : 3  [cch-hg-compose-network-recreation, gr-ops-platform-admin-emails, gr-backlog-qr-live-scan-proof]
      considering (disclosed)   : 1  [cloud-console-operator-audit-log]
      UNNAMED RESIDUE (orphans) : 108
    VERDICT-TOKEN: SEAL-PREDICATE NO-SEAL a=FAIL b=FAIL c=PASS orphans=108 considering=1 …

**LAW 0'S NUMBER AT FIRST CLAIM IS `orphans=108`** (D256: the rule is `orphans` off the
VERDICT-TOKEN line, never `residue` — quoting residue at first claim and orphans at debrief
manufactures a −3 nobody paid). Debrief must re-run this exact command.

Baseline for the delta: wave 24's own first-claim reading (D290) was `orphans=97`, roster 300.
Wave 24 recorded **no debrief number** — `origin/main`'s charter ends at D293 and none of
D291-D293 carries one. So the honest sentence is: **97 (w24 first claim) → 108 (w25 first
claim) = +11 across wave 24**, and the "102" in circulation is a superseded pre-w24 figure.

## 2. `orphans = residue − gates` is an identity here, not an accounting

`seal-predicate.mjs:366-371` puts a residue row in exactly one of gates / fwd / orphans, and
`fwd` requires membership in BOTH `fetchRoster(EPIC)` and `fetchRoster(SUCCESSOR)` — two
`filter[parent_id]` reads, one `parent_id` per task, so the intersection is a structural zero.
111 − 3 − 0 = 108. The `fwd` branch is unreachable; a re-parent lowers orphans by leaving the
denominator, invisibly.

## 3. The two `drafts.*` rows inflating `bp task get`'s 323

    bp task get cloud-console-hardening-epic -o json | python3 -c "
    import json,sys; d=json.load(sys.stdin)
    [print(json.dumps(c)) for c in d['children'] if str(c.get('doc_id')).startswith('drafts.')]"

    drafts.cch-w22-s2-site-row-name-and-host-bounded   open       5/10
    drafts.task-c64f2a37d7f97bd8                       cancelled  (foreign_claimed)

323 − 321 = 2, and the split is exact: open 111 vs 110, cancelled 34 vs 33.

* `drafts.cch-w22-s2-…` **duplicates a published row BY NAME** — the published
  `cch-w22-s2-site-row-name-and-host-bounded` is `done` with the byte-identical title
  ("A site named honestly takes the sites list 1497px sideways …"). The draft holds 5/10
  against a finished row; publishing it would be refused as a criteria regression (D250).
* `drafts.task-c64f2a37d7f97bd8` is **draft-only** — `GET /v1/data/doc/production/task/
  task-c64f2a37d7f97bd8` returns `not_found`. There is no published twin to collapse into.
  Its title duplicates `cchi-w20-bl-modal-oracle-runs-nowhere` in substance, not in id.

Neither is in the 108. Discarding both buys **zero** row-shrink (D256); do it for hygiene only.

## 4. THE EXPIRED LEASES DO NOT REFUSE A CLAIM — THEY COST A BUILDER NOTHING

Six live rows carry `claim.worker: null`, a stale `assignee` naming a finished wave's agent,
and an `expires_at` in the past:

    cch-w19-s1-guard-loses-in-ci                    epoch 7  exp 2026-08-01T20:15:01Z
    cch-w19-bl-baseline-one-integer-assertion       epoch 2  exp 2026-08-01T23:50:01Z
    cch-w12-bl-filing-law-parent-charter-half       epoch 2  exp 2026-08-01T07:02:00Z
    cch-w14-bl-site-open-phone-overflow             epoch 3  exp 2026-08-01T02:12:00Z
    cch-w12-s5-successor-split-and-letterbox-fence  epoch 13 exp 2026-07-31T14:06:01Z
    cch-w11-s1-flip-behind-a-generator-that-cannot… epoch 9  exp 2026-07-31T03:33:00Z

Probe, driven and then reverted:

    bp task claim cch-w14-bl-site-open-phone-overflow law0-throwaway-probe -o json
      → {"ok":true, claim:{"epoch":4,"worker":"law0-throwaway-probe"}, lifecycle_status:"in_progress"}
    bp task release cch-w14-bl-site-open-phone-overflow law0-throwaway-probe 4 -o json
      → {"ok":true, claim:{"epoch":5,"worker":null,"released_by":"law0-throwaway-probe"}}

State after: `open`, `assignee: null`, roster unchanged at 321/110/108. All six also appear in
`bp task ready --all` (1656 rows) — they are executable, not stuck.

**THE ONE REAL COST IS AN EPOCH TRAP, NOT A REFUSAL.** The claim BUMPS the epoch (3 → 4), so a
builder who reads the epoch from a roster/`bp task get` snapshot taken before claiming and then
closes on that stale integer eats a CAS failure. Close on the epoch the claim RESPONSE returns.
`release` bumps it again (4 → 5) and clears the stale assignee — a free hygiene pass on all six.

## 5. Wave 25's own filings, counted against itself

    filter[parent_id]=cloud-console-hardening-epic, ids matching w25 → 0 rows

Zero at first claim. Debrief subtracts every `cch-w25-*` filed under the PARENT from the
repayment; instrument-class rows go to `cch-instruments-epic` at create time (Law 0's filing
half) and never touch this denominator.

## 6. Side finding: D293 recurs, today

`origin/main` (`5444aa5e1`) charter ends at **D293**; the primary checkout's copy ends at
**D250**. The shared checkout is still ~43 D-rows behind, exactly the condition D293 named.
Read the charter with `git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md`.

**AND IT IS NOT JUST THE CHARTER — THE INSTRUMENT IS STALE TOO.**

    git diff --stat origin/main -- cloud/priv/static/__preview__/seal-predicate.mjs
      → 1 file changed, 116 insertions(+), 444 deletions(-)   (primary 572 lines, origin/main 900)

The predicate was run BOTH ways to make the number defensible. `origin/main` bytes, exported to
a scratch path and run with `--repo <primary>`, print the identical line:

    VERDICT-TOKEN: SEAL-PREDICATE NO-SEAL a=FAIL b=FAIL c=PASS orphans=108 considering=1 …

So `orphans=108` is not an artefact of the stale copy. But **no wave may quote a seal-predicate
run out of the primary checkout again without this diff beside it** — a 444-line deletion in the
instrument that decides the seal is a level-skip waiting to happen. Run it from `git show
origin/main:` bytes or from a worktree at `origin/main`.
