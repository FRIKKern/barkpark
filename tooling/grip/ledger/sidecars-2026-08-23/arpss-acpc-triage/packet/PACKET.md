# CLOSE PACKET — arpss/acpc open 0-met triage (2026-08-23)

Roster source: `bp task ls --all -o json` (67MB snapshot at ../all-tasks.json) cross-checked
against `bp task get api-read-path-security-sweep` + `bp task get api-controller-plug-correctness-audit`.
70 rows total: 51 arpss-*, 19 acpc-*. Per-row `bp task get` JSON in ../rows/ (claim + rev + criteria truth).
LIVE CLAIMS: NONE — every claim on all 70 rows carries released_at/expired_at
(released_by tail-d/tail-e 2026-08-20; one expired lead-loop claim 2026-08-21 on
arpss-w10-bl-shares-add-instance-wide-scope-hole).

Criterion files: `<row>__crit<N>.txt` (N zero-based), exact stored bytes, sha256 printed at build.
Rev at fetch time is recorded per row below — re-read before any close (bp-writes doctrine).

## ALREADY-DONE (7)

### arpss-docs-anchors-canonical-none-collision  (rev 1122db1809e1ec44ad6dc19acde57987)
Unmet: 0,1. `none` exempted at scripts/docs-anchors-check.sh:462 (`grep -vxE 'none'`);
landed 7ab99e49d6 (#12193, `git log -S "grep -vxE 'none'"`).
Proof: `bash scripts/docs-anchors-check.sh` → rc=0, "PASS (27 warnings)" (run 2026-08-23).
Crit1 (mutation still catches a REAL dup): attested by cch charter D845 ("a REAL planted
duplicate topic still reds it — the uniqueness guard is not disarmed").

### arpss-w8-tenancy-auth-not-total  (rev 315cc9a1fe0fce3f83e9cd67dae0f667)
Unmet: 0-4. Tenancy.Auth membership/2 normalisation seam + honest moduledoc
(api/lib/barkpark/tenancy/auth.ex:27 "Until this seam landed, the prose here claimed a totality");
test/barkpark/tenancy/auth_totality_test.exs covers nil/non-UUID/16-byte in both positions for
authorize/3, workspace_admin?/2+3, membership_role/2+3.
Landed c8cb3e35e9 (#12616) + 7a42b45576 (#12710). Both ancestors of origin/main.

### arpss-w9-bl-main-format-red-three-test-files  (rev f229572480e749ff31351a4ec8456745)
Unmet: 0-2. Landed e22dc1024a (#12778) "mix format four test files, clearing main's advisory
Format red" (compose_test.exs, media_synonyms_scoping_test.exs, search_synonyms_scoping_test.exs,
bulldocs_open_diff_scope_test.exs; 58+/10-, formatting-only).
Proof: `cd api && mix format --check-formatted` → rc=0 (run 2026-08-23).

### arpss-w10-bl-shares-add-instance-wide-scope-hole  (rev 7e49771c3e19a5eed8c7722cace336bf)
Unmet: 0-4. declarable_scope?/2 clamp at
api/lib/barkpark_web/live/studio/studio_live/handlers/shares.ex:50 (comment at :30 cites this row id);
120-line regression test studio_live_shares_scope_tenancy_test.exs.
Landed bb3b203f58 (#12929, merged 2026-08-21) — merge gate (crit4) satisfied.
NOTE: expired claim (previous_worker lead-loop, expired 2026-08-21T12:10Z) — lapsed, not live.

### arpss-w10-bl-share-link-controller-stale-membership-free-prose  (rev d2850145d01187dd86cdc4239ccf24f9)
No stored criteria. The offending "token arm is documented membership-FREE" sentence is gone;
share_link_controller.ex:109-115 now records "That claim is OVERTURNED" (workspace-scoped seat
authority, arpss-w10/D22). Landed c388238357 (#12704, `git log -S "That claim is OVERTURNED"`).
(The REMAINS-OPEN revoke-arm sentence is a DIFFERENT staleness, tracked by open task-07aec365ada35083.)

### acpc-bl-compose-test-format-red  (rev 086ce374eeef1551c4e1716a9073e591)
Unmet: 0,1. Same landing as the w9 format row: e22dc1024a (#12778).
Proof: `cd api && mix format --check-formatted` → rc=0, whole api tree (crit0's exact command).

### acpc-bl-ets-bound-class-census-residues  (rev aa74bd52cbd4dc3f83820b1de619adc6)
Unmet: 0-2. Crit0: both cloud-limiter sweep bound-resets fixed by 8598c4efe7 (#12628,
strictly-older guard; sibling acpc-w3-cloud-sweep-guard-strictly-older done 7/7).
Crit1: boot-time creation exists since dbcb128880 (#9613) at application.ex:21
(init_graph_corpus_slots); the retained lazy ensure at tasks_controller.ex:1469-1483 carries the
recorded residual-hazard rationale (test-VM re-boot race, rescue ArgumentError).
Crit2: the corrected census is recorded in the acpc charter's four-mode table
(.claude/workflows/api-controller-plug-correctness-charter.md, "Naming modes 2,3,4 closes the class").

## REFUTED (1)

### arpss-w8-bl-router-claims-a-bp-share-cli-that-does-not-exist  (rev a07e5a715022fa176dd8ee340aa5903b)
Unmet: 0,1. POSITIVE CONTRADICTION: the `bp share` CLI EXISTS and is registered in the
capabilities manifest — noun "share" at api/lib/barkpark/plugins/capabilities.ex:642, verbs
share.ls/share.add(/rm) at :1895-1910, landed 9c02def466 "feat(sharing): `bp share` CLI +
admin /v1/shares CRUD (P4b)" dated 2026-06-09 — BEFORE the w8 wave filed this row.
Live proof: `bp share --help` prints the add/ls/rm verb table (manifest-driven, run 2026-08-23).
Crit0's own OR-arm ("the command exists and is registered in the capabilities manifest") is satisfied;
router.ex:2270's claim is TRUE. Filer likely ran a stale bp binary (bp-cli-freshness class).

## SUPERSEDED (1)

### acpc-bl-quota-toctou  (rev 12d03e78575806181197ba3f3a82dd46)
Unmet: 0. Successors: acpc-w2-quota-toctou-demonstration (DONE 10/10) demonstrated the
over-admission — landed d99cb95d0f (#12580) whose commit message states the run evidence
("INSERT 0 1, final count 4") "lives on task acpc-bl-quota-toctou"; the remaining FIX surface is
owned by open sibling acpc-bl-quota-batch-overshoot-unbounded (Quota.within_quota? at
api/lib/barkpark/tenancy/quota.ex:70 is still count-then-compare — deliberately, per the wave's
"refusal is the deliverable" ruling).

## DUPLICATE (flag only — no action recommended)

- arpss-w8-bl-uuid-or-nil-docstring-names-wrong-error overlaps
  arpss-w9-bl-castError-500-folklore-comment-sweep (repo.ex:16 is one of the ~15 folklore sites;
  its verbatim twin task-3158c3be89815848 is already cancelled). Both remain REAL WORK until the
  sweep runs; flagged so one close discharges the other's site list.
