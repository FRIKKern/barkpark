# Felix done-set audit — V4 SHA-census reconfirm + two ledger warts (2026-08-18)

Re-derivation recipes for the V4 verifier findings on the Felix pristine done set
(epic task-96a908af98698118, 127 done children). Read-only audit; no code touched.

## R1 — Authoritative #PR→mergeCommit ancestry (defeats the grep-subject proxy)

The prior census matched `(#NNNN)` in `origin/main` log subjects. This re-derives the
same verdict authoritatively for a stratified 15-row sample of the 109 PR-citing done
rows plus the 3 absent PRs' decisive substitutes. Every MERGED sampled PR resolves to a
merge commit that IS an ancestor of origin/main (15/15). Re-run:

    git fetch origin --quiet
    for pr in 1577 672 2869 2956 2954 3038 3398 3435 5714 5578 5778 5920 \
              12040 11855 11427 7555 11833 11852 11853 12071 12132 6616; do
      mc=$(gh pr view $pr --repo FRIKKern/barkpark --json mergeCommit \
             -q .mergeCommit.oid)
      git merge-base --is-ancestor "$mc" origin/main \
        && echo "PR#$pr $mc ANCESTOR" || echo "PR#$pr $mc NOT_ANCESTOR"
    done

Substitutes confirmed: #6616 → 27352d8c13d8 ANCESTOR; #11853 → b10593ab9440 ANCESTOR.
Absent PRs (no merge commit): #12037 CLOSED, #6551 CLOSED, #12147 OPEN — each cited
alongside a landed sibling (rows felix-w26/w27 also cite #11853/#12071/#12132, all
ancestors), so no orphan citation.

    gh pr view 12037 --repo FRIKKern/barkpark --json state   # CLOSED
    gh pr view 6551  --repo FRIKKern/barkpark --json state   # CLOSED
    gh pr view 12147 --repo FRIKKern/barkpark --json state   # OPEN

## R2 — Phantom-citation row: felix-w29-bl-asset-schema-nil-redaction (D204 on open #12147)

Row is a REFUTED close (2/2). Its cited D204 lives on OPEN PR #12147 (absent from main),
BUT its evidence rests on CODE that IS on main, not on the decision label. Capability
confirmed present:

    git show origin/main:api/lib/barkpark/content/envelope.ex | sed -n '148,162p'
    # nil caller => redact_by_field_visibility(env, schema, %CallerContext{}, owner)
    #   = most-restrictive anonymous (public-only). :internal sentinel = full content.
    git show origin/main:api/lib/barkpark/content/envelope.ex | sed -n '179,196p'
    # drop_field?: FieldCipher.encrypted?(value) -> true  (schema-INDEPENDENT drop)
    # raw_fields(nil) -> [] (line 310); undeclared field -> public (legacy parity)
    git show origin/main:api/lib/barkpark/media/delivery/asset_response.ex | sed -n '108,125p'
    # asset_payload threads caller_context(conn); asset_schema scoped to doc OWN tenant

Verdict: STAYS DONE. A nil schema does not redact declared-private fields because a
schema miss on the own tenant means no such fields are declared; the real protection
(encrypted ciphertext dropped for every non-admin, schema-independent) is on main. The
D204 citation is a cosmetic provenance wart (decision doc pending on #12147), not an
evidence failure.

## R3 — Done-against-open-PR paperwork: drafts.felix-pristine-wave-30-log

    bp task get drafts.felix-pristine-wave-30-log -o json | \
      python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print(d['status'],d['lifecycle_status'],d['criteria_progress'],(d['claim'] or {}).get('now',{}).get('text'))"
    # draft done None  "charter PR #12147 OPEN and reporting checks"

Characterization: status=draft, lifecycle=done, criteria_progress=None (no acceptance
criteria — paperwork, not a capability claim). Closed THROUGH the engine (closed_by /
worker felix-decide-w30 / epoch 3) — NOT a hand-flip. Its `now.text` knowingly records
that its deliverable, the wave-30 CHARTER PR #12147 (docs-only, D202-D207), is OPEN +
CONFLICTING. No code capability at risk. Verdict: NOT a false-done — a paperwork row
honestly recording its own in-flight charter PR. Decide should leave it done and note
the tie to unmerged #12147.
