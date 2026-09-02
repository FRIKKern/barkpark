# EXECUTABLE STAMP PACKET — section A of triage-cch-agent/packet/ledger-writes.md
Prepared 2026-08-22T23:24Z (UTC) against the LIVE board. Board is multi-session and moved
massively since the four rows were authored — re-read any denominator immediately before acting.
CLI: use `./dist/bp` (cli dev, commit 1dc9a1ba44, build 2026-08-22) — it CONTAINS #13006
(70ff34f9fd, "declare --merge-gated"). The shared `~/.local/bin/bp` (commit 6f724edfd8,
build 2026-08-20) PREDATES #13006 and is the stale binary that mishandles --merge-gated. Do not use it.
Only CLI commit after dist/bp's build is 98f6eca6b8 (cloud_deploy_census_cmd only — irrelevant).

Charter corpus = .claude/workflows/bp-cloud-console-hardening-charter.md (NOT bp-cloud-epic-charter.md,
which is a retired 38-line index with ZERO decision ids). Word-boundary grep counts there:
D63:3 D105:17 D172:14 D317:4 D325:3 D334:4 D465:1 D490:5 D745:8 D892:2 — negative control D99999:0.
D766 (line 1235) corrects D745: cch-w58-s2's true pre-close ratio was 3/8, not 6/8.

## THE ONE LIVE STAMP+CLOSE (row 1 family — everything else in row 1 is already executed)

### task-78c7fdb9783e3459  (full id, verified by round-trip `bp task get task-78c7fdb9783e3459`)
open, claim: none (fresh claim needed; epoch comes from THAT claim), 2/3.
Parent: cloud-console-hardening-epic → closing pays THIS epic's live denominator.
- Stamp criterion index **0** (zero-based; boards would call it 1).
  Exact stored text: `task-78c7fdb9783e3459__crit0.txt` in this dir — 191 bytes,
  sha256 8b6f7bfcba4d8beac625ed7d3604a5f01385fa444886236ca0f9230145497f00.
  NOT a merge-gate by stored flag or prose fallback (no MERGE-GATED wording) → `--merge-gated` NOT needed here.
- Merge sha that pays it: **8be3dedea900146e653d395c4bea0bcbd35803b9** — PR #10087
  "fix(cloud): seven route-table rows stop advertising a tier their body refuses",
  `git merge-base --is-ancestor` YES of origin/main.
- Second, ancestry-independent proof:
  `git log -S 'performs a post-guard elevation' --format='%h %s' -- cloud/test` names exactly
  `8be3dedea9` (the squash landing commit); and `git grep -n "post-guard" -- cloud/` hits live at
  cloud/test/support/router_tier_lens.ex:10 (elevate/2 defined :258, called :221) and
  cloud/test/barkpark_cloud/web/router_moduledoc_table_test.exs:24,:134,:273,:393.
- Criteria 1 and 2 are ALREADY met with PAID-BY-#10087 evidence (someone stamped them since w42-bl was written).
- Stamping index 0 makes 3/3 → **the close COMPLETES the row**. Sequence:
  claim → stamp 0 (`--met --evidence … --criterion-text "$(cat task-78c7fdb9783e3459__crit0.txt)"`) → close done on that claim's epoch.

## ROW 2 — cch-w62-bl-the-law-0-repayment-nineteen-located-rows (open 0/6, unclaimed)
Of its 19: **ALL 5 merge-gated paid rows are already closed** (verified done on live roster:
cch-w57-s5-the-dns-sweep-cannot-silently-degrade 7/7, cch-w58-bl-wire-site-url-writes-a-suspended-box 11/11,
cch-w59-s1-the-gate-goes-green-by-tightening-not-loosening 9/9, cch-w59-s3-mains-tip-carries-a-verdict-or-screams 9/9,
cch-w55-f1-rederive-lifecycle-manifest-after-10848 11/11). c1's target
cch-w54-bl-the-server-comment-still-asserts-env-delivery-to-the-box is done 2/2. → c0/c1 work is GONE.

**REMAINING: 7 of the 13 instrument moves.** Six were closed in place without moving
(cch-w41-bl-a-standing-instrument-resolves-open-merge-gated-criteria done 0/4,
cch-w32-bl-roster-false-open-sweep done 0/5, cch-w38-bl-w37-s1-successor-is-an-unpublished-draft done 3/3,
cch-w47-bl-four-merged-round-1-rows-all-need-a-re-claim-not-just-one done 0/5,
cch-w48-bl-the-remaining-lapsed-claim-arrears-epic-wide done 0/4,
cch-w56-bl-six-free-closes-await-a-lead-attestation done 0/5) — moving a done row pays no live
denominator; whether to move them anyway for lineage is the lead's ruling.
The 7 still-open, BODY-RE-READ (bodies fetched in full this session, all instrument-class,
none names a person-reachable console surface):
  1. cch-w44-bl-init-wiring-is-unpinned                                   (open 0/3; body self-declares instruments parent)
  2. cch-w28-bl-orphans-swallows-the-disclosed-considering-row            (open 0/3; seal-predicate residue bug)
  3. cch-w34-bl-false-open-sweep-instrument-fails-silent-empty            (open 0/7; sweep instrument defect)
  4. cch-w31-bl-two-rows-invisible-to-every-ledger-instrument             (open 0/4; census blindness)
  5. cch-w42-bl-two-open-drafts-have-no-published-twin                    (open 0/2; draft hygiene)
  6. cch-w59-bl-nine-live-draft-rows-inflate-the-roster-and-pay-zero      (open 0/5; draft hygiene)
  7. cch-w60-bl-38-live-rows-have-no-acceptance-criteria-at-all           (open 0/3; criteria-less census)
Move verb: `./dist/bp task move <id> cch-instruments-epic` (POST /v1/tasks/<id>/move; no claim needed;
D317: silently accepts a never-published destination — destination verified PUBLISHED and live here).
**Destination pre-move roster, read 2026-08-22T23:24:49Z: cch-instruments-epic = 258 children
(208 open / 43 done / 7 cancelled).** Post-move assert ALL 7 PRESENT there (expect 265 if nothing
else moves) AND absent from cloud-console-hardening-epic — never the orphan delta.
Source epic at same read: 952 children (545 done / 329 open / 77 cancelled / 1 considering; live=329).
c5 ("cch-w58-s2 is NOT closed on its merge gate") is **ALREADY VIOLATED** — see row 4.
w62 itself: after the 7 moves, close with close_reason recording: c0/c1 executed by later waves,
7-of-13 moves executed now + 6 pre-closed in place, c5 violated by an intervening close (named), and
the two-integer move/close report. Rider note: cch-w42-bl-two-open-drafts (#5 above) and
cch-w59-bl-nine-live-draft-rows (#6) are DISTINCT populations (2 no-twin drafts vs 9-draft hygiene) —
verified from both bodies; move both, cancel neither as a twin.

## ROW 3 — cch-w28-bl-w22s7-split-stamps-never-landed-and-c9-kill-is-refuted (open 0/3)
      + rider cch-w29-bl-w22s7-stamp-set-and-two-stale-open-rows (open 0/6)
**NO STAMPS ARE EXECUTABLE ANYMORE — drop the D325 stamp set.** Target
cch-w22-s7-cruelty-ledger-effective-caps-and-classes is **done at 0/16**, closed BY THE LEAD
2026-08-23: close_reason "PART-2 CLOSE, cch-* zero-met shard … VERDICT: SUPERSEDED … adjudicated in
ledger + split into three cc…; All criteria closed over, none flipped." A done row cannot be claimed,
and stamps are holder-only + epoch-fenced → indices 5,6,7,11,13 (D325's C6/C7/C8/C12/C14) and the
--miss notes on 14/15 can never land. Remedy: close w28 and w29 with close_reason citing that
2026-08-23 supersession close.
**LIVE RESIDUE to carry into the close_reason, not silently dropped:** w29 c4's two falsehood rows
are STILL OPEN with 0 criteria each — task-fbdf8011a1721236 (parent task-2ac1f95237c4a8e5) and
cchi-w25-bl-live-protection-requires-two-while-the-spec-declares-four (parent cch-instruments-epic).
Both still assert "live protection requires TWO contexts" (it requires FOUR). Either close/re-scope
them in the same pass or name them as surviving residue. FLAGGED, not recommended for cancel.

## ROW 4 — cch-w77-bl-w58-s2-flags-reflect-withdrawal (open 0/2)
**THE FLIP IS DEAD ON TWO INDEPENDENT WALLS — the remedy is the close_reason/evidence note.**
(a) D745 (charter :1214, verbatim): "the ledger refuses a met:true → met:false patch, so read this
evidence, not the flag". (b) The target cch-w58-s2-a-refusal-is-not-a-started-run is now **done 8/8**,
close_reason "Merged as PR #11103." — closed ON its merge gate, against w62-c5's explicit prohibition
and w77-c1's "remains OPEN" requirement. Criteria 0-3 each still carry "[WITHDRAWN BY WAVE REVIEW
2026-08-09 — NOT MET ON THE FINAL BRANCH loop-epic/an-http-409-stops-being-recorded-as-a-su-1-…]" in
their evidence while met stays true.
Ratio correction: the lead's remembered 7/8→6/8 is D745's figure; **D766 corrected it to 3/8
pre-close** (criteria 0,1,2,3 all withdrawn), so the true as-closed ratio is **4/8** (4-7 legitimately
met incl. the merge gate). Remedy: append a note to cch-w58-s2's close_reason/evidence stating true
ratio 4/8 with the four withdrawn indices, then close w77 with close_reason naming both walls and the
intervening close. Its c0/c1 as written are unfulfillable — do not fight the wall.
**Rider flag:** cch-w61-bl-cch-w58-s2-carries-four-criteria-its-own-review-declared-false (open 0/4,
same epic) covers the same defect — reconcile its disposition WITH w77's in one ruling. Flag only.

## ROW 1's own close + riders (verify-then-rule, no stamps)
cch-w42-bl-twelve-paid-rows-await-the-lead-stamp (open 0/6): ALL 12 enumerated rows verified done on
the live roster (w37-s1 10/10, w37-s2 10/10, w37-s4 12/12, w37-s6 10/10, w39-s4 10/10, w39-s5 11/11,
w40-s1 13/13, w40-s5 10/10, w40-s6 11/11, w41-s1 9/9, w41-s2 11/11, w41-s3 10/10), plus D490's two
(w42-s5 10/10, w42-s1 11/11). Companions: task-ed706f4e1c616f89 done; cch-w38-bl-w37-s1-successor
done 3/3; drafts.cch-w41-s3 already cancelled per its own amendment 4.
**DROPPED: task-fda5b6f19f1e06c9** (open 0/2, parent cch-instruments-epic) — NOT stampable: both its
criteria were REWORDED BY THE LEAD 2026-08-22 into narrowed, still-unbuilt CODE work (a new
site-read-token clause keyed on site-deploy.sh bytes + re-pointed probe). w42-bl's "close it under
the instruments denominator" is overtaken; leave it to builders.
Close w42-bl with close_reason: superseded row-by-row (12 done + 2 D490 + companions), one residual
executed via task-78c7fdb9783e3459 above, fda re-scoped 2026-08-22. Whether its criteria 0/2/3/5's
exact terms (denominator quoted at execution, evidence audit of how the closes were stamped) were
honored by the intervening closers was NOT verified here — close over them, don't flip them.
- Rider cch-w41-bl-six-merge-gated-rows-are-paid-and-await-a-lead-stamp (open 0/4): its 6 targets are
  a strict subset of w42-bl's 12, all done. Genuinely covered → close with supersession reason.
  NOT a nonexistent-twin cancel — both rows verified live and distinct. Flag only.
- Rider cch-w58-bl-thirty-two-lapsed-claims-and-twelve-unfinished-rows (open 0/4): **NOT a duplicate
  and NOT covered.** Different population (claimed-partway rows with NO merged PR). Verified still
  live on the roster: cch-w50-bl-* (3 rows open 0/5,0/5,0/6), cch-w42-s2 open 9/10,
  cch-w14-bl-site-open-phone-overflow open 3/5, cch-w32-bl-delivery-log-* (2 open),
  cch-w37-bl-* (2 open incl. 1/7), cch-w39-s2-fu open 0/3 — and 7 OPEN drafts.* shadow rows
  (3 zz-p probes, 2 w64-s5 law-0 drafts, drafts.zz-probe-labelspine-64, drafts.task-fe3eb44ff42410c5).
  Its triage (c0-c3) remains real work. DO NOT close as a rider of row 1. Flag: keep open (or hand to
  a triage wave); note w59-bl/w60-bl moves above shrink its draft/criteria-less overlap.

## Execution order that keeps every denominator honest
1. task-78c7fdb9783e3459: claim → stamp crit 0 → close done (one live-row repayment, this epic).
2. The 7 moves → assert destination roster (expect 258→265) + absence from source.
3. cch-w58-s2 close_reason note (true ratio 4/8) → close w77 with the two-wall reason.
4. Close w28 + w29 citing the 2026-08-23 supersession; name the two live falsehood rows.
5. Close w62 (two integers: MOVES=7, CLOSES=1-this-pass), then w42-bl, then w41-bl.
6. w58-bl stays OPEN — not covered.
Every close needs a fresh claim first (all claims read null); the epoch is the one THAT claim returns.

## ADDENDUM 2026-08-23 — the before/after census, measured (coordinator's request)
Method: `git archive <sha> cloud/test/.../router_moduledoc_table_test.exs cloud/lib/.../router.ex | tar -x`
into scratchpad extracts (main checkout untouched, no worktree, no git writes); run with plain
`elixir` + an ExUnit runner that `System.halt(2)`s on failures (first runner draft returned rc=0 on a
1-failure run — ExUnit.run() does NOT propagate; fixed before any rc below was quoted). All output
captured `out=$(cmd 2>&1); rc=$?`. The census is a pure DB-free source parse (its own moduledoc says
so); no app compile needed. Raw logs: census-before.out / census-after.out / census-cross.out in
`../` (stamp-packet-agent/).

  BEFORE  8be3dedea9^ (= 209ec49fb6):  rc=0, 6 tests 0 failures
          163 examined / 162 resolved / 1 unresolved-consented   (user|admin subset: 112)
  AFTER   8be3dedea9:                  rc=0, 7 tests 0 failures
          163 examined / 162 resolved / 1 unresolved-consented   (user|admin subset: 108)

**HONEST FINDING: the split triple is BYTE-IDENTICAL before and after.** The criterion's named
instrument (the split pair) cannot demonstrate the widened lens changed the outcome — the resolver
resolves the same 162 rows on both sides; what changes is WHICH TIER each resolves to (user|admin
subset 112 → 108; the 7 fixed rows now resolve to admin/admin(d)).

**The discriminating run, included so the stamp is real:** the AFTER lens over the BEFORE router
(cross-extract) — rc=2, "7 tests, 1 failure", the census test itself red, naming EXACTLY the seven
lying rows: POST /v1/go-live, POST /v1/launch, POST /v1/resurrect, DELETE /v1/env-vars/:id,
POST /v1/env-vars, DELETE /v1/fleet/supports/:id, POST /v1/fleet/supports — each
`doc=user code enforces=admin(…)`. Same lens, green on the fixed router (AFTER run above). That is
the lens-can-lose proof: the widened resolver detects on pre-fix bytes what the BEFORE lens
(6 tests, 0 failures on the same bytes) could not see.

Suggested stamp evidence line for crit 0 (splits as asked + the discriminating cross):
  "PAID BY #10087 (8be3dedea900146e653d395c4bea0bcbd35803b9, ancestor of origin/main). Census re-run
  from git-archive extracts, plain elixir, halt-on-failure runner: BEFORE 8be3dedea9^ rc=0 —
  163 examined/162 resolved/1 consented (user|admin 112); AFTER 8be3dedea9 rc=0 — 163/162/1
  (user|admin 108). Split triple identical by construction (the lens re-tiers rows, it does not
  change reachability); outcome change proven by cross-run: AFTER lens on BEFORE router rc=2,
  7 tests 1 failure, red names the exact 7 rows doc=user/enforces=admin. Resolver diff:
  git log -S 'performs a post-guard elevation' names 8be3dedea9; elevate/2 live at
  cloud/test/support/router_tier_lens.ex:258."
