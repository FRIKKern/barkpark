# Re-derivation recipes — docs/decisions/success-claim-census.md @ origin/main 29cb76e60

Lens: AST census, depth 6, Elixir 1.19.5 / OTP 28, macOS aarch64. Host load avg 36-67
during measurement (NOT quiet — see the runtime row).

Setup (every recipe below assumes it):

    D=$(mktemp -d); git -C <repo> archive origin/main | tar -x -C $D; cd $D

| doc line | claim | derives to | rerun |
|---|---|---|---|
| :1 | `budget: 3200tok` | DECORATIVE — 0 hits in the budget gate | `grep -c success-claim-census scripts/check-doc-budgets.sh` → 0 |
| :30 | 17 registry rows | 42 rows / 19 requiredEnrollments today (`:30` is TRUE AS DATED) | `awk '/func successClaimRegistry\(\)/,/^}/' internal/cli/success_claim_registry_test.go \| grep -c 'Name:'` → 42 |
| :38 | vercel_cmd 13 checkmarks, 0 quoted-glyph | 13 ✓; all 13 ARE inside quoted format strings | `grep -c '✓' internal/cli/vercel_cmd.go` → 13 ; `grep -o '"[^"]*✓' internal/cli/vercel_cmd.go \| wc -l` → 13 |
| :63 | 23 glyphs / 12 files (.sh) | 24 / 12 | `grep -ro '✓' --include='*.sh' . \| wc -l` → 24 |
| :68 | proof harnesses 12, "4 each" | 13; 4 / 5 / 4 | `grep -ro '✓' --include='*.sh' deploy \| sed 's/:.*//' \| sort \| uniq -c` |
| :82 | 20 of 23 harness plumbing | 21 of 24 | derived from :63 + :68 |
| :90 | 48 glyphs / 17 files in api/lib | 48 / 17 ✓ | `grep -ro '✓' api/lib \| wc -l` ; `grep -rl '✓' api/lib \| wc -l` |
| :121 | corpus 804 | 804 ✓ | `find api/lib -name '*.ex' \| wc -l` |
| :122 | "~5 s" | 21.8 / 40.8 / 30.1 s wall, 12.0-14.0 s USER; script self-prints its wall clock | `elixir scripts/pds-elixir-receipt-census.exs \| tail -2` |
| :126 | textual 103, 102 lines | 104 occurrences, 103 lines | `grep -roE 'ok: true\|"ok" => true' --include='*.ex' api/lib \| wc -l` → 104 |
| :127 | AST-literal 95 | 95 ✓ | census `THE POPULATION` block |
| :128 | phantoms 8 | 9 | census `phantoms` row |
| :129 | consumers 4 | 4 ✓, all four cited lines exact | census `consumers` block |
| :130 | emitted 91 | 91 ✓ | census `EMITTED success claims` |
| :135 | depth 3 = 33/12/46 | 34/20/37 | census `depth 3` row |
| :135 | depth 6 = 42/14/35 | 54/14/23 (read 14 is CORRECT) | census `depth 6` row |
| :141 | 35 reach no Repo verb | 23 | census `unrouted` |
| :143 | classified 44 + unclassified 47 | 18 + 73 | census `CLASSIFICATION-TOTAL` |
| :144 | POST-READ 17 | 15 (NOT 14 — 14 is the pre-#8886 tree) | census SHAPE block |
| :144 | UNREACHABLE-ERROR 27 | SHAPE GONE — renamed CATCH-ALL-TO-SUCCESS, 3 fired | census SHAPE block |
| :144 | UNCLASSIFIED 47 (×2) | 73 | census SHAPE block |
| :151 | 218 / 66 / 3 blind spots | 218 ✓ / 66 ✓ / 3 ✓ | `grep -ro 'json(conn,' --include='*.ex' api/lib \| wc -l` → 218 |
| :156 | -P / BSD -E / rg return 97 | 99 (literal spelling), 103 lines (union) | `rg -c 'ok: true' -g '*.ex' api/lib \| awk -F: '{s+=$2} END{print s}'` → 99 |
| :158 | "27 carrier files" | 25 AST / 26 literal / 28 textual — false under all three | census `carrier files` row |
| :158 | refusal exits 2 | RC=2 ✓ (direct, not through a pipe) | `grep -rl 'ok: true' api/lib --include='*.ex' > /tmp/c.txt; elixir scripts/pds-elixir-receipt-census.exs --files-from /tmp/c.txt; echo RC=$?` |
| :159 | five write verbs in close.ex | ZERO. Live analogue = internal.ex :57 / :386 | `grep -cE 'Repo\.(insert\|update\|delete)' api/lib/barkpark/tasks/close.ex` → 0 |
| :160 | mutation reds the arm | REPRODUCES at internal.ex: FAIL + RC=1 | neuter `Repo.update_all` AND `Repo.insert!` in api/lib/barkpark/tasks/internal.ex, rerun census |
| :161 | update_all-only stays green | REPRODUCES: RC=0, PASS at depth 2 via `Repo.insert!` | neuter only `Repo.update_all` in internal.ex, rerun census |
| :166 / :182 | "three integrity checks that can go red" | FIVE arms ship; CORPUS-INTACT is structurally unreachable (`guard_corpus!` :261 halts 2 on the exact negation of the arm at :1582) | `grep -n '@corpus_floor\|CORPUS-INTACT' scripts/pds-elixir-receipt-census.exs` |

STRUCTURAL, not an integer: the doc carries ZERO route-axis content. Only controller
mention is `auth_controller.ex:351` (a double-count parenthetical); `route` appears only
as "route-bearing sentinels" / "write-routed".

    grep -niE 'route|endpoint|/v1/|controller' docs/decisions/success-claim-census.md

BUDGET: 11982 B today; 12800 B leaves 818 B. Retiring the :30-34 first-ship roster buys
313 B → 1131 B. Lens+sha suffixes over ~22 lens-derived numbers ≈ 286 B. That funds the
annotations plus ~845 B of route-axis PROSE — not a per-site table.
