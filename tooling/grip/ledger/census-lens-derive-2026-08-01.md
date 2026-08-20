# Re-derivation recipes — census-lens-derive (PDS wave 33, 2026-08-01)

Verifier lane `census-lens-derive`. Question: how many of `api/lib`'s **102**
`ok: true` sites are WRITE RECEIPTS, how many are READ ENVELOPES, what can the
lens not see — and which of the two surveyor splits on `tasks_controller.ex`
(10r/14w vs 11r/13w) is right?

Everything below reads `origin/main` (re-confirmed at `c48fb17d5`: 102 lines / 27 files / 24 in `tasks_controller.ex`) or a
`git archive origin/main api/lib` export into `$S/full/lib`. **The AST work is
build-free** — `Code.string_to_quoted/2`, ~3.4 s over 804 `.ex` files, no `mix
compile`, so it dodges the recorded local-OOM scar. No repo file outside this
ledger row was modified; the close.ex mutation ran on the scratch export and was
restored.

    S=<scratchpad>
    rm -rf $S/full && mkdir -p $S/full \
      && git archive origin/main api/lib | tar -x -C $S/full \
      && mv $S/full/api/lib $S/full/lib

Scripts live at `$S/census2.exs` (lens A + population) and `$S/full/semantic.exs`
(lens B). Both are verifier carve-outs, NOT in the repo. A builder should
re-author them as `api/test/` or `scripts/` artefacts when the census lands.

## The headline numbers

| Quantity | Value | How |
|---|---|---|
| `git grep` LINES (broad alternation) | **102** across 27 files | `git grep -nE 'ok: true\|"ok" *=> *true' origin/main -- api/lib \| wc -l` |
| textual OCCURRENCES | **103** | `auth_controller.ex:351` carries two on one line |
| AST-literal pairs (real code) | **95** | `elixir census2.exs` → `AST_LITERAL_TOTAL` |
| non-code phantoms | **8** | 7 `@doc`/comment prose + 1 WRONG KEY (`%{db_ok: true}`, `ops_live.ex:285`) |
| CONSUMERS, not emitters | **4** | all 4 `"ok" => true` sites: `bridge_client.ex:66,83,97` + `pusher.ex:286` pattern-match a REMOTE response |
| **emitted success bodies** | **91** | 95 − 4 |
| **WRITE RECEIPTS** | **64** | lens A over the 91 |
| read envelopes | 17 | lens A |
| unrouted (lens A blind) | 10 | plugin routes outside the scanned files + `github_webhook` internals |
| `tasks_controller.ex` | **11 read / 13 write** (24 sites) | lens A **and** lens B, independently |

## Re-derivation table

| # | Claim | Command |
|---|---|---|
| 1 | 102 lines / 27 files; 98 atom-form lines + 4 string-form lines, zero overlap | `git grep -nE 'ok: true\|"ok" *=> *true' origin/main -- api/lib \| wc -l`; `git grep -lE ... \| wc -l`; `git grep -nE '"ok" *=> *true' origin/main -- api/lib` |
| 2 | **THE LENS TRAP, reproduced on this host.** Same pattern, same corpus: `git grep -E '\bok: true'` returns **0**, `git grep -P` returns **97**, BSD `/usr/bin/grep -rE` returns **97**, `rg` returns **97**. Apple git's POSIX ERE has no `\b`; it matches nothing, exits 1, prints no error. A census shipped with the `-E` form under-reports **100%** while looking clean | `git grep -cE '\bok: true' origin/main -- api/lib \| awk -F: '{s+=$NF} END{print s+0}'` vs the same with `-cP`; `/usr/bin/grep -rcE '\bok: true' $S/full/lib`; `rg -c '\bok: true' $S/full/lib` |
| 3 | 8 of the 102 lines are not code: prose in `stage.ex:76`, `auth_controller.ex:404`, `bulldocs_intents_controller.ex:42`, `github_adopt_controller.ex:20,21`, `github_status_controller.ex:35`, `github_webhook_controller.ex:39`; plus `ops_live.ex:285` `%{db_ok: true}` — a DIFFERENT KEY | `elixir census2.exs` → the `DELTA` rows; then `/usr/bin/grep -nE 'ok: true' <file>` on each |
| 4 | All 4 `"ok" => true` sites are inbound-response pattern matches (`case post(...) do {:ok, %{"ok" => true} = body}`) — consumers of a FOREIGN receipt. Any census counting them as Barkpark receipts is wrong by construction | `git show origin/main:api/lib/barkpark/connectors/bridge_client.ex \| sed -n '60,100p'` |
| 5 | **LENS A (route method).** Parse `router.ex` + all 9 `def register_routes` files, build `{controller, action} → http verbs`, map each site to its enclosing `def`, resolve `defp` helpers to their public callers. 370 routes, 273 distinct controller actions | `cd $S && elixir census2.exs` |
| 6 | `tasks_controller.ex` = **24** AST sites, **11 read / 13 write** | `elixir census2.exs` → `TC_SPLIT %{read: 11, write: 13}` |
| 7 | **THE ORIGIN OF THE 10/14 vs 11/13 SPLIT is an attribution bug, not a judgement call.** The obvious `awk '/^  def /{d=$0}'` lens attributes L587 to `def release` (551) because `close`'s receipt lives in `defp close_response` (585) — `^  def ` cannot match `defp`. `close` and `index` never appear as owners at all. Both are POST, so the awk lens still totals 11/13 by luck; any surveyor who hand-corrected one of the two misattributed lines lands on 10/14 | `git show origin/main:api/lib/barkpark_web/controllers/tasks_controller.ex \| awk '/^  def /{d=$0} /ok: true/{print NR": "d}'` — note L558 and L587 BOTH print `def release` |
| 8 | `defp task_list_response` (L83) serves **two** actions, `index` + `ready`, both GET — one site, two owners. This is why 24 sites ≠ 24 actions (25 routed actions exist) | `elixir census2.exs` → `L  83  read  defp task_list_response  owners=index+ready` |
| 9 | **LENS B (semantic).** Controller def → remote calls → resolve module → does the callee reach `Repo.{update_all,insert,insert_all,update,delete,delete_all,transaction}`? Agrees with lens A on **25/25** actions → 12 read / 13 write actions, i.e. the same 11/13 over sites | `cd $S/full && elixir semantic.exs` → `agree=25 disagree=0` |
| 10 | **Lens B is MUTATION-PROVEN able to go red.** Replacing all 5 write-verb calls in `close.ex` flips `close` `true → false` and `agree` `25 → 24`; restoring flips it back. The FIRST attempt (mutating only the 3 `Repo.update_all`) left `close` green — correctly, because `Repo.transaction` at :167,:282 still writes. An incomplete mutation reads exactly like a lens that cannot fail | `python3 -c "…re.sub(r'Repo\.(update_all\|insert_all\|insert\|update\(\|delete_all\|delete\|transaction)', r'Repo.fake_\1', s)…"` on `$S/full/lib/barkpark/tasks/close.ex`, then `elixir semantic.exs` |
| 11 | **A naive Elixir port of the Go symbol-binding arm is a GREEN THAT CANNOT GO RED, twice over.** (a) Run it on a corpus of only the 27 carrier files → **every** action returns `false`, `LENS_B read=25 write=0`, no error. (b) Fix the corpus and it still returns 24/25 `false`, because `Barkpark.Tasks` is a **24-`defdelegate` facade** and `defdelegate` is not `def`. Only after following delegates does the lens agree with lens A | run `semantic.exs` against `$S/lib` (27 files) vs `$S/full/lib` (804 files); `/usr/bin/grep -cE 'defdelegate' $S/full/lib/barkpark/tasks.ex` → 24 |
| 12 | **WHAT THE LENS CANNOT SEE.** 218 `json(conn, …)` lines across 50 files; 273 `put_status(` lines of which **66** carry a 2xx status (`:created` 35, `:ok` 13, `:accepted` 13, numeric `201` 5); **3** `send_resp(conn, 2xx…)`. The digest's "53 put_status" and "4 empty-2xx" do **not** re-derive — the true figures are 66 and 3 | `git grep -nE 'json\(conn,' origin/main -- api/lib \| wc -l`; `git grep -hoE 'put_status\((conn, )?:[a-z_]+' origin/main -- api/lib \| sed 's/.*://' \| sort \| uniq -c \| sort -rn`; `git grep -nE 'send_resp\(conn, 2[0-9][0-9]' origin/main -- api/lib \| wc -l` |
| 13 | **`Repo.reload` appears ZERO times in all of `api/lib`**, against **85** `Repo.update_all`. Nothing in the Elixir write surface re-reads a row through the canonical reload verb — the POST-READ bucket is empty by that spelling and must be sought as `Repo.get`/`Repo.one` if it exists at all | `git grep -cE 'Repo\.reload' origin/main -- api/lib`; `git grep -nE 'Repo\.update_all' origin/main -- api/lib \| wc -l` |
| 14 | The 64 write receipts by file: `auth_controller` 11, `bulldocs_ingest` 9, `github_webhook` 7, `search` 5, `media` 3, `webauthn` 3, `tasks_controller` **13**, and 9 files with 1–2 each | `elixir census2.exs` → the `WRITE-RECEIPT sites by file` table |
| 15 | Lens A's method proxy holds on `search_controller`: all 5 write-classified sites (`reindex`, `delete_search_synonym`, `search_interaction`, `correction`) genuinely mutate — no POST-shaped-read false positive there | `git show origin/main:api/lib/barkpark_web/controllers/search_controller.ex \| /usr/bin/grep -nE 'ok: true\|^  def '` |
| 16 | Charter **PDS-D445 limit (7)** authorises exactly the figures cited: "102 `ok: true` success bodies across 27 files and 218 `json(conn, …)` responses across 50 files", and rules the prior glyph lens structurally blind | `git show origin/main:.claude/workflows/bp-pds-charter.md \| sed -n '7840,7866p'` |

## Boundary of this lane

Lens A resolves `defp` helpers to public callers by NAME, so a receipt built into
a variable and `json`-ed later is counted (correct) but its `emitted?` flag reads
false — 7 of 11 `NOT-EMITTED` rows are that false negative, not real helpers.
Lens A's controller↔route match keys on the LAST module alias segment, so
`MediaController` and `V1.MediaController` are indistinguishable to it. Lens B
follows `defdelegate` and one remote hop at depth ≤ 3; a write reached through a
4th hop, a `Task.async`, or an Oban worker is invisible to it. Neither lens says
anything about whether a write receipt is a POST-READ, a CAS-CONFIRMED ECHO, a
PURE ECHO or an UNREACHABLE-ERROR — that classification is the next lane's work,
over the **64**, not over the 102.
