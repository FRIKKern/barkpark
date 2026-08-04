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

## WAVE 46 — THE ADJUDICATION IS KEYED ON TWO FROZEN BLOB SHAS, NEVER A COUNT

THE PIN. This block adjudicates every arrival at ONE base, and the base is named by
CONTENT, not by an arrival number. Taken with `git rev-parse` at the build base:

    git rev-parse HEAD                                       683c2f00a5f809851f6f3ee2bdd341158349d525
    git rev-parse HEAD:.claude/workflows/bp-pds-charter.md   bb6796c8294f083b0efcc344096d427339df7996
    git rev-parse HEAD:scripts/pds-charter-ledger-adjudication.md
                                                             5382bfb1a3cda1429c8161f9dc16fa3ebc314d46

The second sha is the 105-row table THIS block extends. Neither sha is a count, and
NO acceptance value in the wave-46 slice that wrote this block is an arrival number.

WHY A BLOB AND NOT A COUNT. The arrival count has moved 41 -> 45 -> 59 -> 71 across
four charter merges, and this wave's own charter PR (#9466) moves it a fifth time.
It was 71 here. Quoting 71 as the thing that was adjudicated would be the same
species this epic files: a number that ages silently while the artifact moves.

THE CHURN IS NOT REFLOW, AND THE FINGERPRINT ALREADY PROVES IT. The fingerprint at
`scripts/pds-charter-ledger-sweep.sh:311-312` is `sha1(slug + "|" + whitespace-
normalised line)[:12]` with NO line number in it, so a committed row survives any
amount of reflow — and `stale adjudication rows : 0` at this base says all 105
prior rows still locate. The display-only `line` column is the only line-coupled
field, and it costs zero arrivals.

TWO LIVE-DRIFT CHANNELS IN THE LENS, BOTH UNPINNED, BOTH NAMED HERE. The line
numbers below are RE-DERIVED at this base, not transcribed: the wave-46 brief cited
`:263-269` and `:267` for these two folds, and at blob `bb6796c8` they live 55-60
lines lower. An anchor is exactly the kind of value this epic refuses to inherit.

  (1) THE LENS IS MINED FROM THE CORPUS IT MEASURES. `IDIOM_VOCAB`
      (`pds-charter-ledger-sweep.sh:322-329`, i.e. the `_pred` fold plus the
      `RANK.get(t) >= STOP_RANK` filter) is every token the charter PREDICATES of a
      `pds-*` slug minus the charter's own 100 most-frequent words, and `RANK` is
      recomputed over the WHOLE file (`:290-292`). Appending charter prose therefore
      moves the frequency table and ADMITS VOCABULARY THAT RETRO-FIRES ON OLD,
      BYTE-IDENTICAL LINES. At this blob the printed vocabulary is
      `2. DERIVED DISPOSITION VOCABULARY - 67 tokens (6 CORE + 62 charter idiom)`.

  (2) `CORE` (`:321`, the `CORE = sorted({v for k, v in STATUS.items() ...})` fold)
      is derived from the LIVE ledger's distinct `pds-*` lifecycle values — not from
      the charter at all. It has drifted 5 -> 6 over an identical charter blob; at
      this run it reads `blocked, cancelled, considering, done, in_progress, open`
      over a 620-row `pds-` population. A charter that never changes can still change
      this lens.

THE VINTAGE SPLIT — 14 RETROACTIVE, 57 GENUINELY NEW PROSE. Measured by taking each
arrival's whitespace-normalised line and asking whether that exact line already
existed in the charter at `aa81a9b6e`, the commit that authored the 105-row table
above. Fourteen did. Every one of them fires on ENGINEERING IDIOM, the same
false-positive class the sweep already carves out for `fails CLOSED`:

  - charter:1208  `pds-pull-proof.sh`                      token `export`
  - charter:4028  `pds-w38-routed-population`              token `router`
  - charter:4054  `pds-w34-hand-bucket-register`           token `five`
  - charter:4198  `pds-w34-ledger-background-write-arms`   token `five`
  - charter:4375  `pds-w33-elixir-receipt-census`          token `five`
  - charter:4511  `pds-w31-census-shrinkage-ratchet`       token `satisfied`
  - charter:4587  `pds-w29-registry-postcondition-invariant` token `byte-identical`
  - charter:6986  `pds-w23-cold-owner-verb-honesty`        tokens `export`, `router`
  - charter:7915  `pds-w26-export-atomic-out`              token `export`
  - charter:7916  `pds-w26-workspace-export-declared-size` token `export`
  - charter:8251  `pds-w27-certify-the-round`              token `itself`
  - charter:8281  `pds-w27-reader-transport-honesty`       token `guarded`
  - charter:10818 `pds-w35-background-write-arms`          token `five`
  - charter:11592 `pds-w35-elixir-census-gate`             token `cut`

So roughly a fifth of this block is a LENS REPAIR wearing an adjudication's clothes,
and four-fifths is real judgment over prose waves 40-45 actually wrote.

THE LENS REPAIR IS DELIBERATELY NOT IN THIS PR. Extending the idiom exclusion CHANGES
THE CANDIDATE SET, which can DROP committed rows and turn `stale adjudication rows`
nonzero — doing both at once lets the two effects mask each other. Adjudicate at a
frozen blob first; extend the lens second. `scripts/pds-charter-ledger-sweep.sh` and
`scripts/pds-door-census.sh` are both UNTOUCHED by the PR that wrote this block; the
census's ledger literals are owned by `pds-w45-census-ledger-integrity` this wave.

TWO ADJUDICATIONS WORTH ARGUING WITH, STATED SO THEY CAN BE.

  - A SHIPPED-SLICE TABLE ROW IS `terminal` EVEN WHEN THE LEDGER ROW IS STILL OPEN.
    That is the reading already given to charter:3228 (KNOWN #1) and it deliberately
    produces DISAGREES rather than hiding the stale-open half. Six new rows here take
    it: charter:3007, :3894, :3896, :3897, :4054 and their kin. A DISAGREEMENT is a
    FINDING for the lead, not a red.
  - `pds-w39-r-owning-doc` (charter:3899) is the BRANCH name in a shipped-slice row,
    not a task; `bp task get` answers `ok:false error.code=not_found`, so it is
    `non-task`. The row's actual task, `pds-w34-owning-doc-amendment`, is the line's
    FIRST slug and the lens attributed the other one — the same LENS ATTRIBUTION
    LIMIT already recorded at fingerprint 6526839f4d30.


| fingerprint | line | slug | asserted | note |
|---|---|---|---|---|
| f25e8768c137 | 1208 | pds-pull-proof.sh | non-task | pds-pull-proof.sh:113 is a script filename inside PDS-D148's quoted export line; RETROACTIVE - the line predates this table and became a candidate only when `export` entered the mined vocabulary |
| cde5746adc2d | 2586 | pds-w45-lega-argument-list | terminal | wave-45 shipped-slice table row with its branch and PR #9434 |
| df67c6c4906d | 2629 | pds-w44-grant-door-narrowing | terminal | wave-44 shipped-slice table row with its branch and PR #9377 |
| fcdd795e0555 | 2630 | pds-w44-census-fold-and-blindspot | terminal | wave-44 shipped-slice table row with its branch and PR #9378 |
| b970c8fbbf13 | 2680 | pds-w44-hetzner-offline-door | non-terminal | 'were deferred BY DESIGN' - a standing deferral; the row still carries work |
| 468abae797a8 | 2791 | pds-w42-bl-grant-graded-component-arm-unbuilt | non-terminal | 'stays open and this wave must not' - an explicit refusal to treat the row as cleared |
| 16474b611076 | 2826 | pds-charter-ledger-adjudication.md | non-task | scripts/pds-charter-ledger-adjudication.md is THIS FILE's own path, not a task slug |
| b3e7d2e36f26 | 2845 | pds-idle-sampler.sh | non-task | pds-idle-sampler.sh is a script filename in the door inventory |
| fce285a3aab9 | 2990 | pds-w42-caps-prop-is-a-mount-snapshot | non-terminal | 'is likewise deferred: its unblocking dep merged, but' - standing non-terminal |
| 620412c5ef6e | 3007 | pds-bl-w41-readonly-member-sees-published-only | terminal | wave-41 shipped-slice table row with branch, PR #9295 and its gate; the ledger row is the stale half, so this scores DISAGREES by design |
| 8acfa6eb0f49 | 3055 | pds-w35-elixir-census-gate | non-terminal | 'remain open and unstarted' - standing non-terminal |
| 993e39429ad9 | 3100 | pds-w41-hop-arg-producer | non-disposition | criteria 1 and 3 are REWRITTEN - a criterion edit, not a lifecycle claim |
| d7da9ac04fd5 | 3363 | pds-w41-hop-arg-producer | non-disposition | wave-41 dispatch table row (slice + round + task + surface) |
| cf00a3c053ef | 3365 | pds-w42-paper-op-principal-gate | non-disposition | wave-41 dispatch table row |
| 3b759ed866f5 | 3369 | pds-w40-judgment-coverage-ladder | non-disposition | wave-41 dispatch table row |
| a290d5ef038f | 3370 | pds-w42-caps-prop-is-a-mount-snapshot | non-disposition | wave-41 dispatch table row |
| 3af3cf7874b8 | 3409 | pds-w40-scim-groups-list-members | historical | '8/9. Their merge halves are SATISFIED' - a criteria-count observation at that wave, not a standing claim |
| 8c88e89a2755 | 3434 | pds-w41-caps-component-gate | terminal | wave-41 shipped-slice table row with its PR #9230 |
| ed52e7d13ec6 | 3435 | pds-w40-liveview-write-population | terminal | wave-41 shipped-slice table row with its PR #9231 |
| 0c65003b0534 | 3739 | pds-w35-elixir-census-gate | non-disposition | 'stay CUT behind the .github/workflows/** fence - as POLICY' is a DISPATCH fence, not a lifecycle claim |
| bd4c547f9151 | 3778 | pds-w40-judgment-coverage-ladder | non-disposition | wave-40 dispatch table row |
| 508e4670f05e | 3807 | pds-w40-request-echo-repairs | terminal | wave-40 shipped-slice table row with branch and PR #9164 |
| 75b5e8108000 | 3808 | pds-w40-derivation-partition | terminal | wave-40 shipped-slice table row with branch and PR #9165 |
| 1b72f3b99141 | 3810 | pds-w40-shares-remove-postread | terminal | wave-40 shipped-slice table row with branch and PR #9167 |
| 101291a98b8b | 3882 | pds-w35-elixir-census-gate | non-disposition | 'stay behind the .github/workflows/** POLICY fence (D583)' - the same dispatch fence, restated |
| adca5b24b820 | 3894 | pds-w38-verdict-freshness-arm | terminal | wave-39 shipped-slice table row with branch and PR #9112; the ledger row is the stale half, so this scores DISAGREES by design |
| 45e2edb93e9d | 3896 | pds-bl-status-only-residue-payment | terminal | wave-39 shipped-slice table row with branch and PR #9114; ledger stale half, DISAGREES by design |
| 1c039a1f5c33 | 3897 | pds-w39-record-parity-shallow-guard | terminal | wave-39 shipped-slice table row with branch and PR #9115; ledger stale half, DISAGREES by design |
| 211d9cd25100 | 3899 | pds-w39-r-owning-doc | non-task | pds-w39-r-owning-doc is the BRANCH name in a shipped-slice row, not a task; `bp task get` returns not_found. The row's task is pds-w34-owning-doc-amendment, which the lens did not attribute |
| 018e43da760e | 4028 | pds-w38-routed-population | non-disposition | wave-38 dispatch table row (slice + round + task + what it does); RETROACTIVE - fired only once `router` entered the mined vocabulary |
| 7cc895ffd52c | 4054 | pds-w34-hand-bucket-register | terminal | wave-34 shipped-slice table row with its PR #8989; RETROACTIVE on the idiom `five`; ledger stale half, DISAGREES by design |
| 6c9569488b2c | 4198 | pds-w34-ledger-background-write-arms | terminal | wave-34 shipped-slice table row with its PR #8886; RETROACTIVE on the idiom `five` |
| 98fef89f0730 | 4375 | pds-w33-elixir-receipt-census | terminal | wave-33 shipped-slice table row; RETROACTIVE on the idiom `five` |
| 7d3b54d3be6a | 4511 | pds-w31-census-shrinkage-ratchet | terminal | wave-31 shipped-slice table row with its PR #8686; RETROACTIVE on the idiom `satisfied` |
| b30ee7a58719 | 4587 | pds-w29-registry-postcondition-invariant | terminal | wave-29 shipped-slice table row with its PR #8645; RETROACTIVE on the idiom `byte-identical` |
| 17ca934705f7 | 6986 | pds-w23-cold-owner-verb-honesty | non-disposition | wave-23 dispatch table row (round + task + surface); RETROACTIVE on the idioms `export` and `router` |
| ef5d72c9e9ae | 7915 | pds-w26-export-atomic-out | terminal | wave-26 shipped-slice gate table row (task + what + gate command); RETROACTIVE on the idiom `export` |
| 1c3f7e4aa768 | 7916 | pds-w26-workspace-export-declared-size | terminal | wave-26 shipped-slice gate table row; RETROACTIVE on the idiom `export` |
| db5911789a17 | 8251 | pds-w27-certify-the-round | non-disposition | wave-27 dispatch table row (task + round + what + gate); RETROACTIVE on the idiom `itself` |
| cd31e189f6b9 | 8281 | pds-w27-reader-transport-honesty | terminal | wave-27 shipped-slice table row with its PR #8410; RETROACTIVE on the idiom `guarded` |
| 77e4ccc36e5f | 10818 | pds-w35-background-write-arms | non-task | pds-w35-background-write-arms is a planned slug in a wave-35 dispatch table that was never filed - `bp task get` returns not_found; RETROACTIVE on the idiom `five` |
| 52e8aeef5276 | 11592 | pds-w35-elixir-census-gate | non-disposition | wave-35 dispatch table row, 'CUT from this wave's dispatch' - dispatch scope, not lifecycle; RETROACTIVE on the idiom `cut` |
| 41572551093f | 11940 | pds-w38-verdict-freshness-arm | non-disposition | PDS-D559 calls THREE CRITERIA defective - a criterion claim, the same reading the wave-39 reviewer gave this decision |
| 828bfe96a836 | 12051 | pds-bl-spill-dir-path-drift | non-disposition | the charter QUOTING this sweep's own finding ('charter is paid vs live open 0/4'), not asserting a disposition |
| 35da4917f854 | 12052 | pds-w20-crown-fire | non-disposition | same shape - the charter quoting the finding about pds-w20-crown-fire |
| edd0ae40ece1 | 12053 | pds-w34-census-cas-shadow | non-disposition | same shape - the charter quoting the self-contradiction it found at :9820 |
| 255737af37d5 | 12093 | pds-census | non-task | pds-census is a `needs:` CI job name, the same reading already given to pds-receipt-census |
| ed5cc3fcb7fa | 12323 | pds-w35-elixir-census-gate | non-disposition | 'criterion 8 is satisfiable only by a duration from an Actions run' - a criterion claim |
| 22e5602f0426 | 12373 | pds-w29-pay-lb | historical | 'is open at 12/14 with #8644 merged' - a ledger-state observation at that wave |
| b4201b2f3e72 | 12378 | pds-w25-round-open | non-terminal | 'are CLOSABLE TODAY' - the row is not closed and still carries the close act |
| 3959aa87618d | 12380 | pds-w25-round-bare | non-disposition | 'its own criterion 3 is stamped met claiming it is PARKED' - a criterion stamp claim |
| 6545ce378942 | 12382 | pds-bl-stale-open-rows-with-merged-prs | historical | 'is itself open at 0/4 since yesterday' - a dated ledger-state observation |
| 415ea6339d25 | 12407 | pds-w40-shares-remove-postread | non-disposition | wave-40 dispatch table row |
| d16a425432e4 | 12409 | pds-w40-residue-lens-can-fail | non-disposition | wave-40 dispatch table row |
| 1aff03d82cc6 | 12596 | pds-ledger-census.sh | non-task | pds-ledger-census.sh is a script filename; the sentence corrects an attribution to that FILE |
| 5d4150ca9d68 | 12714 | pds-record-parity.sh | non-task | pds-record-parity.sh is a script filename |
| 7919a4be61d2 | 12716 | pds-record-parity.test | non-task | pds-record-parity.test.sh is a script filename; the slug regex stops at the dot-segment |
| 1cc5e59de35d | 12723 | pds-w44-grant-door-narrowing | non-disposition | wave-44 dispatch table row |
| 6fc8f9cf1b66 | 12725 | pds-w44-door-census-instrument | non-disposition | wave-44 dispatch table row |
| 84185aad20b9 | 12726 | pds-w44-palette-harness-repair | non-disposition | wave-44 dispatch table row |
| 76f93bf48938 | 12729 | pds-w44-charter-sweep-adjudication | non-disposition | wave-44 dispatch table row; the row itself is now cancelled and superseded by pds-w45-bl-sweep-adjudication-frozen-blob, which does not change what this LINE asserts |
| 78aed6d46907 | 12747 | pds-door-census.sh | non-task | scripts/pds-door-census.sh is a script filename |
| 4ff5314b78b9 | 12921 | pds-scratch-target | non-task | pds-scratch-target_test.sh is a script filename; the slug regex stops before the underscore |
| 40cca8eef7a2 | 13114 | pds-scratch-target | non-task | pds-scratch-target_test.sh is a script filename |
| 4db5525ed73b | 13193 | pds-ledger-census | non-task | pds-ledger-census_test.sh is a script filename |
| b79ac6581cb7 | 13211 | pds-w45-grant-door-nonvacuity | non-disposition | wave-45 dispatch table row |
| d05eba940558 | 13212 | pds-w45-lega-argument-list | non-disposition | wave-45 dispatch table row |
| c9beed77cb07 | 13213 | pds-w44-judgment-coverage-ladder | non-disposition | wave-45 dispatch table row |
| 0964270bfa1c | 13214 | pds-w45-sweep-failopen | non-disposition | wave-45 dispatch table row |
| 1be9d39387f2 | 13216 | pds-w45-census-ledger-integrity | non-disposition | wave-45 dispatch table row |
| aaae540d6898 | 13218 | pds-w44-hetzner-offline-door | non-disposition | wave-45 dispatch table row |
