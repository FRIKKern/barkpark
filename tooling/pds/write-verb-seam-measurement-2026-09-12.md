# The write-verb seam vs `stub_mapping_only`'s falsifier — the measurement

Task: `pds-bl-w37-persist-fun-seam-defeats-the-falsifier`
Measured at sha `f072865bbd7002aa55eb64d4293c10840ad694fa` (origin/main, 2026-09-12).
Every integer below names its lens and was re-derived at that sha; nothing is transcribed
from the task row.

## The row's premise, checked

The row says `api/lib/mix/tasks/barkpark.rehydrate_body_html.ex:376` binds
`persist_fun = Keyword.get(opts, :persist_fun, &Repo.update/1)`.

**CONFIRMED, no line drift.** Lens `grep -n 'persist_fun' api/lib/mix/tasks/barkpark.rehydrate_body_html.ex`
at that sha prints `376:    persist_fun = Keyword.get(opts, :persist_fun, &Repo.update/1)`.
`376` is the only integer the row quotes.

The row's structural claim is also correct: this is the ONLY seam in `api/lib` whose
default is a Repo WRITE verb. Lens
`grep -rnE 'Keyword\.(get|fetch)[^)]*&Repo\.(update|insert|delete|insert_or_update)' api/lib`
→ **1** hit, the line above.

And the interaction it describes is real. `scripts/pds-elixir-receipt-census.exs`'s
`stub_mapping_only` arm reds on `"#{ev} DOES read Repo"` where `repo?` is a substring
probe (`@repo_tokens`) over the cited block and its same-file helpers. A test that injects
`:persist_fun` and then reads a row back through `Repo.` satisfies that probe while the
production write verb was never executed.

## What the row gets WRONG: the free pass does not exist today

The row's consequence — "the Repo half gives this site a free pass" — assumes a
`stub_mapping_only` row can cite a seam-injecting test and reach the Repo half. It cannot,
for two independently measured reasons.

**(1) No `stub_mapping_only` row cites a seam-injecting file.**
Lens `grep -c 'basis: :stub_mapping_only,' scripts/pds-elixir-receipt-census.exs` → **8**
rows. Lens `grep -A1 'basis: :stub_mapping_only,' … | grep -o '"api/test/[^"]*"' | sort -u`
→ **1** distinct cited path,
`api/test/barkpark_web/controllers/github_webhook_controller_test.exs`.
(The census's own prose says "all 6 top-level `stub_mapping_only` rows"; the raw grep
counts 8 because two of the register entries are not top-level. Both numbers describe the
same single citation path — the discrepancy is a counting lens, not a disagreement.)
Lens `grep -rln 'persist_fun:' api/test` → **1** file,
`api/test/barkpark/papers/body_html_render_version_test.exs`. The two sets are disjoint.

**(2) The arrival tripwire fires BEFORE the Repo half.**
`judge_citation/4`'s `:stub_mapping_only` arm is a `cond` whose FIRST clause is
`path not in @stub_citation_allowlist -> [finding(r, :reds, …)]`. `@stub_citation_allowlist`
is a **1**-element list at `:13154` naming the github webhook controller test. So a row
citing `body_html_render_version_test.exs` REDS on arrival and never evaluates `repo?`.

There is a third, smaller correction. The one committed injecting test does not even
exercise the hazard: its `persist_fun` calls `Repo.update(changeset)` for every row except
the one it deliberately fails, so its `reload(successful)` DOES observe a real Repo write.
The hazard is a property of the SEAM, not of any test standing on it today.

## So the hazard is LATENT, and the fragile part is the allowlist

The census's own remedy text for an allowlist red is *"RE-MEASURE the widened probe against
this file, then widen the allowlist."* Following that instruction with a seam-injecting test
is exactly the step that opens the free pass, and nothing in the loop warns about it.

## What was built

`api/test/barkpark/pds_write_verb_seam_test.exs` — reds when the set of test files injecting
a Repo WRITE verb intersects `@stub_citation_allowlist`. It reads the allowlist out of the
census SOURCE rather than transcribing it, carries three positive controls (an empty seam
scan, an empty injection scan or an empty allowlist parse each fail loudly rather than
greening the guard), and carries a fixture-tree negative control proving the predicate can
red.

The census script itself is NOT edited: it is saturated by two open PRs (#17856, #17872).
The narrowing question the row raises — whether `stub_mapping_only`'s falsifier should gain
a `write-verb-injected` arm that no Repo read can clear — is left OPEN and is recorded as a
REQUEST in the PR body. The guard makes the day that question becomes urgent impossible to
miss; it does not answer it.

## Addendum — the guard's own door-census collision (own defect, caught in CI)

The first push bound the census path as `@census_rel "../../../scripts/pds-elixir-receipt-census.exs"`.
`scripts/pds-door-census.sh`'s leg-A classifier reads **every** quoted `("../")+…pds-…` literal under
`api/lib` + `api/test` (prefilter at `classify_refs`, grep
`'"(\.\./)+[^"]*pds-[^"]*"'`) and demands that an attribute-bound one be dereferenced into
`System.cmd`/`Port.open`. Anything else is `BOUND-UNEXEC` — *"attribute-bound but executed by nothing
— a door pointed at nothing"*.

This case READS the census as a source file and must never EXECUTE it, so it can never satisfy that
demand. The binding therefore reclassified `scripts/pds-elixir-receipt-census.exs` from **THROUGH**
to **ERROR**, which in turn ORPHANED its row in `PDS_DOOR_PRICES` (read at exactly one site, inside
the THROUGH branch) — **2 error rows from one module attribute**, both own, neither inherited
(main + charter tree reads `ERROR rows : 0 of 44`).

The repair is the ROOT-ANCHOR idiom that `scripts/elixir-path-escape-check.sh` already documents for
its `-root` door: `@repo_root Path.expand("../../..", __DIR__)` bound once, then `Path.join` at each
read site. No `"../"` literal contains `pds-` any more, so the door census has nothing to classify,
while the escape check still resolves the repo-root read. Both instruments green:
`ERROR rows : 0 of 44` and `OK: every repo-root read from api/lib + api/test is dispatched on.`

**The transferable rule:** under `api/lib` + `api/test`, a `"../…pds-…"` string literal is a CLAIM
that the file is a door. A test that reads a pds instrument as DATA must not make that claim — anchor
the root and join the name.
