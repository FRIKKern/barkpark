<!-- doc-tier: cold | canonical-for: pds-charter-ledger-adjudication | budget: 24000tok -->

# PDS CHARTER↔LEDGER ADJUDICATION TABLE

The hand adjudication that `scripts/pds-charter-ledger-sweep.sh` resolves against
the live ledger. EVERY candidate line the same-line lens produces is here — this
table is exhaustive by construction: the sweep REDS on an UNRESOLVED-CLAIM
ARRIVAL, so a candidate missing from this file cannot pass silently.

`asserted` is the HAND reading of what the charter line claims. The verdict
(AGREES / DISAGREES / NOT-A-DISPOSITION-ASSERTION / NOT-A-TASK) is NOT stored
here — it is COMPUTED at run time from the live `lifecycle_status`, so this file
can never go stale against the ledger, only against the charter.

THE FIVE CLASSES, AND THE RULE THAT SEPARATES THEM

  terminal         the charter claims the row's work is finished — paid, CLOSED,
                   MOOT, REFUTED, shipped in a wave's slice table with its PR.
  non-terminal     the charter claims the row still carries work — stays open,
                   deferred, held, RE-SCOPED, a criterion explicitly unpaid.
  historical       the charter records the row's state AT A MOMENT ("stays open
                   at 0/11", "had been FALSELY CLOSED"). The charter is an
                   append-only decision log: a timestamped observation is not a
                   standing claim, and scoring one against today's ledger
                   manufactures disagreements out of ordinary progress.
  non-disposition  the matched token is not about lifecycle at all — a criterion
                   edit, a dispatch precondition, a filename, a description of
                   the artifact rather than the row.
  non-task         the `pds-` string is not a task: a script filename, a CI job
                   name, a Paper slug, or a planned slug never filed. Every one
                   is CONFIRMED with a second read (`bp task get`) at run time.

THE SEPARATING RULE, stated so it can be argued with: a claim about the WORK
("all 16 sites paid") is standing and is scored against the live row; a claim
about the LEDGER STATE at a moment ("stays open at 10/11") is historical.

MEASURED BY THE WAVE-39 REVIEWER, 2026-08-02 — THIS TABLE REDS THE MOMENT THE
WAVE-39 CHARTER PR (#9100) MERGES, AND HERE IS EXACTLY HOW MUCH. This table was
adjudicated against the charter as it stands on `origin/main` (10,479 lines).
The wave-39 charter is an OPEN PR, so the reviewer ran the sweep against that
PR's charter content (10,788 lines) to measure the arrival before it lands:

    bash scripts/pds-charter-ledger-sweep.sh --charter <#9100's charter>
    → rc=1 · unresolved-claim arrivals: 6 · misclassified arrivals: 0

The six, verbatim, with the reviewer's PROVISIONAL reading — **NOT adjudicated
here, and deliberately not written into the table above**:

| line | slug | provisional reading |
|---|---|---|
| 6923 | pds-w27-reader-transport-honesty | non-disposition — a shipped-slice table row; `guarded` describes the ARM, not the row |
| 10582 | pds-w38-verdict-freshness-arm | non-disposition — PDS-D559 calls the row's CRITERIA defective, which is a criterion claim |
| 10693 | pds-bl-spill-dir-path-drift | non-disposition — the charter QUOTING this sweep's own finding, not asserting a disposition |
| 10694 | pds-w20-crown-fire | non-disposition — same shape, quoting the finding |
| 10695 | pds-w34-census-cas-shadow | non-disposition — same shape, quoting the self-contradiction |
| 10735 | pds-census | non-task — a `needs:` job name, the same reading already given to `pds-receipt-census` |

WHY THE REVIEWER DID NOT JUST WRITE THEM IN. The fingerprint is a content hash of
the whole line, and #9100 is OPEN and therefore still mutable — a row adjudicated
against an unmerged line is a row that can be stale on arrival, which is the exact
species this epic files. Note also that line 6923 was NOT a candidate before:
the vocabulary is mined from the charter itself, so 314 lines of new prose move the
stopword frequency table and admit lines that were previously below it. **The
adjudication is owed on the POST-MERGE tree**, and `pds-w39-charter-ledger-corrections-owed`
already carries a criterion for that re-run. Until then this arm is NOT enrolled in
`.github/workflows/**`, so the red is local and blocks nothing on `main`.

| fingerprint | line | slug | asserted | note |
|---|---|---|---|---|
| 0491b85db045 | 573 | pds-w1-crown-proof | non-disposition | PDS-D75 rewrites CRITERION 7's wording; a criterion edit is not a lifecycle claim |
| 8129198fe428 | 934 | pds-scratch-target.sh | non-task | pds-scratch-target.sh is a script filename, not a task slug |
| c9cebb359a4d | 1119 | pds-w1-crown-proof | historical | quotes the row's lifecycle AT wave 1 (carried done, closed_by oc-lead) - a timestamped observation, not a standing claim |
| 5cc8562bdc74 | 1160 | pds-w3-shares-fidelity | non-terminal | PDS-D143 STAYS DEFERRED TO WAVE 9 - a standing non-terminal disposition |
| cd915f1f2a1c | 1456 | pds-w1-crown-proof | historical | STAYS OPEN at 10/11 - the row's state at that wave, since advanced |
| 3d2ee043e15d | 1583 | pds-pull-proof.crown | non-task | pds-pull-proof.crown-transcript-w8.txt is a transcript filename |
| b816c8fc8de3 | 1850 | pds-pull-proof.sh | non-task | pds-pull-proof.sh is a script filename |
| aa5b10f15e20 | 1926 | pds-pull-proof.sh | non-task | pds-pull-proof.sh is a script filename |
| 080215d66127 | 2588 | pds-w38-routed-population | terminal | wave-38 SHIPPED-SLICE table (slug + branch + what it does) - asserts the work landed |
| bf5a3defbf87 | 2590 | pds-w38-scim-group-member-receipts | terminal | wave-38 shipped-slice table row |
| 6d1b1f0e7b84 | 2591 | pds-w38-ledger-hygiene-derived | terminal | wave-38 shipped-slice table row |
| d2891f418ea1 | 2672 | pds-w38-scim-group-member-receipts | non-disposition | DISPATCH table (what the slice will do), not a completion claim |
| 3bf877ee312c | 2673 | pds-w38-ledger-hygiene-derived | non-disposition | dispatch table row |
| 0ab4a1332229 | 2770 | pds-w34-census-import-arity | terminal | wave-34 shipped-slice table row with its PR |
| 05bf131a38d2 | 2772 | pds-w36-groupc-diffs | terminal | wave-36 shipped-slice table row with its PR |
| d7531c406e90 | 2838 | pds-w34-unreachable-error-positive-arm | terminal | wave-34 shipped-slice table row with its PR |
| 1261a1f4414b | 2839 | pds-w34-declared-basis-literals-need-constants | terminal | wave-34 shipped-slice table row with its PR |
| 41b16ffe48a5 | 2923 | pds-w34-census-lens-correction | terminal | wave-34 shipped-slice table row with its PR |
| ac8df79bef81 | 2925 | pds-w32-census-binds-the-basis | terminal | wave-32 shipped-slice table row with its PR |
| b186dcfba4b2 | 2968 | pds-w34-hand-bucket-register | non-disposition | 'it is deliberately last' orders the dispatch; it asserts no lifecycle |
| 1e6a489771fe | 2993 | pds-w34-census-import-arity | non-disposition | 'name-scoped, not arity-scoped' describes the resolver, not the row |
| e0cbcceb0cae | 3000 | pds-w34-hand-bucket-register | non-disposition | 'the doc amendment is now ...' narrates scope, not lifecycle |
| 124ea12248d4 | 3020 | pds-w33-cli-renders-error-details | terminal | wave-33 shipped-slice table row |
| 4c83cffea245 | 3048 | pds-bl-opaque-arm-blind-to-nonliteral-kind | non-disposition | 'is stamped on that evidence' is a CRITERION stamp, not a lifecycle disposition |
| c2fb8c0a112c | 3085 | pds-w31-harvest-only | terminal | wave-31 shipped-slice table row with its PR |
| cebea4bd059f | 3086 | pds-w29-pay-net-dns | terminal | wave-29 shipped-slice table row with its PR |
| 21fba8c88bfb | 3152 | pds-w29-pay-storage-backup | terminal | wave-29 shipped-slice table row with its PR |
| 9f24c336c953 | 3176 | pds-w29-pay-net-dns | non-disposition | 'is likewise round 2, behind #8685' is dispatch ordering |
| 8e4f887a0876 | 3228 | pds-w29-pay-lb | terminal | KNOWN #1 - shipped-slice table, PR #8644 MERGED, 'all 16 non-destroy lb-family sites paid'. The charter is right about the WORK; the ledger row is the stale half |
| 99a678f701dc | 3352 | pds-w28-census-isolation | terminal | wave-28 shipped-slice table row with its PR |
| 6eca4e162637 | 3355 | pds-w28-reader-default-page-fence | terminal | wave-28 shipped-slice table row with its PR |
| 65b868c0d3fc | 3525 | pds-w13-scratch-cost-truth | non-disposition | a round-1 DISPATCH brief ('the boot-cost record is wrong by 4.75x'), not a disposition |
| de8a7359bf84 | 3607 | pds-w11-floor-rederivation | non-disposition | 'dispatch only after the engine is MERGED AND DEPLOYED' is a precondition |
| be3b700dd47f | 3790 | pds-w1-crown-proof | historical | 'is correctly reopened' records a wave-time reopen; the row has since closed |
| 2889ee5d6b1d | 3804 | pds-w8-rung6-sentinel | non-disposition | 'order is cosmetic' is about dispatch order |
| e556cd96bdd5 | 3807 | pds-w3-shares-fidelity | non-terminal | 'stays deferred until after a green' - standing non-terminal |
| dfe236226cf9 | 3843 | pds-w1-crown-proof | historical | 'had been FALSELY CLOSED by this' - explicitly retrospective |
| de6e1b4910a6 | 3851 | pds-w3-shares-fidelity | non-terminal | 'stays deferred to' - standing non-terminal |
| 2b126034d5e4 | 3935 | pds-pull-proof.sh | non-task | scripts/pds-pull-proof.sh is a script filename |
| ac912876e7b7 | 3993 | pds-w5-charter-amendment | non-disposition | 'was dispatched' records a dispatch event, not a lifecycle |
| 07b2c53343c0 | 4034 | pds-w1-crown-proof | historical | 'stays open at 0/11' - the row's state at that wave; live is done |
| 0377e13f5fd1 | 4102 | pds-w3-shares-fidelity | non-terminal | 'STAYS HELD behind the transcript' - standing non-terminal |
| 840c73d68caa | 4145 | pds-w14-crown-fire | non-disposition | 'The degradation is silent by construction' describes the harness |
| 1fff7aab1f10 | 4192 | pds-bl-w14-standdown-token-ruling | non-terminal | 'is RE-SCOPED' narrows the row; a re-scope is not a closure |
| f4e08c59d9c1 | 4427 | pds-idle-sampler.sh | non-task | pds-idle-sampler.sh is a script filename |
| dbfb5784638a | 4448 | pds-w15-fire-record.md | non-task | scripts/pds-w15-fire-record.md is a document filename |
| 54767de93f80 | 4842 | pds-backlog-import-savepoint-honesty | non-terminal | 'stays open as honest error-surfacing polish' - standing non-terminal |
| 090c92e9132c | 4874 | pds-crown-launch.sh | non-task | scripts/pds-crown-launch.sh is a script filename |
| 70db14d8b5b1 | 4948 | pds-w1-crown-proof | terminal | 'is lifecycle done, 12/12' - an explicit terminal claim |
| c96b2d32501b | 5014 | pds-w1-crown-proof | historical | 'was closed at 6-and-10 met:false and now reads 12/12' - explicitly retrospective |
| daa11cf6cf4d | 5104 | pds-bl-harness-pgrep-wrong-process | terminal | 'is FIXED by 58d1bd3a5' - a terminal claim about the work |
| efd62561121e | 5191 | pds-w21-crown-collect-and-seal | terminal | '= done 6/6' - an explicit terminal claim |
| e19e546ec4eb | 5294 | pds-w22-manifest-and-counts-honesty | terminal | wave-22 shipped-slice table row with its PR |
| ea2a5f8db1ee | 5319 | pds-bl-stage-note-evaporates | terminal | 'was closed as a duplicate into pds-bl-park-note-evaporates' |
| 6526839f4d30 | 5337 | pds-bl-bounded-import-unpack | non-disposition | LENS ATTRIBUTION LIMIT - 'was taken by NO slice' predicates of pds-bl-scratch-pointer-concurrency, but the line's FIRST slug is pds-bl-bounded-import-unpack |
| c434451ce9a2 | 5496 | pds-backlog-streamed-bundle-channel | terminal | 'is `done`' - an explicit terminal claim |
| c5f99c02b1eb | 5561 | pds-bl-blob-sidecar-byte-verify | terminal | 'is CLOSE-ELIGIBLE verified by content' - asserts the row should carry no more work |
| 35f28b11ba41 | 5641 | pds-w23-triage-round | non-terminal | 'is deferred BY DESIGN' - standing non-terminal |
| 824a7d558613 | 5648 | pds-bl-park-note-evaporates | terminal | wave-23 shipped-slice table row with its PR |
| 87910b3b35d0 | 5652 | pds-w23-cold-owner-verb-honesty | terminal | wave-23 shipped-slice table row with its PR |
| 967480925787 | 5711 | pds-w23-triage-round | non-disposition | 'is unblocked the moment #6550 ...' is a readiness condition, not a disposition |
| c52cdd856910 | 5849 | pds-bl-spill-dir-path-drift | terminal | KNOWN #2 - PDS-D343 'is paid' with the surviving-hits evidence inline |
| 291dfc578196 | 5850 | pds-w20-crown-fire | terminal | KNOWN #3 - 'is MOOT (it arms a crown sealed 12/12)'. MOOT-implies-cancelled is an ADJUDICATION, not a charter rule - the live `considering` is the question still open, and this sweep REFUSES to mass-cancel it |
| 967e6bcc53d8 | 5851 | pds-bl-bp-search-false-negative | terminal | the worked VOCABULARY-GAP example - 'premise is REFUTED', a word no ledger status carries |
| f84fa857300d | 5855 | pds-bl-w16-full-meta-permissive-default | non-terminal | CROSS-LINE INVERSION - the governing phrase 'NOT paid, checked and standing:' ends charter:5854; read same-line, 'is ACCEPTED' inverts the claim |
| daff13599f0f | 5941 | pds-w24-stage-disposition-wiring | terminal | 'is CLOSED with that fixing commit rather than carried' |
| b48db439b636 | 6278 | pds-w25-hetzner-nine-verb-receipt | terminal | wave-25 shipped-slice record with PR #8219 |
| f7b6a8a0ba02 | 6293 | pds-w12-crown-climb-preconditions | non-disposition | CROSS-LINE TRUNCATION - 'is lifecycle' ends the line and the VALUE `blocked` is on charter:6294; the same-line lens sees the assertion and never the value |
| dc3e5f69d9a7 | 6315 | pds-w25-round-terminal | non-disposition | 'it is fully specified and it is the last 15 rows' describes readiness, not lifecycle |
| bd9c3aa56e83 | 6330 | pds-w26-stamp-readback | terminal | wave-26 shipped-slice table row |
| 15bb0a2481e4 | 6333 | pds-w26-hetzner-five-flag-verbs | terminal | wave-26 shipped-slice table row |
| 2ac139f290f6 | 6334 | pds-w26-census-anchor-4a | terminal | wave-26 shipped-slice table row |
| 5cec7c8d4122 | 6362 | pds-w26-census-anchor-4a | non-disposition | 'the residual is exact and unresolved' is about a numerator |
| 233c7e9d7595 | 6373 | pds-w25-round-terminal | non-disposition | 'the moment #8218 is DEPLOYED' is a dispatch precondition |
| c896d1a8da12 | 6554 | pds-w26-publish-door-criteria-fence | terminal | wave-26 shipped-slice gate table row; the token comes from lifecycle_test.exs |
| 4df1e8408a2a | 6648 | pds-bl-cond-b-nonnumeric-floor-fail-direction | terminal | 'is REFUTED BY EXPERIMENT' - the row's premise is dead |
| 199c0196bcdc | 6652 | pds-bl-github-linkput-auto-publish-erasure | terminal | FIFTH DISAGREEMENT - 'headline defect was fixed by wave 26 and lifecycle.ex:292-312 says so verbatim' |
| fb7f83dcb874 | 6655 | pds-bl-task-stamp-silent-nonland | terminal | 'priority-1 framing is stale - the CLI read-back shipped' |
| db4d031889e4 | 6657 | pds-bl-close-409-hint-promises-absent-fields | terminal | SIXTH DISAGREEMENT - 'is MIS-STATED ... the criterion as written would make the SERVER worse' |
| 39602ec60739 | 6886 | pds-w27-round-terminal-15 | non-disposition | wave-27 dispatch table (round + what + gate), not a completion claim |
| 6cd6d64b15b8 | 6887 | pds-w27-round-bare-30 | non-disposition | wave-27 dispatch table row |
| 9699e3e2b421 | 6921 | pds-w27-round-bare-30 | terminal | SEVENTH DISAGREEMENT - wave-27 shipped-slice table, PR #8408, 'clause 4(a) 30 to 0 ... All 30 verdicts re-derived by content' |
| e1a3825caa18 | 6926 | pds-w27-hetzner-gate-file-blindness | terminal | wave-27 shipped-slice table row with its PR |
| 56bafc2ece4e | 6947 | pds-w27-brief-card-disposition | historical | 'was lifecycle `open` with 9-of-10 criteria stamped' - explicitly retrospective |
| 28072c3458be | 7205 | pds-ledger-census.sh | non-task | pds-ledger-census.sh is a script filename |
| 99ef5feaf983 | 7233 | pds-w28-census-isolation | terminal | wave-28 shipped-slice table row with its gate |
| 9e9de970682a | 7604 | pds-w25-backlog-hzresdone-receipt | non-disposition | 'Both cuts are exact partitions of the same 40' is about the cut, not the row |
| 9334a0f7b268 | 7677 | pds-w29-pay-net-dns | non-disposition | 'Criterion 7 ... is REWRITTEN' is a criterion edit |
| 8e1981deb51c | 7803 | pds-w29-write-receipt-fence | historical | 'were all lifecycle_status: open with every criterion met' - a wave-time observation of a class of rows |
| 253e4a3de432 | 7826 | pds-w29-pay-net-dns | non-disposition | wave-29 dispatch table row (round 2 planning) |
| 1c9c0a34ae45 | 7827 | pds-w29-pay-storage-backup | non-disposition | wave-29 dispatch table row - 'criterion 4 already paid' is a criterion note inside a plan |
| 4ecf5f89ac77 | 7868 | pds-bl-census-runs-in-no-ci-gate | non-disposition | 'is about scripts/pds-ledger-census*.sh' names the row's SUBJECT |
| 25695bf7c912 | 8075 | pds-w29-pay-lb | non-terminal | 'c13 is VIOLATED BY MERGED CODE' - the charter's OWN counter-claim to charter:3228, on the same slug |
| 53fd2f659056 | 8081 | pds-w29-registry-postcondition-invariant | non-terminal | 'c9 is half satisfied ... stamping it would launder up to ten' - an explicit refusal to treat the row as complete |
| 1d869df2d678 | 8083 | pds-bl-hzresdone-registry-row-vacuous | non-terminal | 'are open with substantive unpaid criteria' |
| a0aebf96ae1d | 8103 | pds-w29-pay-storage-backup | non-disposition | wave-29 dispatch table row |
| f1401fe6653f | 8396 | pds-w31-harvest-only | non-disposition | wave-31 dispatch table row |
| de2ded3e25d7 | 8403 | pds-w31-harvest-only | non-disposition | 'its credential-free premise was REFUTED as filed and re-cut here' - retrospective framing of the CUT |
| 657649754084 | 9458 | pds-w35-lens-stops-accusing | non-task | a planned slug in a dispatch table that was never filed - `bp task get` returns not_found |
| d1f63cd270d1 | 9500 | pds-receipt-census | non-task | pds-receipt-census is a CI job name, not a task |
| debacd8c2cfe | 9820 | pds-w34-census-cas-shadow | non-terminal | KNOWN #4 - the charter QUOTES lifecycle_status open while charter:2628/:2681 say done and live is done. The charter disagrees with ITSELF; this is a stale QUOTE |
| f04f19ce434d | 9926 | pds-w36-groupc-webhook-differentials | non-task | a planned slug in a dispatch table that was never filed - `bp task get` returns not_found |
| fc97c6511931 | 9927 | pds-w36-brief-help-seal-divergence | non-task | a planned slug in a dispatch table that was never filed - `bp task get` returns not_found |
| 8e2aecb9cce6 | 10192 | pds-receipt-census | non-task | pds-receipt-census is a CI job name, not a task |
| ca218163ca19 | 10408 | pds-bl-opaque-arm-blind-to-nonliteral-kind | historical | a wave-38 observation of a merged-but-open row ('is open at 2/2 met'); the ledger-hygiene slice has since closed it |
