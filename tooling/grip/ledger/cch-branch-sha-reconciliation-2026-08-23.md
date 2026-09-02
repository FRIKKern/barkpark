<!-- doc-tier: cold | canonical-for: cch-branch-sha-reconciliation-2026-08-23 | budget: 600tok -->
# CCH done-set branch-SHA -> merge-SHA reconciliation — full re-derivation, 2026-08-23

> HISTORICAL RECORD (2026-08-23) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Pays criterion 0 (the table) and criterion 2 (the re-runnable recipe) of
`cch-bl-thirtyone-done-rows-cite-branch-shas`. Run by the lead session (ledger-writes packet, section C #15).
Origin/main head at run: `51a823b10d2f2ab809d5c526e373e286ca6dc7bb` (2026-08-22 23:47 +0200). Full clone (`git rev-parse --is-shallow-repository` = false), fetched first.

## The two-sided result, both halves stated

1. **The vanished-commit class is EMPTY — zero missing work.** All 248 unique non-ancestor commits cited by done rows reconcile to origin/main: 227+4 by content anchor, 13 via the gh commit->pulls association with the merge sha confirmed ancestor, 4 deliberate probe/regression shas never meant to land. Weeks of rows that LOOKED like they might point at lost commits pointed at none.
2. **219 done rows carry >=1 stale (branch-sha) citation — the class is REPRODUCING**, up from the 31(+11) this row first measured. Re-run this sweep at the next arrears pass; a reader who takes only half 1 and skips half 2 will be back here in three weeks.

## Population swept (stated per the row's own scope note)

ALL done children of BOTH epics at sweep time, membership from `bp task get <epic> -o json | .children`
(never the filter route — cch-finding-roster-tooling-contract): `cloud-console-hardening-epic` 545 done of 952,
`cch-instruments-epic` 43 done of 258 = **588 done rows**, each fetched individually with `bp task get`.
Extraction fence: hex tokens (7-40 chars, >=1 [a-f]) from `acceptance_criteria[].evidence` + `content.close_reason` ONLY.

## Census

| class | count | note |
|---|---|---|
| unique hex tokens | 1102 | across 493 of 588 rows |
| ANCESTOR of origin/main | 647 | merge shas / on-main commits — clean |
| NOT-ANCESTOR commit | 270 tokens -> 248 unique commits | the squash-chain class; reconciled below |
| NO-OBJECT | 184 | ALL non-commit noise: 101 are 16/32-hex digests+doc-revs by length; the 83 commit-like (8/12/40-hex) were checked against the GitHub commits endpoint = 0 found, with positive controls (efc70074b, dcd8c9ce...) resolving — they are UUID tails, md5 fragments, canary literals |
| tree object | 1 | noise |

**Reconciliation outcome over the 248 non-ancestor commits:** 227 LANDED by content anchor, 4 LANDED on a looser anchor (2nd pass), 13 LANDED via the gh commit->pulls association with the PR merge sha confirmed ancestor (anchor unusable: probe/fixture-heavy diffs), and 4 DELIBERATE-NON-LANDING (probe/deliberate-regression pushes cited as evidence of RUNS, not landings: 35908a194 regression proof for cch-w19-s1, d4d9144b2 + e9be79a8d throwaway CI probes, a31faa52d explicitly cited as NOT-the-tree). **ZERO missing work. The vanished-commit (unfalsifiable) class is EMPTY.**

**219 done rows carry >=1 non-ancestor citation** — the class the row measured at 31 (+11 delta) has kept
reproducing exactly as its body predicted; it remains citation hygiene, not missing work.

## Self-tests (run before trusting any line above)

Known positive: `b457db90c` (cch-w10-registration-sample-instrument) -> content anchor names `efc70074b` (PR 8252) = the row's own worked example, REPRODUCED. Negative control: `deadbeefdeadbee` -> `fatal: Not a valid object name`. gh oracle positive controls: `efc70074b`, `dcd8c9ceff0e...` both resolve.

## Re-run recipe (criterion 2)

```
git fetch origin
# 1. roster: bp task get <epic> -o json | .children -> done doc_ids; bp task get each
# 2. extract: hex tokens 7-40 (>=1 a-f) from acceptance_criteria[].evidence + close_reason
# 3. for tok: git cat-file -t; commit -> git merge-base --is-ancestor tok origin/main
# 4. NOT-ANCESTOR -> content anchor: longest added line >=25ch from git show -U0 <sha> -- <path>;
#    git log -1 -S"<line>" --format="%H %s" origin/main -- <path>  # names the landing commit; PR# from the squash subject
# 5. anchor-less -> gh api repos/FRIKKern/barkpark/commits/<sha>/pulls -> merged PR merge_commit_sha; confirm ancestor
# 6. NO-OBJECT commit-like -> gh api repos/FRIKKern/barkpark/commits/<tok>; 404 with passing positive controls = not a commit
# Self-test on b457db90c -> efc70074b and an impossible-sha control EVERY run.
```

## The two sentences owed beside standing law 1 (criterion 1 — drafted here; the charter edit needs a commit)

> Reconcile a done row's non-ancestor citation by CONTENT ANCHOR — `git log -S` on a distinctive added line names the landing commit — never by commit subject, because a squash rewrites subjects (subject matching resolved only 19 of the wave-9 sweep's 50, and after a squash the PR head is ALWAYS a non-ancestor).
> A done row citing a branch SHA is evidence of a STALE CITATION, not of missing work; the two must never be conflated — the 2026-08-23 full re-derivation found 248 non-ancestor citations and zero missing landings.

## The table: branch/head sha -> landing commit on origin/main

| cited sha | landing commit | PR | anchor path | citing done rows |
|---|---|---|---|---|
| 0025be198ca5 | 2bf39d4d386e | #9593 | cloud/lib/barkpark_cloud/accounts.ex | cch-w31-s3-role-agreement-census |
| 017170cd091f | 8af8c2adf27c (gh pulls assoc) | #10727 | — | cch-w51-bl-two-factor-and-identity-changes-leave-no-audit-trail, cch-w53-s3-audit-census-false-rationales-and-the-twofa-producers, cch-w55-s5-the-wave-54-arrears-pays-eight-rows |
| 0340117f77bc | ca5bc542941e | #10559 | cloud/priv/static/__app.test.mjs | cch-w50-s2-every-500-stops-directing-users-to-a-support-desk-that-does-not-exist |
| 05aa0e78e360 | 0a1b4d2ea53b | #9356 | cloud/priv/static/__preview__/fixtures/seal-predicate/README.md | cch-w28-s1-empty-roster-control-asserts-clause-a |
| 05f4f1119a5c | b2fb4d00e694 | #11723 | cloud/lib/barkpark_cloud/accounts/audit_event.ex | cch-w51-s3-site-rolled-back-becomes-storable |
| 06bd854c9d74 | e20740837d8a | #9848 | cloud/lib/barkpark_cloud/web/auth.ex | cch-w36-s1-crown-launch-authority-seam |
| 0792f2bb61b1 | d1d9ce3deec5 | #10649 | scripts/required-checks-verify.sh | cch-w51-s6-verify-refuses-when-it-declined-to-look |
| 07a16014d1ac | 29e793b62f43 (gh pulls assoc) | #10085 | — | cch-w40-s3-the-binding-census-gets-a-fixture-control-and-2d-stops-freezing-a-live-defect |
| 08432e64e28b | 88e3c3cb06ed | #9594 | cloud/priv/static/__app.test.mjs | cch-w31-s4-crash-blame-boundary |
| 0908062da20f | f7a87c0a5946 | #11075 | docs/ops/merge-gates.md | cch-w49-s4-merge-ledger-stops-presenting-checks-that-cannot-block-as-checks-a-pr-must-clear |
| 0da037143cf4 | a001f566390b | #9257 | cloud/priv/static/__preview__/scenarios.mjs | cch-w24-s7-three-screens-cruel-by-fixture |
| 0da65324182d | a1d27149e755 | #11438 | cloud/priv/static/__preview__/seal-predicate.mjs | cch-w64-s4-the-seal-predicate-can-read-its-own-roster |
| 0dc0cac54aa7 | 4cb1072ec230 | #9921 | scripts/registration-deadlock-sweep.sh | cch-w37-s5-the-sweep-stops-passing-on-what-it-did-not-see |
| 0df022424cdc | 9a24537df521 | #11786 | api/lib/barkpark/sites/deploy_runner.ex | cch-w67-bl-every-teardown-422-opens-by-saying-a-deploy-died |
| 0e0252ca7bc2 | 0239dd4ee662 | #11017 | cloud/lib/barkpark_cloud/registry.ex | cch-w56-s5-a-compliance-guard-nothing-in-production-can-call |
| 0e7703c039b2 | cb7aa7963348 | #9105 | cloud/priv/static/__app.test.mjs | cch-w22-s5-console-stops-asserting-false-things |
| 1023ee5b4676 | 7ad181d1969e | #9685 | cloud/lib/barkpark_cloud/notifications.ex | cch-w32-r2-notifications-withhold-branches |
| 1056c5b4b33a | dfb8baf4dc98 | #10613 | .github/workflows/console-harness.yml | cch-w51-s1-timeline-event-vocabulary-manifest-and-the-three-renderers-with-no-producer |
| 107880c57a03 | b00d793c0e20 | #10252 | cloud/test/barkpark_cloud/accounts_invitations_test.exs | cch-w44-s5-server-crux-disagreement-gets-an-elixir-pin |
| 112705fd4522 | 4c1e1859630e | #11378 | cloud/test/barkpark_cloud/web/router_sites_test.exs | cch-w63-s3-the-site-write-fence-lands-at-the-dispatcher-and-its-guard-stops-being-vacuous |
| 11458ceb7059 | 3e78048013dd | #11782 | .claude/workflows/bp-cloud-console-hardening-charter.md | cch-w47-bl-rebase-10256-union-insert-with-proven-resolution |
| 132c3472196d | 5abf841887f2 | #11292 | tooling/grip/ledger/cch-w61-s3-criteria-less-roster-pass-2026-08-09.md | cch-w61-s3-the-criteria-less-roster-pass |
| 134111f966d0 | 209ec49fb6cd | #10083 | .github/workflows/console-harness.yml | cch-w40-s1-the-refusal-default-inverts-and-three-authored-causes-converge |
| 134bfb672524 | 92ef3efd57b6 | #11288 | cloud/test/barkpark_cloud/reader_less_instrument_census_test.exs | cchi-w60-reader-less-census-derives-its-admission |
| 14987eb5c730 | 981ee6f5130f | #10851 | internal/cli/cloud/warmpool.go | cch-w54-s6-decommission-sweeps-dns-by-value-not-by-name |
| 163d94c67c6b | 25d994539afe (gh pulls assoc) | #8298 | — | cch-w11-s1-flip-behind-a-generator-that-cannot-lose |
| 16faef458851 | 4ce2354b968d | #11135 | cloud/test/barkpark_cloud/reader_less_instrument_census_test.exs | cch-w59-bl-both-census-mutation-arms-are-sole-element-brittle |
| 1a0f437c1d44 | 3f8d1e126f1b | #11014 | cloud/test/barkpark_cloud/promise_actor_manifest_test.exs | cch-w56-s2-the-clock-column-stops-being-a-constant |
| 1aac717631a8 | e141afbf8332 | #9159 | cloud/priv/static/__app.test.mjs | cch-w23-s3-site-row-second-domain-visible |
| 1b4dc14b0909 | 6546f72b4a71 | #11530 | cloud/priv/static/__preview__/font-pin.mjs | cch-w59-bl-font-pin-refuses-on-every-cloud-pr-about-one-run-in-eight |
| 1be02798c745 | a78fd4e8cc99 | #9354 | cloud/priv/static/__preview__/overflow-guard.mjs | task-ee662108818d603c |
| 1cf9250d0419 | 56d5fda63ece | #10395 | cloud/priv/static/__app.test.mjs | cch-w47-s3-archives-resurrect-stops-offering-a-member-a-destroy-tier-403 |
| 1d928b3bfae3 | 22c42b2198cb (gh pulls assoc) | #4733 | — | cch-w1-emit-marker-fence |
| 1e274650febf | 7eda0783367a | #11377 | .github/workflows/console-harness.yml | cch-w63-s2-the-console-gate-stops-naming-chrome-and-its-refusal-arm-learns-to-lose, cch-w64-s5-law-0-twelve-closes-and-three-integers |
| 1f16ecb2f2b2 | 64d924fe99f3 | #11077 | .github/required-checks.json | cch-w56-s4-the-task-gate-stops-passing-having-evaluated-nothing |
| 1f4198d32d42 | 7dd27bc9bbec | #8499 | cloud/lib/barkpark_cloud/registry.ex | cch-w12-s4-deploy-rail-measured-estimates |
| 21611a10cf8e | 4f2598801fd5 | #10447 | cloud/priv/static/__app.test.mjs | cch-w48-s3-the-github-card-stops-offering-a-disconnect-it-will-refuse |
| 234e8f800f97 | fca9ee3a71cd | #8126 | cloud/lib/barkpark_cloud/accounts.ex | cch-bl-auth-touch-unthrottled |
| 23614d5cceeb | 9b8e75f55467 | #10852 | tooling/grip/ledger/ledger-arrears-w54-2026-08-08.md | cch-w54-s7-the-ledger-arrears-pays-twenty-five-rows, cch-w55-s5-the-wave-54-arrears-pays-eight-rows |
| 247abffb27f4 | 981ee6f5130f | #10851 | internal/cli/cloud/warmpool.go | cch-w54-s6-decommission-sweeps-dns-by-value-not-by-name, cch-w55-s5-the-wave-54-arrears-pays-eight-rows |
| 24f317e83f3c | 64d924fe99f3 | #11077 | .github/required-checks.json | cch-w57-s6-exclusions-survive-regeneration-and-the-fix-can-lose |
| 258a85192ab8 | d157d098c78b | #5377 | cloud/lib/barkpark_cloud/accounts.ex | cch-w3-sse-ticket |
| 2788bb0107ad | 205a3a874826 | #8740 | cloud/priv/static/__preview__/cssom-heads.baseline | cch-w15-s2-archives-resurrect-scroller |
| 280a31c88c02 | 7907b78e9653 | #10728 | .github/workflows/required-checks-drift.yml | cch-w53-s5-guard-suite-vacuous-green-and-the-blocking-label |
| 284aae43ebe1 | 467f7e2837b0 (gh pulls assoc) | #9521 | — | cch-w30-s5-control-plane-error-shape |
| 2927e25a5748 | 3cf1285e30c9 | #9057 | cloud/priv/static/__preview__/cssom-heads.baseline | cch-w21-s1-members-roster-identity-and-remove |
| 29a7e09ead72 | abfd8dd017e7 (gh pulls assoc) | #11104 | — | cch-w58-s3-unreachable-stops-meaning-two-things |
| 29d5ad3ffc79 | 94b12757a0e7 | #11891 | .claude/workflows/bp-cloud-console-hardening-charter.md | cloud-console-hardening-epic-wave-72-log |
| 2a0b9482409d | d5d15d9ef73e | #6698 | cloud/lib/barkpark_cloud/accounts.ex | gr-bl-delivery-keyset-tiebreak |
| 2aa305943290 | 840effe8acd9 | #11711 | internal/cli/cloud_rollback_cmd.go | cch-w40-s4-the-cli-reads-the-refusal-evidence-instead-of-printing-a-bare-slug |
| 2b993514e893 | 264eae552c9b | #11831 | .claude/workflows/bp-cloud-console-hardening-charter.md | cloud-console-hardening-epic-wave-70-log |
| 2c13cc3a3a0f | 8317b8ce6c41 | #10847 | cloud/test/barkpark_cloud/lifecycle_state_manifest_test.exs | cch-w55-f1-rederive-lifecycle-manifest-after-10848 |
| 2c3dcc9d041f | 88b30a246f93 | #10018 | .github/workflows/console-harness.yml | cch-w9-console-gate-shim |
| 2c49db0088ff | 2a2b009c27cb | #10509 | cloud/lib/barkpark_cloud/billing.ex | cch-w49-s2-checkout-refuses-before-it-charges-and-the-plane-declares-its-billing-capability |
| 2cf019895a29 | 80c1984159ca | #9158 | cloud/priv/static/__preview__/overflow-guard.mjs | cch-w23-s2-account-modal-identity-bounded |
| 2e27929dc74e | 974d412caec6 | #8987 | cloud/priv/static/__preview__/overflow-guard.mjs | cch-w20-s9-attention-name-column-collapse |
| 2f36b49ceaff | d2d3cd8d3b80 | #11103 | cloud/lib/barkpark_cloud/workers/autoupdate_rollout_worker.ex | cch-w58-s2-a-refusal-is-not-a-started-run |
| 301452f20303 | 0239dd4ee662 | #11017 | cloud/lib/barkpark_cloud/registry.ex | cch-w54-bl-the-server-comment-still-asserts-env-delivery-to-the-box |
| 312d9492b43a | b22145665cff | #10510 | .github/workflows/cloud.yml | cch-w49-s3-cross-layer-mirror-guard-reads-both-sides-by-running |
| 320baf4b76aa | 08c5756bd7a1 | #4665 | cloud/priv/static/app.css | cch-w1-cssom-ci-wiring |
| 325a0d789bff | 4a26d181b8e2 | #10848 | cloud/lib/barkpark_cloud/web/router.ex | cch-w54-s2-suspension-closes-the-three-mint-and-reveal-paths, cch-w55-s5-the-wave-54-arrears-pays-eight-rows |
| 33c14b95bd63 | c6107095a562 | #9301 | cloud/priv/static/__app.test.mjs | cch-w26-s5-css-check-bp-lc-closed-alternation-paid |
| 35908a194541 | DELIBERATE-NON-LANDING (probe/regression evidence, never meant to land) | — | — | cch-w15-bl-overflow-guard-unwired, cch-w19-s1-guard-loses-in-ci |
| 35bfb21c2d58 | 08c5756bd7a1 | #4665 | cloud/priv/static/app.css | cch-w1-cssom-ci-wiring |
| 37530d6356e8 | 2e1446489801 | #10959 | cloud/lib/barkpark_cloud/billing.ex | cch-w50-s3-the-cancel-modal-promise-becomes-true-bounded-and-guarded |
| 3939116e1060 | e88f1e05c0aa | #10508 | cloud/priv/static/__app.test.mjs | cch-w49-s1-money-screen-stops-stating-numerals-it-cannot-support |
| 3ae56ee16935 | 7b5e54b5d67a | #9918 | cloud/lib/barkpark_cloud/web/router.ex | cch-w37-s2-six-refusals-name-their-authority |
| 3d2d0909c175 | 652c681686a2 | #8396 | cloud/priv/static/__preview__/scenarios.mjs | cch-w11-s3-token-revoke-shrink-oracle |
| 3d8e93d08271 | 3ea921a2d767 | #9789 | cloud/lib/barkpark_cloud/web/auth.ex | cch-w35-s1-refusal-names-its-authority |
| 3e577be4800b | f7a87c0a5946 | #11075 | docs/ops/merge-gates.md | cch-w49-s4-merge-ledger-stops-presenting-checks-that-cannot-block-as-checks-a-pr-must-clear |
| 3f72907d9b57 | 576107987528 | #6541 | cloud/priv/static/__app.test.mjs | cch-bl-overview-subscription-band-stale |
| 3fc1b9befbac | 8317b8ce6c41 | #10847 | cloud/priv/static/__app.test.mjs | cch-w54-s1-the-stop-nothing-performs-and-the-lifecycle-state-register, cch-w55-s1-format-unblocks-the-wave-54-crown |
| 4000c1329bf4 | cb6a5291075a | #12996 | cloud/priv/static/__app.test.mjs | cch-w38-s1-lifecycle-rail-authority-is-three-valued |
| 40ded39f03a2 | f50f48b83e88 | #9464 | cloud/lib/barkpark_cloud/failure_copy.ex | cch-w28-bl-capacity-arm-blames-hetzner-for-azure |
| 40ec70e2bcdb | 40097d1d2aaf | #9463 | cloud/lib/barkpark_cloud/notifications/render.ex | cch-w26-bl-deployment-failed-email-still-unhumanized |
| 40f99f9e8720 | bf58260d1d21 (gh pulls assoc) | #11102 | — | cch-w58-s1-the-identity-verdict-stops-being-discarded |
| 41a12e3ff8da | a94b79b20595 | #11338 | cloud/lib/barkpark_cloud/web/router.ex | cch-w58-followup-unavailable-reason-has-no-reader |
| 429596b7b123 | 6b82ebf1517a | #11436 | .github/workflows/cloud.yml | cch-w64-s2-the-red-aggregate-names-the-refusing-job |
| 42a135e23803 | 3df1c08306c7 | #10008 | tooling/grip/ledger/spec-gate-packet-refresh-and-roster-disposal-2026-08-07.md | cch-w39-s5-the-spec-gate-packet-is-refreshed-and-the-ledger-is-disposed |
| 438495a96205 | 156f7669db62 | #9408 | cloud/test/barkpark_cloud/domain_status_test.exs | task-3fbfff8c97b50c8f |
| 4473bdeda0dd | 142cbbf5ac29 | #9617 | templates/search-starter/lib/graph.ts | cch-w32-s4-console-gate-is-not-advisory |
| 452ee0758ae0 | 541d5d1c1f9d | #9522 | cloud/lib/barkpark_cloud/accounts/user_token.ex | cch-w30-s6-pat-membership-revoke |
| 479b8c38d4bc | ef82a20aaded | #11532 | cloud/priv/static/__app.test.mjs | cch-w66-s3-the-site-card-stops-asserting-a-deletion-it-never-observed |
| 4876d2693ccf | 60a4f90efa1b | #5306 | design/check.mjs | cch-w1-emit-marker-fence |
| 4889c544e4be | 87e8726c47a2 | #8945 | cloud/priv/static/__preview__/cssom-heads.baseline | cch-w19-s2-topbar-phone-band-620 |
| 4896e4492731 | 6e6d0624ca86 (gh pulls assoc) | #11105 | — | cch-w58-s4-domain-status-checks-the-name-the-plane-serves |
| 48de98fa7478 | f5a29922c91a | #11122 | scripts/main-gate-watch.sh | cch-w59-s3-mains-tip-carries-a-verdict-or-screams |
| 4958b757c510 | 11412247df1d | #11552 | cloud/priv/static/__app.test.mjs | cch-w63-bl-teardown-failed-has-no-console-reader-at-all |
| 4a5322ff46fb | d4575be0510a | #6539 | cloud/lib/barkpark_cloud/accounts.ex | gr-p5-session-provenance |
| 4a99cbcc7bf9 | 22f4c6f0632b | #10648 | cloud/test/barkpark_cloud/audit_vocabulary_census_test.exs | cch-w51-s4-audit-vocabulary-bidirectional-census |
| 4b989a65073f | 8c9c116c55eb | #5379 | cloud/priv/static/__preview__/scenarios.mjs | cch-w2-revoke-click-oracle |
| 4d49d82b0943 | b316419406ee | #9688 | cloud/priv/static/__app.test.mjs | cch-w31-s4-followup-retire-status0-branches |
| 4d82d63a7da2 | e4c81aa6c03e | #11074 | cloud/lib/barkpark_cloud/web/router.ex | cch-w57-s4-instance-proxy-stops-spending-the-admin-token-on-a-suspended-box |
| 4f2a0d769ccd | 386390b9bf31 | #11886 | internal/cli/cloud_site_cmd.go | cch-w70-bl-site-create-collapses-refusal-exit-families |
| 4fb84f7fee05 | e3f47c5858d1 | #8888 | cloud/priv/static/__preview__/cssom-heads.baseline | cch-w16-bl-attention-pill-detail-truncated-front-screen |
| 4fc4d065b25f | 39620dfd38d9 | #10251 | cloud/priv/static/__me_envelope_census.mjs | cch-w43-bl-me-census-onboarding-subtree |
| 526149d789d2 | 4679ed6afbbe | #9255 | scripts/console-path-escape-check.sh | cch-w25-s3-deploy-rail-fail-wrap-and-the-stated-rule |
| 53d2890a8725 | ca5bc542941e | #10559 | cloud/lib/barkpark_cloud/failure_copy.ex | cch-w50-s2-every-500-stops-directing-users-to-a-support-desk-that-does-not-exist, cch-w54-s7-the-ledger-arrears-pays-twenty-five-rows |
| 53e7e4840360 | 2fc6f23a6356 | #11709 | .github/workflows/doc-gates.yml | cch-w68-s4a-emit-manifest-regions-keyed-by-artifact-not-path |
| 552d53b84d0a | 02ab46d0f879 | #11487 | cloud/lib/barkpark_cloud/registry.ex | cch-w65-s2-the-control-plane-stops-stamping-an-unmade-check |
| 563350d77a78 | 2a4dc1f9594c | #10943 | internal/cli/cloud_status_cmd.go | cch-w56-s4-the-task-gate-stops-passing-having-evaluated-nothing |
| 57ac9c2d0911 | 42f6c1e2c46d | #9788 | cloud/priv/static/__app.test.mjs | cch-w34-s6-console-says-never-reported |
| 58f141a1aa1c | 80c1984159ca | #9158 | cloud/priv/static/__preview__/overflow-guard.mjs | cch-w24-s8-e11-can-see-the-stylesheet |
| 592a6f58e659 | c61107cc49a5 | #10557 | cloud/test/barkpark_cloud/sold_capability_manifest_test.exs | cch-w50-s1-sold-capability-manifest-and-the-two-bullets-that-fail-it |
| 5b723be98689 | 43ee848ef4fe | #10006 | cloud/priv/static/__app.test.mjs | cch-w39-s2-the-account-modal-stops-stating-a-2fa-state-it-never-read |
| 5bad63351691 | 62b5847eda5e | #9922 | cloud/priv/static/__preview__/breakpoint-sweep.mjs | cch-w34-bl-neutral-card-modifier |
| 5ddb205fb75e | 8f109bcac40c | #10646 | cloud/lib/barkpark_cloud/mailer.ex | cch-w52-s1-api-transport-leaves-the-console-and-a-manifest-reds-when-an-option-outruns-its-mechanism, cch-w52-s1-followup-api-transport-prose-residue |
| 5ec8232914e6 | 5aa485bdae55 | #11071 | cloud/priv/static/__app.test.mjs | cch-w54-s5-the-dunning-grace-clock-names-a-day-nothing-acts-on |
| 61de7c3fd474 | 6d167cf8ad2b | #9059 | cloud/priv/static/__preview__/breakpoint-sweep.mjs | cch-w21-s3-cruel-fixture-fleet-url-and-card-name |
| 63182ae7c116 | 8763f8d8db81 | #10343 | cloud/priv/static/__app.test.mjs | cch-w45-s5-two-member-reachable-rail-verbs-stop-selling-a-403 |
| 6368d7e14717 | 4327393fab2c | #10647 | cloud/lib/barkpark_cloud/workers/trial_expiry_worker.ex | cch-w52-s2-a-mute-stops-consuming-the-trial-warning-budget |
| 638b5eeb6346 | bf309b27dcd2 | #10471 | .claude/workflows/bp-cloud-console-hardening-charter.md | cch-w49-s5-the-epics-own-ledger-stops-reading-open-on-25-merged-rows |
| 64ed912a6b11 | 5d07f73e80a5 | #10853 | scripts/required-checks.test.sh | cch-w54-s8-the-guard-suite-refuses-an-absent-object-database, cch-w55-s5-the-wave-54-arrears-pays-eight-rows |
| 65b0d6591139 | 0c451e5edb07 | #9787 | cloud/lib/barkpark_cloud/registry.ex | cch-w34-s5-detail-column-is-text |
| 65f293b4097f | c7c3b803afbc | #10088 | cloud/lib/barkpark_cloud/failure_copy.ex | cch-w40-s6-the-failure-classifier-stops-naming-a-party-and-a-remedy-it-never-determined |
| 6adb57382292 | cb905aa6266a | #11784 | internal/cli/cloud_site_cmd.go | cch-w67-bl-the-cli-site-delete-receipt-flattens-every-typed-refusal |
| 6afacbbf021d | 4116674652c2 | #8944 | tooling/grip/ledger/cch-w19-guard-mutation-proof-2026-08-01.md | cch-w15-bl-overflow-guard-unwired, cch-w19-s1-guard-loses-in-ci |
| 6c3c40769220 | b348779d6b35 | #9409 | cloud/priv/static/__app.test.mjs | cch-w28-s8-never-deployed-site-row-says-so |
| 6c6c4708a2a9 | c73bbc07c417 | #9739 | cloud/lib/barkpark_cloud/health/staleness_worker.ex | cch-w34-s2-health-never-measured |
| 6ca245b028e0 | 4b5d802a1d5a | #11553 | cloud/lib/barkpark_cloud/web/router.ex | cch-w66-bl-site-delete-cascades-are-untested-and-one-is-three-days-old |
| 6ce1b6cef024 | ddfe64ab0ec9 | #8606 | cloud/priv/static/__app.test.mjs | task-1f8bcab494ac0a3a |
| 6d1c6ce2caf0 | 3bd53abdf103 | #11015 | cloud/test/barkpark_cloud/web/router_operator_test.exs | cch-w56-s3-the-operator-digest-log-can-return-its-own-rows |
| 6e82406ca91e | a23b5bc03951 | #10849 | cloud/lib/barkpark_cloud/accounts.ex | cch-w53-s4-sign-out-everywhere-ends-the-live-stream |
| 718a845c4f5b | d5bbd6c36193 | #9917 | cloud/priv/static/__app.test.mjs | cch-w37-s1-invalid-precedence-details-win |
| 71a288c49c5a | 8af8c2adf27c | #10727 | cloud/lib/barkpark_cloud/accounts/audit_event.ex | cch-w51-bl-two-factor-and-identity-changes-leave-no-audit-trail, cch-w55-s5-the-wave-54-arrears-pays-eight-rows |
| 71bfdb1e23e3 | 8ad2f0ff1237 | #11376 | cloud/priv/static/__preview__/breakpoint-sweep.mjs | cch-w61-s2-a-permanent-refusal-renders-terminally, cch-w63-s1-the-crown-lands-one-cause-one-cell-three-literals, cch-w64-s5-law-0-twelve-closes-and-three-integers |
| 724aa09aa2e6 | eeefc27dacf9 | #8742 | cloud/priv/static/__preview__/cssom-heads.baseline | cch-w15-s4-fleet-lead-column-bounded |
| 7712ea9dbb94 | 4b5d802a1d5a | #11553 | cloud/lib/barkpark_cloud/web/router.ex | cch-w66-bl-site-delete-cascades-are-untested-and-one-is-three-days-old |
| 774286bd9180 | 3df1c08306c7 | #10008 | tooling/grip/ledger/spec-gate-packet-refresh-and-roster-disposal-2026-08-07.md | cch-w39-s5-the-spec-gate-packet-is-refreshed-and-the-ledger-is-disposed |
| 777c055cd3d1 | b402c0083225 | #10650 | cloud/priv/static/__app.test.mjs | cch-w51-s2-backup-sentinel-cross-fence-pin, cch-w51-s2-followup-backupprobe-eq-nil-false-positive |
| 779327cfa0fb | da47f61aa39c | #11121 | cloud/lib/barkpark_cloud/registry.ex | cch-w58-bl-wire-site-url-writes-a-suspended-box |
| 7802bb2d54d3 | 7907b78e9653 (gh pulls assoc) | #10728 | — | cch-w49-bl-required-checks-drift-calls-its-own-job-blocking, cch-w53-s5-guard-suite-vacuous-green-and-the-blocking-label, cch-w55-s5-the-wave-54-arrears-pays-eight-rows |
| 78ce673f3993 | 7499fe85a76f | #10561 | .github/workflows/console-harness.yml | cch-w46-s7-member-actor-rendered-state-authority-sweep |
| 7a16c78f62fb | dff84fd5d323 | #8611 | .github/workflows/security.yml | cch-w13-s6-ledger-truth-closes |
| 7afc036bad91 | 5646cc7dfbf0 | #9226 | cloud/priv/static/__css_check.mjs | cch-w24-s8-e11-can-see-the-stylesheet |
| 7ca4524559b9 | 033dbe1d0267 | #9791 | cloud/lib/barkpark_cloud/notifications/delivery_reason.ex | cch-w35-s3-delivery-reason-names-what-it-observed |
| 7d3ec6886f07 | 4b5224def12e | #9956 | cloud/lib/barkpark_cloud/web/auth.ex | cch-w37-s3-scope-stops-naming-a-team-it-did-not-consult, cch-w39-s5-the-spec-gate-packet-is-refreshed-and-the-ledger-is-disposed |
| 7f1ec6eae7ed | 5acc12158dfa | #9687 | cloud/lib/barkpark_cloud/registry.ex | cch-w33-s3-console-narration-completeness |
| 7f80f4b1d973 | 5f23c963e14e | #2227 | cloud/lib/barkpark_cloud/web/router.ex | cch-w54-bl-other-admin-token-backed-paths-ignore-suspension |
| 80a6949552b0 | b0fa685fe9a3 | #9060 | cloud/priv/static/__preview__/overflow-guard.mjs | cch-w21-s4-token-reveal-readable |
| 80ede92bfe76 | bd6cf848feb3 | #9591 | cloud/lib/barkpark_cloud/notifications.ex | cch-w31-s1-delivery-reason-closed-vocabulary |
| 8134100dee30 | f73092dae5ca | #9462 | scripts/console-path-escape-check.sh | cch-w28-bl-auto-deploy-refusal-has-no-event-at-all |
| 818d2bc4b5f9 | 822322bb6251 | #10726 | cloud/test/barkpark_cloud/web/claim_payload_manifest_test.exs | cch-w53-s2-cp-worker-claim-payload-manifest, cch-w54-s7-the-ledger-arrears-pays-twenty-five-rows |
| 82eb84a3771c | 481d6f2319ec | #5308 | cloud/priv/static/__app.test.mjs | cch-bl-bands-136-reproduce, cch-w1-refetch-storm, gr-blk-console-refetch-storm |
| 85787760a1f9 | a601fae3eb8e | #5437 | cloud/config/config.exs | cch-bl-sse-ticket-mint-rate-limit |
| 8585be71258d | 156129539632 | #8498 | cloud/priv/static/__preview__/cssom-heads.baseline | cch-w12-s3-sites-card-focus-perimeter |
| 872b5d4a8593 | c488e127f022 | #10005 | cloud/priv/static/__app.test.mjs | cch-w39-s1-me-reads-are-three-valued-and-the-unknown-has-an-exit |
| 877bcb3edb0d | 5cf2b6dee81b | #10297 | cloud/priv/static/__binding_census.mjs | cch-w37-s4-binding-census-add-and-remove |
| 89855a9eb4e8 | 47c32698e8fa | #11678 | .claude/workflows/bp-cloud-console-hardening-charter.md | cloud-console-hardening-epic-wave-68-log |
| 899d8a274309 | 7137953054f3 | #9357 | cloud/priv/static/__preview__/overflow-guard.mjs | cch-w26-bl-deploy-row-siblings-unwrapped |
| 89b3c67480be | dcba89411fb1 | #9404 | .github/workflows/console-harness.yml | cch-w28-s3-console-harness-hermeticity-prose |
| 8df852dbe6f4 | 0c9130a99f82 | #5482 | api/lib/barkpark/content/mutations.ex | cch-w2-ledger-close-guard-create-ops |
| 904eca506375 | 814052259c95 | #10155 | .github/workflows/cloud.yml | cch-w42-s4-main-push-gate-failures-find-a-human, cch-w46-s4-post-verdict-job-category-unblocks-the-main-failure-reporter |
| 90ab9999a112 | 156f7669db62 | #9408 | cloud/lib/barkpark_cloud/domain_status.ex | task-3fbfff8c97b50c8f |
| 90caadd65797 | 62b5847eda5e | #9922 | cloud/priv/static/__app.test.mjs | cch-w36-s4-operator-refusal-names-its-authority |
| 91f0469989a5 | b402c0083225 | #10650 | cloud/priv/static/__app.test.mjs | cch-w51-s2-backup-sentinel-cross-fence-pin |
| 929a938f77d7 | 3a45111ab7b2 | #9297 | cloud/priv/static/__preview__/overflow-guard.mjs | cch-w26-s1-instance-track-min-content-and-a-leg-that-can-lose |
| 933ba6bacff5 | b3b8a779bcb7 | #10956 | cloud/lib/barkpark_cloud/failure_copy.ex | cch-w55-s2-archive-does-not-stop-paying |
| 935bac37ef04 | 5a73433eb038 | #8607 | cloud/lib/barkpark_cloud/failure_copy.ex | cch-w13-s2-failure-scrub-display-boundary |
| 954af4261e5f | fe63782015b7 | #9592 | scripts/console-path-escape-check.sh | cch-w30-s3-escape-ratchet-transitive-and-per-idiom-floor |
| 9706c92ab237 | 02475d0ecaf4 | #11134 | cloud/priv/static/__app.test.mjs | cch-w58-s6-the-console-states-the-binding-it-already-receives, cch-w61-s1-the-test-anchor-moves-out-of-the-tdz-window |
| 97ba7d315728 | 74b2b3d4cba4 | #11533 | tooling/grip/ledger/cch-w66-law0-nine-closes-and-three-integers-2026-08-09.md | cch-w66-s4-law-0-nine-closes-and-three-integers |
| 981ecd3557c6 | dc9920b2e080 | #9162 | cloud/priv/static/__preview__/overflow-guard.mjs | cch-w23-s6-cred-remediation-reachable |
| 99dea464157a | afe4217ab2e3 | #9228 | cloud/priv/static/__preview__/overflow-guard.mjs | cch-w24-s2-instance-detail-stops-dragging-the-page |
| 9bb965fca45a | 019fbd1d4893 | #10957 | cloud/priv/static/app.js | cch-w55-s3-four-console-assertions-the-plane-cannot-support |
| 9c29a223763e | bf1077884b86 | #11339 | scripts/console-runtime-pin-check.sh | cch-w62-s3-the-runtime-pin-stops-certifying-what-it-did-not-measure |
| 9c9c3de6b999 | 740b73705b18 | #9775 | cloud/priv/static/__app.test.mjs | task-b9ea0c5a83282c68 |
| 9fa5218ca6e0 | 467f7e2837b0 | #9521 | cloud/lib/barkpark_cloud/web/router.ex | cch-w30-s5-control-plane-error-shape |
| a0787062a51d | 019fbd1d4893 | #10957 | cloud/priv/static/__app.test.mjs | cch-w55-s3-four-console-assertions-the-plane-cannot-support |
| a31faa52dc75 | DELIBERATE-NON-LANDING (probe/regression evidence, never meant to land) | — | — | task-c04dde30f94b14c9 |
| a3945c91d4f4 | 5ae071044bc7 | #10394 | cloud/priv/static/__app.test.mjs | cch-w47-s2-the-members-own-instance-screen-stops-selling-two-403s |
| a39bf6a0f3bc | 0b5a57c3bf9d | #10393 | cloud/priv/static/__app.test.mjs | cch-w12-s1-activity-who-axis-cold-boot |
| a3e288ec8d42 | dd436fe29387 | #10448 | cloud/priv/static/__binding_census.mjs | cch-w47-s5-the-binding-census-stops-printing-numbers-nothing-can-red |
| a466a2565f79 | 7ad181d1969e | #9685 | cloud/lib/barkpark_cloud/notifications.ex | cch-w32-s1-chat-rail-stops-lying |
| a54540ba2183 | b22145665cff | #10510 | cloud/test/barkpark_cloud/billing_client_mirror_test.exs | cch-w49-s3-cross-layer-mirror-guard-reads-both-sides-by-running |
| a5ed9527c26d | cc9be0d69898 | #11716 | cloud/priv/static/__app.test.mjs | cch-w68-s5-the-recheck-and-settle-tier-stop-inventing-outcomes |
| a7c4dac12814 | 4679ed6afbbe | #9255 | cloud/priv/static/__app.test.mjs | cch-w25-s3-deploy-rail-fail-wrap-and-the-stated-rule |
| a97a8b49a122 | 42f6c1e2c46d | #9788 | cloud/priv/static/__preview__/cssom-heads.baseline | cch-w34-s6-console-says-never-reported |
| ab29c2880408 | dd436fe29387 | #10448 | cloud/priv/static/__binding_census.mjs | cch-w47-s5-the-binding-census-stops-printing-numbers-nothing-can-red |
| ad04c036a3ad | 11412247df1d | #11552 | cloud/priv/static/__app.test.mjs | cch-w63-bl-teardown-failed-has-no-console-reader-at-all |
| ad1d156d6f8e | 8317b8ce6c41 | #10847 | cloud/test/barkpark_cloud/lifecycle_state_manifest_test.exs | cch-w55-f1-rederive-lifecycle-manifest-after-10848 |
| ae6e155dc404 | 26df9e43e1c3 (gh pulls assoc) | #11106 | — | cch-w54-bl-other-admin-token-backed-paths-ignore-suspension |
| af6bd4e9ace2 | b1c80eda5c0a | #8743 | cloud/priv/static/__preview__/cssom-heads.baseline | cch-w15-s5-site-link-phone-band |
| afa4f45a845d | e88f1e05c0aa | #10508 | cloud/priv/static/__app.test.mjs | cch-w49-s1-money-screen-stops-stating-numerals-it-cannot-support |
| b0adf66f6c69 | bf309b27dcd2 | #10471 | tooling/grip/ledger/cch-w49-false-open-close-sweep-2026-08-07.md | cch-w49-s5-the-epics-own-ledger-stops-reading-open-on-25-merged-rows |
| b2461bdf9df5 | 037bb7343dd1 | #9849 | .github/required-checks.json | cch-w36-s2-protection-census-quoted-pattern-fence |
| b457db90c769 | efc70074bb8d | #8252 | scripts/lib/check-runs.sh | gr-bl-doneset-merge-sha-reaudit |
| b70bbf711965 | 3fca45081688 | #9299 | cloud/lib/barkpark_cloud/notifications/event_email.ex | cch-w26-s3-the-humanized-cause-reaches-the-inbox |
| bb8923c4957a | 3df1c08306c7 | #10008 | tooling/grip/ledger/spec-gate-packet-refresh-and-roster-disposal-2026-08-07.md | cch-w39-s5-the-spec-gate-packet-is-refreshed-and-the-ledger-is-disposed |
| bba642d0db07 | 33c9344a399c | #8255 | docs/ops/merge-gates.md | cch-w10-merge-gates-doc-drift-security-topology |
| bbfddf03cb72 | d5bbd6c36193 | #9917 | cloud/priv/static/__app.test.mjs | cch-w37-s1-invalid-precedence-details-win |
| bfbe6b20055d | 6949a1ffccc3 | #9957 | tooling/grip/ledger/cch-w38-s3-spec-gate-packet-rederivation-2026-08-07.md | cch-w38-s3-spec-gate-packet-and-roster-disposition |
| c0d771a7b7c2 | 1e7b85750c65 | #10560 | cloud/lib/barkpark_cloud/billing.ex | cch-w50-s3-the-cancel-modal-promise-becomes-true-bounded-and-guarded |
| c222e08b0bfb | 9d56c0406e22 | #9517 | cloud/priv/static/__app.test.mjs | cch-w30-bl-preview-fixture-nine-event-vocabulary |
| c2dbadfd7837 | 8ad2f0ff1237 | #11376 | cloud/priv/static/app.js | cch-w61-s2-a-permanent-refusal-renders-terminally, cch-w64-s5-law-0-twelve-closes-and-three-integers |
| c41a58eb0ef2 | 50f0de0e8c83 | #11707 | .github/workflows/console-harness.yml | cch-w65-bl-action-labels-and-actions-are-uncoupled |
| c6909469534c | fdfdcfc95514 | #11120 | cloud/test/barkpark_cloud/payload_key_set_census_test.exs | cch-w59-s1-the-gate-goes-green-by-tightening-not-loosening |
| c7f08d99380e | f50f48b83e88 | #9464 | cloud/DESIGN.md | task-79aa75e4be7a0067 |
| ce6f22b8fc56 | bf97452bb384 | #9850 | cloud/priv/static/__app.test.mjs | cch-w36-s3-me-cache-has-an-unknown-state |
| d1546e067c81 | 4864edc144a4 | #9058 | cloud/priv/static/__preview__/overflow-guard.mjs | cch-w21-s2-detail-head-320-copy-offscreen |
| d1d6de55242d | d2a721ba25a6 | #10199 | cloud/priv/static/__me_envelope_census.mjs | cch-w43-s1-corpus-mints-the-account-the-server-mints |
| d218fc84b43b | 085cc8719bd1 | #11016 | .github/required-checks.json | cch-w56-s4-the-task-gate-stops-passing-having-evaluated-nothing |
| d2d08be497a1 | 2e1446489801 | #10959 | cloud/lib/barkpark_cloud/billing.ex | cch-w55-s4-the-resume-narrowing-and-the-promise-actor-register |
| d357d0a2cfc5 | d7606341ba18 | #10725 | cloud/priv/static/__app.test.mjs | cch-w53-s1-console-stops-claiming-three-custodies-it-cannot-perform |
| d4d9144b2a05 | DELIBERATE-NON-LANDING (probe/regression evidence, never meant to land) | — | — | cch-w1-cssom-ci-wiring |
| d5fcf226aa04 | 62b5847eda5e | #9922 | cloud/priv/static/__app.test.mjs | cch-w37-s6-operator-console-stops-checking-forever |
| d62ff07918e7 | 7f8a0dd7f9c9 | #4592 | cloud/priv/static/app.css | cch-w15-bl-overflow-guard-unwired, cch-w19-s1-guard-loses-in-ci |
| d63db4d80b51 | e5087118a6f3 | #11073 | cloud/priv/static/__preview__/smoke.mjs | cch-w57-s3-terminal-verbs-state-their-residue |
| d640be552f89 | a78fd4e8cc99 | #9354 | cloud/priv/static/__preview__/overflow-guard.mjs | cch-w26-s6-theater-ready-and-new-launch-get-geometry |
| d6c0b3eb845f | f85b944c4fa6 | #10125 | cloud/lib/barkpark_cloud/web/router.ex | cch-w41-s2-v1-me-states-the-team-authority-the-gate-will-enforce |
| d7183176a47a | 7b27abc2a17c | #12068 | cloud/priv/static/__app.test.mjs | cch-w72-bl-no-fallback-friendly-sites-remainder |
| d91e9059e2fe | 839453b70614 | #11287 | cloud/test/barkpark_cloud/registry_autoupdate_test.exs | cch-w60-s4-the-plane-stops-asking-a-refuted-box-to-execute |
| da3b844e5fe5 | dcd8c9ceff0e | #8394 | .github/required-checks.json | cch-w9-stale-protection-claims |
| dc8de26e7ad6 | 2a6b673ccb5a | #6538 | cloud/lib/barkpark_cloud/web/router.ex | gr-bl-provider-reconnect-client-guard |
| ddcb14d9e3c7 | 6dfe16bac177 | #10511 | docs/ops/merge-gates.md | cch-w49-s4-merge-ledger-stops-presenting-checks-that-cannot-block-as-checks-a-pr-must-clear |
| df59b2515a6a | 909a5d742b14 | #8817 | cloud/priv/static/__preview__/breakpoint-sweep.mjs | cch-w16-s2-sweep-axes-theme-height-scenario |
| dfcad458f0a2 | 9e39c60c04de | #9920 | .github/workflows/console-harness.yml | cch-w37-s4-binding-census-add-and-remove |
| e0cf6fc23d19 | 6194262cbf53 | #9157 | cloud/priv/static/__preview__/scenarios.mjs | cch-w23-s1-status-pill-detail-token-bounded |
| e1363810726c | b91d9fd26d4a | #6540 | cloud/priv/static/app.css | gr-p5r7-ring-soft-accent-invariant |
| e136dae69cfa | 909a5d742b14 | #8817 | cloud/priv/static/__preview__/breakpoint-sweep.mjs | cch-w16-s2-sweep-axes-theme-height-scenario |
| e202e2c29d4f | edaee78edee8 | #9686 | cloud/lib/barkpark_cloud/notifications.ex | cch-w31-s8-member-self-scoped-delivery-read |
| e241c4e535f4 | 9b4e76d5c793 | #9406 | cloud/lib/barkpark_cloud/failure_copy.ex | cch-w28-s5-refused-connection-is-not-a-timeout |
| e25e2cf60fb2 | 069c6e9869ff | #5438 | cloud/priv/static/__css_check.mjs | cch-bl-css-check-states-boundary |
| e7cd2f04ebb2 | 92bf677376ed | #9659 | cloud/priv/repo/migrations/20260805210000_backfill_legacy_last_error.exs | cch-w33-s5-gate-green-discloses-nothing-ran |
| e8ee217be2f4 | da47f61aa39c (gh pulls assoc) | #11121 | — | cch-w58-bl-wire-site-url-writes-a-suspended-box |
| e9be79a8d87c | DELIBERATE-NON-LANDING (probe/regression evidence, never meant to land) | — | — | cch-w33-s5-gate-green-discloses-nothing-ran |
| eae9a796652a | 17b3aabf4538 | #11776 | .claude/workflows/bp-cloud-console-hardening-charter.md | cloud-console-hardening-epic-wave-69-log |
| eb770034c81c | d7606341ba18 (gh pulls assoc) | #10725 | — | cch-w53-s1-console-stops-claiming-three-custodies-it-cannot-perform |
| ebbded3e9941 | 02e89d934251 | #9595 | tooling/grip/ledger/cch-w31-s5-ledger-adjudication-2026-08-05.md | cch-w31-s5-ledger-adjudication |
| ed09be7b261a | f8378579f532 | #11781 | .github/workflows/doc-gates.yml | cch-w65-bl-action-labels-and-actions-are-uncoupled |
| ee321589bbe0 | d020382028e3 | #11783 | cloud/priv/static/__app.test.mjs | cch-w66-bl-site-create-renders-the-raw-slug-and-drops-the-servers-menu |
| efcc6d4617c1 | 7326aa4a854c | #11489 | cloud/lib/barkpark_cloud/accounts/audit_event.ex | cch-w63-s8-a-refused-write-leaves-a-named-audit-row-with-its-stale-criterion-corrected |
| f0ee21286e73 | c488e127f022 (gh pulls assoc) | #10005 | — | cch-w39-s1-me-reads-are-three-valued-and-the-unknown-has-an-exit, cch-w41-bl-the-second-merger-of-9955-and-10005-owes-106-and-81 |
| f1194e32451f | 695a485ce7bc | #10615 | docs/ops/merge-gates.md | cch-w51-s5-merge-gates-discloses-the-nothing-ran-green |
| f17f13aaa496 | c61107cc49a5 | #10557 | cloud/priv/static/__app.test.mjs | cch-w50-s1-sold-capability-manifest-and-the-two-bullets-that-fail-it |
| f2f16430c387 | 1e6cc29d0dad | #11870 | .claude/workflows/bp-cloud-console-hardening-charter.md | cloud-console-hardening-epic-wave-71-log |
| f626763f912e | 2de8118daf6c | #11340 | cloud/test/barkpark_cloud/web/verify_route_producer_exemption_test.exs | cch-w60-s7-the-producer-exemption-census-learns-the-third-column |
| f6352ce96842 | 87972d0dec6f | #6007 | api/.sobelow-skips | cch-w2-gate-ledger-honesty |
| f7a0aaf62fcf | 02475d0ecaf4 | #11134 | cloud/priv/static/__app.test.mjs | cch-w58-s6-the-console-states-the-binding-it-already-receives, cch-w61-s1-the-test-anchor-moves-out-of-the-tdz-window |
| f7a8cdb18bba | 8317b8ce6c41 | #10847 | cloud/test/barkpark_cloud/lifecycle_state_manifest_test.exs | cch-w55-s1-format-unblocks-the-wave-54-crown |
| f89b65b40076 | dad66869ef65 | #10156 | cloud/test/barkpark_cloud/notifications/event_vocabulary_census_test.exs | cch-w42-s5-notification-event-vocabulary-census |
| f9aa997d6e5b | a9d29985d63d | #11849 | cloud/priv/audit-actions.json | cch-w53-bl-twofa-rows-render-as-raw-slugs |
| fa38c2465218 | f020b0741507 | #10124 | cloud/test/barkpark_cloud/accounts/role_agreement_census_test.exs | cch-w41-s1-the-two-server-authority-predicates-are-proved-single |
| fa8da039efcf | 99e3ee8233d1 | #6697 | cloud/priv/static/__app.test.mjs | cch-bl-mockjs-revoke-stateless |
| fb451552e3c6 | 6d8f1f1c434f | #11437 | cloud/priv/static/__preview__/member-authority-sweep.mjs | cch-w63-s6-pin-total-scenarios-learns-to-lose |
| fc3f802edaec | 55a3831474f7 | #9742 | cloud/priv/static/__app.test.mjs | cch-w34-s1-absence-is-not-an-answer |
| fe163c9a8d7f | 8a8a2fdd7fdf | #11531 | api/lib/barkpark/tasks/close.ex | cch-w66-s2-the-autostamp-records-what-it-actually-observed |
| fe32f62d0355 | 20c623f15fac | #9741 | cloud/lib/barkpark_cloud/accounts.ex | cch-w34-s4-delivery-log-cursor-seeks |
