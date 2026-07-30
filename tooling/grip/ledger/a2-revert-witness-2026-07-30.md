# Re-derivation recipes — A2 revert witness (PDS wave 26, 2026-07-30)

Verifier lane `a2-revert-witness`. Question: does `bp doc patch` → `bp task stamp`
→ `bp doc publish` actually erase a landed acceptance criterion, **observed**
rather than derived? And does `drafts.pds-bl-tagregistry-guard-no-rung` exist?

Everything below was run live against `guerrilla.barkpark.cloud` with
`bp` build `2c94b0ba7`, or read from `origin/main` `3693f2541`. **No command below
is piped** — the `cmd | tail` exit-code trap is the recorded cause of the
"silent" stamp failures this epic chased.

Two scratch rows were created and retired: `task-ea0f40a603e00dbf` (the revert
witness) and `task-ad2ab343da6a88d0` (the guard-boundary complement). Both are
`cancelled`. The pre-existing scratch row `task-fc21e82beaefbb86` (`w26probe`)
was also retired. **No `pds-*` row was written to.**

| # | Claim | Command |
|---|---|---|
| 1 | Both halves of the disputed row exist RIGHT NOW: published `done` with 1113 B of stamped evidence across 3 met criteria, and a draft twin born 19:29 today, `open`, 0 met, 0 B evidence | `bp doc get task pds-bl-tagregistry-guard-no-rung --perspective published -o json; bp doc get task drafts.pds-bl-tagregistry-guard-no-rung --perspective raw -o json` |
| 2 | `bp task stamp` writes the **published** row directly and leaves the `drafts.` twin byte-identical (its `_rev` does not move) | `bp task stamp <scratch> <worker> 1 --criterion 0 --met --evidence "…" --criterion-text "…" --yes -o json; bp doc get task drafts.<scratch> --perspective raw -o json` |
| 3 | OBSERVED L1: a `bp doc publish` of a claim-identical stale draft erases the stamp — `met:true` → `met:false`, `evidence:""` — and returns **rc=0** with a normal `{"results":[…]}` envelope and no warning | full sequence in row 4 |
| 4 | The full witness sequence, every step un-piped, rc captured | `bp task create … --publish --yes` → `bp doc patch task <id> --set main_tag/tags/description` → `bp doc publish task <id> --yes` → `bp task claim <id> <worker> --yes` → `bp doc patch task <id> --set purpose=X --yes` (mints the stale draft) → `bp task stamp <id> <worker> 1 --criterion 0 --met --evidence "TRACER" --criterion-text "…" --yes` → `bp task get <id> -o json` (met:true) → `bp doc publish task <id> --yes` → `bp task get <id> -o json` (met:false) |
| 5 | Staleness **compounds**: a SECOND `bp doc patch` does NOT rebase the draft on the current published row. A tracer stamped after the first patch is still absent from the draft after the second patch, so every draft-door write inherits the original mint base | stamp crit0 → `bp doc patch --set purpose=X` → stamp crit1 → `bp doc patch --set purpose=Y`, then read `results[0].document.acceptance_criteria` from the second patch's envelope |
| 6 | Selective erasure confirms the base: publishing erased ONLY the criterion stamped after the mint (`TRACER-B`) and preserved the one stamped before it (`TRACER-A`) | `bp task get <id> -o json` before and after `bp doc publish task <id> --yes` |
| 7 | The publish-door task gate reads `lifecycle_status` ONLY — `acceptance_criteria` are not consulted anywhere in it | `git show origin/main:api/lib/barkpark/content/lifecycle.ex \| sed -n '294,315p'` |
| 8 | `publish_document` replaces the published row's content **wholesale** from the draft (`"content" => pub_content`); the only rev fence in the transaction is `fenced_delete(draft)` — on the DRAFT | `git show origin/main:api/lib/barkpark/content/lifecycle.ex \| sed -n '155,200p'` |
| 9 | `done → open` is an explicitly legal transition, so the lifecycle gate cannot stop a reopen-shaped revert | `git show origin/main:api/lib/barkpark/tasks/transitions.ex \| sed -n '60,70p'` |
| 10 | **The boundary.** `stale_claim?/2` refuses a draft whose `claim` map differs from the published row's. A draft minted BEFORE the claim is REFUSED (`rc=5 validation_failed`, stamp intact). A draft minted AFTER the claim is claim-identical, passes, and erases. That is the whole hole | `git show origin/main:api/lib/barkpark/content/lifecycle.ex \| sed -n '310,314p'`; live: patch → claim → stamp → `bp doc publish task <id> --yes -o json` |
| 11 | The CLI drops the guard's teaching text: the refusal prints only `task content failed validation` / `Fix the listed validation errors to match the schema` — the `"stale draft: the published row carries claim state …"` field message never reaches the operator | `bp doc publish task <pre-claim-draft-row> --yes -o json` |
| 12 | 336 `drafts.` task twins exist on guerrilla; only 20 have a published counterpart; 8 of those pair a terminal published row with a non-terminal draft. Exactly ONE is a `pds-*` row | `bp task ls --all -o json`, then pair `drafts.X` against `X` on `lifecycle_status` |
| 13 | Evidence at stake on those 8, and the guard verdict for each: all 7 with a real loss are claim-divergent, so a plain `bp doc publish` REFUSES them today (derived from row 10's predicate, not executed against live rows) | `bp doc get task <id> --perspective published -o json` + `bp doc get task drafts.<id> --perspective raw -o json`, compare `claim` maps and sum `acceptance_criteria[].evidence` lengths |
| 14 | `bp task close`'s `doc_changed_since_claim` 409 hint promises "the 409 body names current_rev + changed_fields" — the body carries neither; it is `{"error":{"code","hint","message"}}` only | `bp task close <stale-claim-row> <worker> <epoch> cancelled "…" --yes -o json` |
| 15 | Prior art `pds-bl-stamp-writeback-reverts-a-stamped-criterion` is `open` and says "Suspect a lost update between the stamp write and a concurrent publish/patch on the same doc" — rows 3-6 confirm that suspicion at L1 | `bp search query "stamp writeback reverts"`; `bp doc get task pds-bl-stamp-writeback-reverts-a-stamped-criterion --perspective published -o json` |
| 16 | PDS-D313's A2 justification reads verbatim "the response IS the record; a second GET reads the same row" | `git show origin/main:.claude/workflows/bp-pds-charter.md \| sed -n '4594,4612p'` |
