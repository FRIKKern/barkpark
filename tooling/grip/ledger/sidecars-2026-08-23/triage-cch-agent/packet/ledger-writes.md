# PURE bp-LEDGER WRITES — one lead session clears these (no build, no CI, no merge)

Curated down from the sweep's ~35 estimate to the rows whose WORK is genuinely a ledger write or a lead ruling — the honest list is 17 + 4 riders. Rows needing any code/CI landed elsewhere stay out.

## A. Stamp/close arrears (the 7-generation family's live half)
1. `cch-w42-bl-twelve-paid-rows-await-the-lead-stamp` — hand-stamp + close 12 enumerated paid rows; claims lapsed so each needs re-claim first; criteria carry no merge_gate:true so the autostamp bridge cannot retro-pay. Riders (DUPLICATE, resolve in the same pass, close nothing as "twin" without checking): `cch-w41-bl-six-merge-gated-rows-are-paid-and-await-a-lead-stamp`, `cch-w58-bl-thirty-two-lapsed-claims-and-twelve-unfinished-rows`.
2. `cch-w62-bl-the-law-0-repayment-pass-nineteen-located-rows` — the big one: re-claims, closes with merge shas, 13 body-verified instrument-row moves to cch-instruments-epic (`bp task move`, D317's verb — POST /v1/tasks/<id>/move; assert the DESTINATION roster, never the orphan delta), dual roster derivations timestamped. D745 lists the 5 merge-gated paid rows and the ONE stale-open full-criteria row.
3. `cch-w28-bl-w22s7-split-stamps-never-landed-and-c9-kill-is-refuted` — execute charter D325's adjudication on cch-w22-s7: 5 stampable criteria, 2 unpayable, recorded reasons. Rider (DUPLICATE): `cch-w29-bl-w22s7-stamp-set-and-two-stale-open-rows`.
4. `cch-w77-bl-w58-s2-flags-reflect-withdrawal` — flip cch-w58-s2's withdrawn flags 7/8→truth 6/8. CAVEAT (D745, \bD745\b=8): the ledger REFUSES a met:true→met:false patch; if it still refuses, pay by close_reason/evidence note stating the true ratio — do not fight the wall.

## B. Draft & roster hygiene
5. `cch-w59-bl-nine-live-draft-rows-inflate-the-roster-and-pay-zero` — discard/disposition the 9 live drafts (drafts.* discards pay bp task get's 414-denominator, NOT the published 404 — never let a draft discard carry a Law-0 criterion).
6. `cch-w30-bl-discard-three-stranded-draft-twins` — 3 bp discards; note its own premise correction: the rows are parented to cch-instruments-epic, so closing does NOT shrink this epic by 3.
7. `cch-w42-bl-two-open-drafts-have-no-published-twin` — DUPLICATE rider of #5 (different draft population — verify before treating as covered).
8. `cch-w37-bl-roster-collapse-three-paid-rows` — three closes + cancels + live-count re-read, lead credential only.
9. `cch-w60-bl-38-live-rows-have-no-acceptance-criteria-at-all` — re-derive the 38, make 38 triage decisions (criteria-or-close), plus the Standing Law 0 charter amendment it requests (D680 already amended the law — reconcile, don't duplicate).

## C. Single-row amendments / re-scopes
10. `cch-w34-bl-amend-cch-w11-s1-criterion-10` — one criterion amend; residual criterion 11 = cch-w30-bl-w11s1-gate-mutation-proof-owed (BLOCKED-HUMAN, keep separate).
11. `cch-w33-bl-recut-api-status-aware-envelope-criterion-3` — recut one criterion per D376(d) (in-repo half already paid).
12. `cch-w14-bl-tablet-width-audit-rescope` — re-scope one row against the sweep that discharges its criterion 0 (the re-parent D160 froze and D317 thawed).
13. `cch-w39-fu-flip-packet-passes-require-new-context` — two-word prose edit in the flip packet row + paste one rc=2 run.
14. `cch-w42-bl-membersContext-motivations-refuted-by-rendering` — update GH issue 9971 / row wording to the refuted framing (code side already confirmed at app.js:21989).
15. `cch-bl-thirtyone-done-rows-cite-branch-shas` — reconcile 31 done rows' branch-sha citations to merge shas BY CONTENT ANCHOR (never subject); 4 prior ancestry sweeps in tooling/grip/ledger are the recipe.

## D. Lead rulings with no build attached
16. `cch-w53-bl-members-cannot-read-their-own-account-security-rows` — product/permission ruling (self-scoped audit read: yes/no); the row is the decision.
17. `cch-finding-roster-tooling-contract` (NEEDS-DEPTH) — standing finding; retire iff its two gr-* trigger rows are closed — a 2-minute ledger read settles it.

Ledger-half-only rider: `cch-w61-bl-the-merge-gate-attestation-names-the-wrong-required-set` — criterion 2 (37 rows re-derived with the gh compare oracle) is ledger+gh work you can do; criterion 1 (shallow-repo guard on close paths) is code and stays with builders.
