# CCH wave 48 — the lapsed-claim close path, proved by executing it

Date: 2026-08-07. Author: wave-48 verifier (`ledger-close-path-proof`).
Server: guerrilla.barkpark.cloud, `bp` commit 0789ab90a.

## What was claimed, and what is true

The brief said four of five wave-47 closes would **silently fail** on the recorded
`previous_worker` (the same condition `cch-w47-bl-four-merged-round-1-rows-all-need-a-re-claim-not-just-one`
was filed for). **Refuted: nothing is silent.** The server refuses loudly, in a
fixed order, and each refusal names its own recovery.

## Re-derivation recipe

    # 1. read a lapsed row (worker:null, previous_worker set, N-1/N criteria)
    bp task get cch-w47-s5-the-binding-census-stops-printing-numbers-nothing-can-red -o json

    # 2. close on the recorded previous_worker -> refused on CRITERIA, not identity
    bp task close <id> <previous_worker> <epoch> done "…" --yes
    # -> criteria_unmet:10  (identity accepted; previous_worker IS the holder)

    # 3. close on a bogus worker -> not_holder:<previous_worker>  (honesty gate,
    #    overridable with --set holder_override="…")
    # 4. close on a bogus epoch  -> fenced_off ("re-claim under your worker id")

    # 5. stamp the merge-gated criterion as the previous_worker -> TWO guards fire:
    #    merge_gated_criterion (needs --merge-gated), then not_in_progress:open
    #    (the row's lifecycle went back to open when the lease was swept)

    # 6. THE WORKING PATH:
    bp task claim <id> <new-worker> --yes                       # epoch 6 -> 7
    bp task stamp <id> <new-worker> 7 --criterion 10 \
      --criterion-text "MERGE-GATED (lead closes): the PR is merged into main." \
      --met --merge-gated --evidence "<PR + squash sha + ancestor proof>" --yes
    bp task close <id> <new-worker> 7 done "<summary>" \
      --set holder_override="original claim lapsed to worker:null" --yes
    # -> lifecycle done, met 11/11, closed_by=<new-worker>

## Executed once, for real

`cch-w47-s5-the-binding-census-stops-printing-numbers-nothing-can-red` is now
`done`, 11/11, `closed_by=epic-w48-verifier-ledger-close-path`. Its merge evidence
is the squash commit `7dc763a70` (PR #10397), proved by
`git merge-base --is-ancestor 7dc763a70 origin/main` exiting 0.

## The remaining arrears (all identical shape: merge-gated criterion only)

    cch-w45-s1 9/10   cch-w45-s2 10/11  cch-w45-s3 8/9   cch-w45-s4 8/9
    cch-w45-s5 10/11  cch-w46-s2 8/9    cch-w46-s3 8/9   cch-w46-s4 8/9
    cch-w47-s1 12/13  cch-w47-s2 12/13  cch-w47-s3 9/10  cch-w47-s4 11/12

Eleven rows, every one merged, every one open only because the lead's merge
criterion was never stamped. Epic denominator at the time of writing:
`child_count 612 · done 258 · open 296 · considering 1 · cancelled 57`.

## Two rows called phantoms are not phantoms

`bp task get cch-w45-s6` and `bp task get cch-w47-s6` both return
`not_found: task not found` — because a bare `cch-w4N-sM` is not an id. The rows
exist under their full slugs and are genuinely unbuilt (never claimed):

    cch-w45-s6-lifecycle-cli-chip-names-its-provider                  open 0/10
    cch-w47-s6-the-member-times-empty-fleet-scenario-and-the-five-integers open 0/11

## cch-w46-s5 / s6 must NOT be closed as paid

Both are `open`, `claim: null` — **never claimed, never built**. cch-w47-s2 shipped
the OFFER fence for both surfaces (`fleetSupportCardHtml` gates the add CTA on
`authority === "grant"`, app.js:7690; the four autoupdate controls route through
`adminWriteControlHtml`, app.js:8168-8171) — but that is one criterion of nine
and one of eight. Residue that has NO ledger row of its own:

* `__binding_census.mjs` still pins `submitAddSupport` (:278) and
  `patchAutoupdate` (:280) as `predicate: null` / "UNPREDICATED" although both
  offers are now fenced. Only the third stale pin has a row
  (`cch-w47-bl-census-pin-openresurrectmodal-now-predicated`, :239).
* The four `data-au` controls pass `exitHtml = ""`, so their `unknown` arm
  renders "Checking capabilities…" with no exit — while the sibling call at
  app.js:6950 passes `meRetryHtml()`. `cch-w45-s5-fu-panel-unknown-arm-has-no-exit`
  names only the Updates-panel Rollback, not these four.
* `cch-backlog-bpbase-envelope-incomplete` is still `open 0/2`, and
  `cch-w46-bl-bpbase-remaining-seven-envelope-keys` is `open 0/0`.
