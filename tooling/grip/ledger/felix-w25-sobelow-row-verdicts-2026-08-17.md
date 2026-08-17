# Re-derivation recipes — Felix wave 25, per-row Sobelow verdicts (2026-08-17)

Subject: dated verdict for every open felix-w23/w24 (+ w21) Sobelow-vein row,
each with a message-text-confirmed paying commit on origin/main, the human gate
(#6057), or the documented no-op ruling. All re-derivable from the commands below.

## Anchors (run once)

    for p in 6616 7553 9411 7555 6412 7556 7557 7554 11427; do
      git log origin/main --oneline | grep "(#$p)" | head -1; done
    git show origin/main:api/.sobelow-skips | grep -vc '^#\|^$'      # 52 baseline rows
    grep -rn sobelow_skip api/lib | wc -l                            # 122 inline skips
    gh pr view 6057 --json state,title,mergedAt                      # OPEN human waiver

## PAID rows — paying commit (dated, message-confirmed)

    # 19-drifted migration → felix-w23-s1-drift-migration
    git show 27352d8c13 --stat        # #6616 2026-07-28 "migrate 19 drifted fingerprints to inline annotations"

    # 15 blobstore → felix-w23-s5-blobstore-migration, felix-w24-s1-blobstore-fifteen
    git show 5a0f4abfa4 --stat        # #7553 2026-07-29 "waive the 15 blobstore Sobelow findings with a two-clause reachability verdict"
    grep -c sobelow_skip api/lib/barkpark/media/blobstore/s3.ex api/lib/barkpark/media/blobstore/local.ex   # 5 + 4

    # 16 fenced (workspace_bundle 10 + janitor 6, + archive) → felix-w23-bl-fenced-sixteen, felix-w24-s6-fenced-sixteen
    git show 92f91f0433 --stat        # #9411 2026-08-03 workspace_bundle.ex+34 archive.ex+6 janitor.ex+14 (AFTER #6551 fence lifted)
    grep -c sobelow_skip api/lib/barkpark/tenancy/workspace_bundle.ex   # 12

    # prune 32 dead + staleness BLOCKING → felix-w23-s2-staleness-ratchet, felix-w23-bl-staleness-blocking-flip,
    #   felix-w24-s3-baseline-prune-and-flip, felix-w24-bl-staleness-script-header-stale, felix-w24-bl-staleness-line-anchor
    git show -s --format='%b' c66008ae2b | head -25   # #7555 2026-07-29 "prune 32 dead ... make the staleness ratchet blocking" (residue 31->0)
    git show origin/main:.github/workflows/security.yml | sed -n '300,335p'   # STALENESS ratchet blocking as of wave 24

    # overlap + binding ratchets (blocking) → felix-w23-bl-overlap-unbound-annotation, felix-w24-s4-annotation-binding-ratchet,
    #   felix-w24-bl-binding-transfer-needs-detector-map, felix-w24-bl-binding-census-floor,
    #   felix-w24-bl-config-hash-line-consistency, felix-w24-bl-multiclause-annotation-review
    git show c69cc0b1ee --stat        # #6412 2026-07-28 "baseline stops swallowing its own inline waivers"
    git log -1 2f9f25dd93 --format='%b' | grep -i 'Task:\|selftest\|MULTICLAUSE\|binding'   # #7556 2026-07-29 NAMES Task: felix-w24-s4-annotation-binding-ratchet; --selftest 14/14

    # merge-gates D75 / dead "no branch protection" premise → felix-w23-s3-amend-d75, felix-w24-s5-merge-gates-dead-premise
    git show f91bf276b9 --stat        # #7557 2026-07-29 "re-ground the Sobelow topology on S4, not on dead 'no branch protection'"

    # secure browser headers (Config.Headers) → felix-w24-s2-router-csp-fix
    git show 458ce20113 --stat        # #7554 2026-07-29 "set secure browser headers on :error_test instead of waiving them"

    # fresh-finding-guard --selftest → felix-w23-s4-fresh-guard-selftest
    git show origin/main:api/scripts/sobelow-fresh-finding-guard.sh | grep -n 'selftest'   # --selftest present, fail-closed on unknown arg

## NO-OP ruling (still-live on main, but flip buys nothing — S4)

    # felix-w23-bl-continue-on-error-flip, felix-w24-s7-continue-on-error-flip
    git show origin/main:.github/workflows/security.yml | sed -n '221,228p'   # continue-on-error: true STILL at :227
    # merge-gates S4: paths-filtered workflows are excluded from required checks, so the sobelow job
    # cannot be a required check regardless of continue-on-error; flipping is cosmetic. Decide: no-op / superseded.

## HUMAN GATE

    gh pr view 6057 --json state,title,mergedAt   # OPEN — "reconcile sobelow baseline — 43 drifted findings (HUMAN REVIEW: security waiver)"
    # felix-w24-bl-close-6057-superseded: Decide may close the ROW as superseded (the PR would delete 31 LIVE
    # baseline rows and buys zero blobstore coverage), but the PR itself stays human-gated. Not a builder.

## STILL-LIVE (genuine, unpaid — NOT a no-op)

    # task-felix-w21-bl-readiness-sobelow-inline: readiness.ex:42 CI.System is STILL a baseline row, never migrated inline
    git show origin/main:api/.sobelow-skips | grep readiness   # CI.System ... readiness.ex:42,6CC3DE8
    # felix-w23-bl-sobelow-transfer-proof-harness: empty-baseline twin scan not scripted as a standalone harness
    #   (binding detector-map from #7556 covers the transfer CASE, but the D141(c) twin-scan harness row is unclosed)
    # felix-w24-bl-blobstore-runtime-guard: relative_path invariant is DOCUMENTED (inline skips) but not RUNTIME-enforced
    # felix-w24-bl-stranded-sobelow-worktree: steward/felix-sobelow-durable branch land/discard — verify separately

## Prior-art cross-check (felix-w23-sobelow-prior-art-2026-07-28.md)

    # Read this wave: its recipes (inline-annotation migration, baseline reconcile #6412, human waiver, staleness ratchet)
    # are CONSISTENT with the three buckets above. No contradiction. It predates the payments (baseline was 108 then; 52 now).
