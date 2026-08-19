# Felix done-set audit — V1: decide-closed 0/N zero-evidence capability re-derivation

Verifier: V1-decide-closed-zeroN-capabilities. origin/main = 3ddc00a0c12a00095ba27fafe25f2d68fa38359c (fetched 2026-08-18).
Scope: the 9 rows felix-decide-w26/w27 closed 2026-08-17 at 0/N with zero stamped evidence.
Question per row: is the claimed capability present on origin/main (landed via a sibling slice whose PR is an ancestor), or a genuine false-done?

VERDICT: 8 PASS, 1 FAIL (felix-w24-bl-config-hash-line-consistency — proven false-done, warrants reopen).

## Re-derivation recipes (one command block per row)

### 1. felix-w23-s5-blobstore-migration — PASS
Capability: 15 blobstore Sobelow findings migrated to inline annotations, removed from baseline.
    git show origin/main:api/lib/barkpark/media/blobstore/local.ex | grep -n 'sobelow_skip'   # 4 annotations (put_file/put_bytes/delete + module)
    git show origin/main:api/lib/barkpark/media/blobstore/s3.ex | grep -n 'sobelow_skip'       # 5 annotations
    git show origin/main:api/.sobelow-skips | grep -c 'blobstore'                              # 0 — none remain baselined
    git merge-base --is-ancestor 902d2a8936 origin/main && echo ANCESTOR                        # #12039 blob-path seam, ancestor

### 2. felix-w23-bl-fenced-sixteen — PASS  (paying commit #9411 = 92f91f0433, ancestor)
    git grep -c sobelow_skip origin/main -- api/lib/barkpark/tenancy/workspace_bundle.ex        # 12
    git grep -c sobelow_skip origin/main -- api/lib/barkpark/tenancy/workspace_bundle/janitor.ex # 5
    git show origin/main:api/.sobelow-skips | grep -c 'workspace_bundle\|janitor'               # 0 — migrated out
    git merge-base --is-ancestor 92f91f0433 origin/main && echo ANCESTOR

### 3. felix-w23-bl-bundle-member-guard — PASS  (paying commit #11855 = 62f5ff7d48, ancestor)
Capability: assert_member_tables!/1 refuses any manifest table outside the live Catalog-derived member set, before any write.
    git show origin/main:api/lib/barkpark/tenancy/workspace_bundle.ex | sed -n '547,575p'       # defp assert_member_tables!/1 raises InvalidBundleError
    git show origin/main:api/lib/barkpark/tenancy/workspace_bundle.ex | sed -n '373p'            # called before import loop (line 373)
    git merge-base --is-ancestor 62f5ff7d48 origin/main && echo ANCESTOR

### 4. felix-w23-bl-overlap-unbound-annotation — PASS  (paying commit #7556 = 2f9f25dd93, ancestor)
Capability: binding ratchet — reds on annotation inside a body / misspelled / multi-clause-displaced; --selftest; wired blocking.
    git show origin/main:api/scripts/sobelow-inline-overlap-check.sh | grep -n 'binding\|MISSPELL\|MULTI-CLAUSE\|selftest'
    git show origin/main:.github/workflows/security.yml | sed -n '343,350p'                     # selftest + run, in blocking sobelow-inline-overlap job
    (cd api && bash scripts/sobelow-inline-overlap-check.sh --binding)                          # "PASS: every sobelow annotation is bound ...", exit 0
    git merge-base --is-ancestor 2f9f25dd93 origin/main && echo ANCESTOR

### 5. felix-w23-bl-staleness-blocking-flip — PASS  (paying commits #7555 = c66008ae2b + #11427 = 4ca033f502, both ancestors)
Capability: blocking baseline-staleness ratchet; continue-on-error removed from the staleness step.
    (cd api && bash scripts/sobelow-baseline-staleness-check.sh)                                # "PASS: every checkable baseline entry ...", exit 0
    git show origin/main:.github/workflows/security.yml | sed -n '388,389p'                     # staleness step has NO continue-on-error (blocking)
    git merge-base --is-ancestor c66008ae2b origin/main && git merge-base --is-ancestor 4ca033f502 origin/main && echo BOTH-ANCESTOR

### 6. felix-w24-bl-staleness-line-anchor — PASS (caveat: documented supersession)
The blocking staleness ratchet exists and greens (same proof as row 5). The row's stricter ideal (remove line-anchoring / AST-rebind, mutation-proven) was NOT built — the check is still line-anchored — but the close_override documents the pragmatic resolution (PAID via #7555 make-blocking + #11427 follow-shifted-lines, D164). Documented judgment call, not a fabricated done. Not a false-done.

### 7. felix-w24-s6-fenced-sixteen — PASS  (paying commit #9411 = 92f91f0433, ancestor)
Same 16 fenced annotations as row 2 under the D153 comment-only precedent. Same proofs.

### 8. felix-w24-bl-config-hash-line-consistency — FAIL (proven false-done — reopen)
Claimed capability: a check that recomputes each baseline row's fingerprint from its declared type/source/file/line and REDS when it disagrees with the stored hash, COVERING Config.* / Vuln.* rows that the staleness ratchet structurally SKIPS; mutation-proven; runs in the advisory sobelow job.
Proof of ABSENCE:
    (cd api && bash scripts/sobelow-baseline-staleness-check.sh) 2>&1 | grep SKIP
      # SKIP  Config.CSRF — whole-file/router finding, no per-line anchor to check
      # SKIP  Config.HTTPS — whole-file/router finding, no per-line anchor to check
      # "checked 45 of 52 baseline entries (7 skipped: no per-line anchor)"  — the staleness ratchet EXPLICITLY does not cover this class
    git show origin/main:api/.sobelow-skips | grep -c 'Config\.'                                # 7 live Config.CSRF(6)+Config.HTTPS(1) rows — non-empty target set
    git show origin/main:api/scripts/sobelow-baseline-reconcile.sh | sed -n '60,90p'            # regenerates+diffs baseline but only UPLOADS an artifact for human review; never exits nonzero on a diff
    git show origin/main:.github/workflows/security.yml | sed -n '223,227p'                     # the sobelow job hosting reconcile is continue-on-error:true (advisory — cannot red)
No sibling slice built a red-on-fingerprint-disagreement check; no open task re-files it. Closed at 0/3 with NO close_reason and NO close_override. The gap (a dead Config.* baseline row indistinguishable from a live one) remains unguarded on main. Low severity (defense-in-depth over an already-narrow class) but a genuine false-done.
Reopen recipe: bp task stage felix-w24-bl-config-hash-line-consistency open  (keeps the claim), correction note: "Audit V1: 0/3 close carried no evidence; capability absent on origin/main 3ddc00a0 — staleness ratchet SKIPS Config.*/Vuln.* (proven), reconcile is advisory-only (continue-on-error), no red-on-fingerprint-disagreement check exists. Reopened per proven evidence failure."

### 9. felix-w24-bl-multiclause-annotation-review — PASS (caveat: mechanical substitute)  (#7556 = 2f9f25dd93, ancestor)
The literal deliverable is a recorded clause-by-clause human review (process artifact, not code). The safety property it sought — no multi-clause annotation silently waives an unreviewed sibling clause — is enforced mechanically by w24-s4's MULTI-CLAUSE predicate in the binding ratchet, which greens on main:
    (cd api && bash scripts/sobelow-inline-overlap-check.sh --binding)   # "PASS: every sobelow annotation is bound to the def its author wrote it for" (106 annotations), exit 0
Mechanical guarantee present; not a false-done.
