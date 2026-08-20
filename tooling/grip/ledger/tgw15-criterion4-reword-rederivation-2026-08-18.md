<!-- doc-tier: cold | canonical-for: tgw15-criterion4-reword-rederivation | budget: 900tok -->

# tgw13-s1 criterion index 4 re-word — re-derivation recipe (wave 15, VERIFY)

Verifier assignment: governance-criterion-rewording. Read-only; no bp mutation, no main touch.

## Re-derive the current pinned wording

    bp task get tgw13-s1-scaffy-subcommand-anchor -o json | \
      jq -r '.doc.content.acceptance_criteria[4].criterion'

Yields (0-based index 4 = 5th criterion, verbatim):

> MERGE-GATED (the LEAD closes this): PR #12181 is amended with the anchor + assertion, merged to main, and node --test tooling/grip/test/level.test.mjs is green on origin/main

## Re-derive that "amend" is tactical routing, not a fact-authority invariant

    git show origin/main:.claude/workflows/bp-truth-grip-charter.md | sed -n '3020,3068p'
    grep -n "amend\|#12181" <(git show origin/main:.claude/workflows/bp-truth-grip-charter.md)

Only TWO live mentions of the amend after D140:
- line 3035 (D140 body): "the tgw12-s2 builder amends PR #12181" — a *Why*-clause routing note.
- line 3068 (wave-13 roster row): "amends PR #12181 (D140)" — dispatch metadata.
Neither is a ratified invariant; the ratified content is the verdict (REQUEST-CHANGES on the
indexOf over-refusal) + remedy (subcommand-anchor + L2 assertion). Highest D-number in charter
is D144 (`grep -oE "D1[0-9][0-9]" | sort -u | tail`); D142/D143/D144 do NOT re-mandate the amend.

## Draft replacement (Decide applies this — verifier does not mutate)

Replace criterion index 4 with:

> MERGE-GATED (the LEAD closes this): a fresh corrected PR — cut from clean origin/main, landing the subcommand-anchored isLocalScaffyInvocation + the L2 remote-read assertion, preserving D140's ratified verdict + remedy byte-for-byte (close+fresh supersedes the held #12181) — is merged to main, and `node --test tooling/grip/test/level.test.mjs` is green on origin/main

Decide-block one-liner to record the mechanism change:

> Mechanism note: #12181 shipped by CLOSE+FRESH, not amend (D140's "amend" was PR-routing, not
> an invariant); criterion 4 re-worded to reference the fresh corrected PR so the task stays
> closeable. Verdict D140 + remedy preserved byte-for-byte.
