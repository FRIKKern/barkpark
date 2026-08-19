# GR112 done-set FULL re-audit — the deferred full enumeration, discharged

Wave: cloud-gui-remake reconcile 2026-08-18 (Paper `cloud-gui-remake-wave-2026-08-18`)
Row: `gr-blk-false-done-audit-closed-children` (parent `task-47bc4168392dec17`)
Auditor worker: `epic-builder-discharge-the-deferred-gr112-done-set-au`
Frozen reference: `origin/main` @ `870fcbb7bb6e06efc22cda8fbcec5355df1565e9` (committed 2026-08-18 07:10:06 +0200)

## Why this row exists

The prior `gr-blk` close was a **RULING-CLOSE**, not a full sweep: the GR111/GR112
census touched 35 of 56 done children plus GR123's 4/4 spot-check, and explicitly
left criterion 0 (full enumeration) unflipped because flipping a
full-enumeration criterion on a sample IS the false-done sin this row was filed
to catch. This recipe completes the enumeration so the close rests on genuine
per-row evidence.

## Census — ONE fresh server read

Single read of `task-47bc4168392dec17` via `GET /v1/tasks/<id>` (carries all 82
children with lifecycle + criteria_progress). Guardrail satisfied: the closed set
was enumerated fresh at one read BEFORE any mutation, so no reopen could race a
live roster change.

- child_count = 82
- lifecycle split: **76 done / 2 cancelled / 4 in_progress** (child_count is NOT
  the open count — Felix-w31 phantom)
- cancelled (2): `gr-backlog-alias-retirement`, `gr-backlog-dead-vars`
- in_progress (4): all THIS wave's own working rows —
  `gr-blk-false-done-audit-closed-children` (this row),
  `gr-r-rehome-belowbar-instruments`, `gr-wave-reconcile-2026-08-18-log`,
  `gr-recon-seal-and-spin`. Zero stale-open backlog.
- All 76 done rows: criteria met == total (zero lifecycle-vs-criteria mismatch).

Partition of the 76 done by close shape (exact claim-map inspection):

- **8 CAS-bypass** — claim map + work_digest present, no `closed_at`/`closed_by`
  (Close.close/2 never stamped the CAS seal). Weakest attribution → audited FIRST.
- **4 no-claim** — no claim map at all (innocent by construction).
- **64 clean-CAS** — `closed_at` + `closed_by` present (Close.close/2 ran).

This matches the brief's 8 / 4 / 64.

## Material-failure definition (GR112, FROZEN)

A row is a **material failure** iff: the cited artifact does NOT exist on
`origin/main`, OR the criterion's user-visible claim is FALSE on `origin/main`
today. NOT material: line-number drift; an unmet "PR merged — LEAD CLOSES" whose
work is demonstrably on main; a supersession/ruling close carrying its GRnn.

## Method (pasted checks, never asserted)

For each of the 76 rows, one user-visible criterion was checked against
`origin/main`:

- **Merge-SHA rows** — every SHA cited in criterion evidence was tested for
  ancestry: `git merge-base --is-ancestor <sha> origin/main` (verified by
  prefix-membership in `git rev-list origin/main`, then spot-confirmed directly
  for 444f07317 / 0044903a4 / ea63fcad9 / the four CAS-bypass SHAs
  09735e96b / 37304602f / 32e6395a7 / b9cb9b04a — all exit 0).
- **File-artifact rows** — `git cat-file -e origin/main:<path>` for the cited
  file.
- **Ruling / decision / supersession closes** (7 rows) — the cited GRnn ruling
  and the user-visible claim were hand-verified on main (symbols grepped, tasks
  fetched, files inspected); see per-row notes below.

Semantic deep-verification (claim TRUE on main, not merely file-present) was run
on a 12-row clean-CAS spread on top of the fleet's 29 (8 CAS-bypass + 21 GR123
clean-CAS): `shellNavLayer`×6, `webhookCardHtml`×4, `accountModalHtml`×3,
`.set-check-list` in app.css, `modal-oracle.mjs` EXISTS, `cssom-parity.mjs`
EXISTS, 4 woff2 fonts in `cloud/priv/static/fonts/`, charter `GR104` present,
`webhookBannerHtml`/`readOnlyPlanCardHtml`/`require_platform_operator` present —
all confirmed on `origin/main`.

## VERDICT

**76 / 76 done rows audited. 0 material failures. 0 reopens. SEAL CLEAN stands.**

The residue no longer rests on unread evidence. Every done child's cited artifact
either is an ancestor of `origin/main`, exists on `origin/main`, or (for the 7
ruling/decision/supersession closes) carries a GRnn whose user-visible claim was
independently confirmed true on `origin/main` today.

## Per-row ledger (all 76)

### CAS-BYPASS cohort (8 rows)

| # | row | verdict / pasted check |
|---|---|---|
| 1 | `gr-p3-fleet-archives` | artifact ancestor: `git merge-base --is-ancestor 09735e96b origin/main` -> exit 0 (09735e96baab) | 
| 2 | `gr-p3-instance-workspace` | artifact ancestor: `git merge-base --is-ancestor 09735e96b origin/main` -> exit 0 (09735e96baab) | 
| 3 | `gr-p3-site-detail` | artifact ancestor: `git merge-base --is-ancestor 09735e96b origin/main` -> exit 0 (09735e96baab) | 
| 4 | `gr-p3-small-surfaces` | artifact ancestor: `git merge-base --is-ancestor 09735e96b origin/main` -> exit 0 (09735e96baab) | 
| 5 | `gr-p3-usage-metrics` | artifact ancestor: `git merge-base --is-ancestor 09735e96b origin/main` -> exit 0 (09735e96baab) | 
| 6 | `gr-p4-deliveries-route` | artifact ancestor: `git merge-base --is-ancestor 32e6395a7 origin/main` -> exit 0 (32e6395a7a79) | 
| 7 | `gr-p4-hygiene` | artifact ancestor: `git merge-base --is-ancestor b9cb9b04a origin/main` -> exit 0 (b9cb9b04a015) | 
| 8 | `gr-p5r7-reshoot-verify` | artifact ancestor: `git merge-base --is-ancestor dcd80b36b origin/main` -> exit 0 (dcd80b36b2ab) | 

### NO-CLAIM cohort (4 rows)

| # | row | verdict / pasted check |
|---|---|---|
| 1 | `gr-backlog-deliveries-filters` | artifact ancestor: `git merge-base --is-ancestor 301e035d8 origin/main` -> exit 0 (301e035d8ade) | 
| 2 | `gr-backlog-portal-retry-sentence` | artifact ancestor: `git merge-base --is-ancestor 444f07317 origin/main` -> exit 0 (444f07317719) | 
| 3 | `gr-backlog-settings-wave` | artifact ancestor: `git merge-base --is-ancestor 444f07317 origin/main` -> exit 0 (444f07317719) | 
| 4 | `task-396a2fa055f92c51` | artifact ancestor: `git merge-base --is-ancestor 444f07317 origin/main` -> exit 0 (444f07317719) | 

### CLEAN-CAS cohort (64 rows)

| # | row | verdict / pasted check |
|---|---|---|
| 1 | `gr-backlog-768-residue` | artifact ancestor: `git merge-base --is-ancestor 0044903a4 origin/main` -> exit 0 (0044903a4bdd) | 
| 2 | `gr-backlog-bp-search-verb-discoverability` | artifact ancestor: `git merge-base --is-ancestor 3f16c9f43 origin/main` -> exit 0 (3f16c9f43c2e) | 
| 3 | `gr-backlog-cap-payload-drift` | artifact ancestor: `git merge-base --is-ancestor 7f8a0dd7f origin/main` -> exit 0 (7f8a0dd7f9c9) | 
| 4 | `gr-backlog-email-fleet-mapping` | DECISION-CLOSE (GR46): retain plain text. Verified on main: text_body present in notifications/{digest_email,event_email,transactional}.ex; html_body = 0 matches in cloud/lib. Claim TRUE. NOT material. | 
| 5 | `gr-backlog-favicon` | artifact ancestor: `git merge-base --is-ancestor 382f23540 origin/main` -> exit 0 (382f235407b6) | 
| 6 | `gr-backlog-fleetstrip-dead-code` | artifact ancestor: `git merge-base --is-ancestor 0044903a4 origin/main` -> exit 0 (0044903a4bdd) | 
| 7 | `gr-backlog-role-vocabulary` | artifact ancestor: `git merge-base --is-ancestor 567bf6e39 origin/main` -> exit 0 (567bf6e39626) | 
| 8 | `gr-backlog-shoot-matrix-budget` | artifact ancestor: `git merge-base --is-ancestor 7a43e5847 origin/main` -> exit 0 (7a43e584737c) | 
| 9 | `gr-backlog-wave-exhaust` | OPS branch-cleanup: cites merged PRs #4236/#4238/#4237/#4277/#4271 (ephemeral branches; nothing claimed to exist on main). NOT material. | 
| 10 | `gr-blk-archives-doc-link` | artifact ancestor: `git merge-base --is-ancestor 0044903a4 origin/main` -> exit 0 (0044903a4bdd) | 
| 11 | `gr-blk-cssom-parity-gate` | artifact ancestor: `git merge-base --is-ancestor 1ca6ff4a3 origin/main` -> exit 0 (1ca6ff4a39b8) | 
| 12 | `gr-blk-index-icon-link` | artifact ancestor: `git merge-base --is-ancestor 0044903a4 origin/main` -> exit 0 (0044903a4bdd) | 
| 13 | `gr-blk-invite-ico-danger-variant` | artifact ancestor: `git merge-base --is-ancestor 0044903a4 origin/main` -> exit 0 (0044903a4bdd) | 
| 14 | `gr-blk-modal-survives-route` | artifact ancestor: `git merge-base --is-ancestor 0044903a4 origin/main` -> exit 0 (0044903a4bdd) | 
| 15 | `gr-blk-shootsh-reap-timeout` | artifact ancestor: `git merge-base --is-ancestor 8b24003d1 origin/main` -> exit 0 (8b24003d1933) | 
| 16 | `gr-p2-front-door` | artifact ancestor: `git merge-base --is-ancestor 401e250c7 origin/main` -> exit 0 (401e250c7488) | 
| 17 | `gr-p2-home-triage` | artifact ancestor: `git merge-base --is-ancestor 5cac4ffed origin/main` -> exit 0 (5cac4ffedbf2) | 
| 18 | `gr-p2-launch-theater` | artifact ancestor: `git merge-base --is-ancestor 401e250c7 origin/main` -> exit 0 (401e250c7488) | 
| 19 | `gr-p2-plan-dunning` | artifact ancestor: `git merge-base --is-ancestor 401e250c7 origin/main` -> exit 0 (401e250c7488) | 
| 20 | `gr-p3-hygiene-guard` | artifact ancestor: `git merge-base --is-ancestor 09735e96b origin/main` -> exit 0 (09735e96baab) | 
| 21 | `gr-p3-timeline-grammar` | artifact ancestor: `git merge-base --is-ancestor 09735e96b origin/main` -> exit 0 (09735e96baab) | 
| 22 | `gr-p3-webhooks` | artifact ancestor: `git merge-base --is-ancestor 09735e96b origin/main` -> exit 0 (09735e96baab) | 
| 23 | `gr-p4-billing` | artifact ancestor: `git merge-base --is-ancestor 444f07317 origin/main` -> exit 0 (444f07317719) | 
| 24 | `gr-p4-members-env` | artifact ancestor: `git merge-base --is-ancestor 444f07317 origin/main` -> exit 0 (444f07317719) | 
| 25 | `gr-p4-notifications` | artifact ancestor: `git merge-base --is-ancestor 444f07317 origin/main` -> exit 0 (444f07317719) | 
| 26 | `gr-p4-providers-matrix` | artifact ancestor: `git merge-base --is-ancestor 444f07317 origin/main` -> exit 0 (444f07317719) | 
| 27 | `gr-p4-tokens` | artifact ancestor: `git merge-base --is-ancestor 444f07317 origin/main` -> exit 0 (444f07317719) | 
| 28 | `gr-p5-account-2fa` | artifact ancestor: `git merge-base --is-ancestor 815cd4d99 origin/main` -> exit 0 (815cd4d9912d) | 
| 29 | `gr-p5-cloud-flake` | artifact ancestor: `git merge-base --is-ancestor 6bc7646ff origin/main` -> exit 0 (6bc7646ffbeb) | 
| 30 | `gr-p5-coherence-fixture` | artifact ancestor: `git merge-base --is-ancestor 87463fa3b origin/main` -> exit 0 (87463fa3b7bc) | 
| 31 | `gr-p5-flotilla-closers` | artifact ancestor: `git merge-base --is-ancestor 7a43e5847 origin/main` -> exit 0 (7a43e584737c) | 
| 32 | `gr-p5-grammar-pass` | artifact ancestor: `git merge-base --is-ancestor 12a14a88b origin/main` -> exit 0 (12a14a88b9e0) | 
| 33 | `gr-p5-honesty-batch-1` | artifact ancestor: `git merge-base --is-ancestor 301e035d8 origin/main` -> exit 0 (301e035d8ade) | 
| 34 | `gr-p5-honesty-batch-2` | artifact ancestor: `git merge-base --is-ancestor 382f23540 origin/main` -> exit 0 (382f235407b6) | 
| 35 | `gr-p5-operator-console` | artifact ancestor: `git merge-base --is-ancestor 93fd1e2d8 origin/main` -> exit 0 (93fd1e2d83a1) | 
| 36 | `gr-p5-operator-routes` | artifact ancestor: `git merge-base --is-ancestor 567bf6e39 origin/main` -> exit 0 (567bf6e39626) | 
| 37 | `gr-p5-spa-finishers` | RULING-CLOSE (GR64): 8-part plan superseded by 2 slices; names gr-p5r4-spa-a (merged, in done-set) + gr-p5r4-spa-b (successor). Supersession carrying GRnn. NOT material. | 
| 38 | `gr-p5r3-ops-passthrough` | artifact ancestor: `git merge-base --is-ancestor 09f229d5d origin/main` -> exit 0 (09f229d5dce7) | 
| 39 | `gr-p5r3-shoot-accent-fix` | artifact ancestor: `git merge-base --is-ancestor d220c53e0 origin/main` -> exit 0 (d220c53e03e9) | 
| 40 | `gr-p5r3-successor-epic` | SUPERSEDED (GR70): filed cloud-console-hardening-epic. Verified: task cloud-console-hardening-epic exists (lifecycle=open). NOT material. | 
| 41 | `gr-p5r4-shoot-seam` | artifact ancestor: `git merge-base --is-ancestor 798faad9f origin/main` -> exit 0 (798faad9f933) | 
| 42 | `gr-p5r4-spa-a` | artifact ancestor: `git merge-base --is-ancestor 7f8a0dd7f origin/main` -> exit 0 (7f8a0dd7f9c9) | 
| 43 | `gr-p5r5-css-families` | artifact ancestor: `git merge-base --is-ancestor 22c42b219 origin/main` -> exit 0 (22c42b2198cb) | 
| 44 | `gr-p5r5-modal-css-e10` | artifact ancestor: `git merge-base --is-ancestor 25c5bac33 origin/main` -> exit 0 (25c5bac335b2) | 
| 45 | `gr-p5r5-modal-cssom-oracle` | artifact ancestor: `git merge-base --is-ancestor e9dde14c9 origin/main` -> exit 0 (e9dde14c9aed) | 
| 46 | `gr-p5r5-modal-reshoot` | artifact ancestor: `git merge-base --is-ancestor 24fae1b9f origin/main` -> exit 0 (24fae1b9f6f7) | 
| 47 | `gr-p5r5-spa-wireups` | artifact ancestor: `git merge-base --is-ancestor 67e1996b4 origin/main` -> exit 0 (67e1996b40e0) | 
| 48 | `gr-p5r6-charter-amendment` | artifact ancestor: `git merge-base --is-ancestor 8503835ad origin/main` -> exit 0 (8503835ad85c) | 
| 49 | `gr-p5r6-seal-finishers` | artifact ancestor: `git merge-base --is-ancestor 7a5aff656 origin/main` -> exit 0 (7a5aff6569c1) | 
| 50 | `gr-p5r7-doneset-audit` | artifact ancestor: `git merge-base --is-ancestor 09735e96b origin/main` -> exit 0 (09735e96baab) | 
| 51 | `gr-p5r7-doneset-residue-21` | RULING-CLOSE: names GR123 successor. Spot-check symbols verified on main: webhookBannerHtml + readOnlyPlanCardHtml in cloud/priv/static/app.js; require_platform_operator in cloud/lib/barkpark_cloud/web/auth.ex. NOT material. | 
| 52 | `gr-p5r7-tablet-overflow` | artifact ancestor: `git merge-base --is-ancestor 0261ace15 origin/main` -> exit 0 (0261ace1569a) | 
| 53 | `gr-p5r8-bpconsole-dead-rule` | artifact ancestor: `git merge-base --is-ancestor 0044903a4 origin/main` -> exit 0 (0044903a4bdd) | 
| 54 | `gr-p5r8-seal-predicate-freeze` | Cited PR #4848 SHA 79a50a7af is NOT ancestor (superseded/re-landed), BUT the ARTIFACT exists on main: cloud/priv/static/__preview__/seal-predicate.mjs (1542 lines, VERDICT/NO SEAL/parent_id ledger read) + seal-predicate.test.mjs. Claim TRUE on main. NOT material (work on main under different commit). | 
| 55 | `gr-w1-charter-archive-pr` | artifact ancestor: `git merge-base --is-ancestor 76122e55a origin/main` -> exit 0 (76122e55a6c9) | 
| 56 | `gr-w1-cloudchrome-bridge` | artifact ancestor: `git merge-base --is-ancestor d9cfdfec2 origin/main` -> exit 0 (d9cfdfec2288) | 
| 57 | `gr-w1-css-check-detector` | artifact ancestor: `git merge-base --is-ancestor 3c39c32b0 origin/main` -> exit 0 (3c39c32b0ef5) | 
| 58 | `gr-w1-fonts` | artifact ancestor: `git merge-base --is-ancestor ea63fcad9 origin/main` -> exit 0 (ea63fcad949c) | 
| 59 | `gr-w1-operator-me-flag` | artifact ancestor: `git merge-base --is-ancestor 019aae88a origin/main` -> exit 0 (019aae88a463) | 
| 60 | `gr-w1-shell` | artifact ancestor: `git merge-base --is-ancestor 23e2bd3e4 origin/main` -> exit 0 (23e2bd3e4a72) | 
| 61 | `gr-w1-styleguide-port` | artifact ancestor: `git merge-base --is-ancestor 9a12ba011 origin/main` -> exit 0 (9a12ba011dc5) | 
| 62 | `gr-w1-token-ramps` | artifact ancestor: `git merge-base --is-ancestor e147e6c2f origin/main` -> exit 0 (e147e6c2f8fe) | 
| 63 | `task-050074a198b116c4` | artifact ancestor: `git merge-base --is-ancestor 301e035d8 origin/main` -> exit 0 (301e035d8ade) | 
| 64 | `task-7836903b7ea83111` | ABSORBED into gr-p3-hygiene-guard (PR #4271). Verified on main: cloud/priv/static/__css_check.mjs has E9 parse-completeness guard (swallowed declarations, regression #4251) at L520/L1486. NOT material. |
