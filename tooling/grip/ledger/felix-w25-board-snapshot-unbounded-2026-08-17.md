<!-- doc-tier: cold | canonical-for: felix-w25-board-slice-pin re-derivation | budget: 400tok -->

# Felix W25 — board.ex snapshot unbounded Repo.all (re-derivation)

Verdict: STILL-LIVE on origin/main as of 2026-08-17. board.ex last touched 2026-07-23 (#5914), no fence collision.

## The scar

`Barkpark.Tasks.Board.load_task_docs/1` (board.ex:210-213) runs
`from(d in Document, where: d.type == "task" and d.dataset == ^dataset) |> Repo.all()`
— NO `limit:`. `snapshot/1` (line 156) is the LiveView reconcile source (board_live.ex:212 mount + :refresh every 15s). Its HTTP twin `Query.docs_for_query/2` (query.ex:241,244) clamps `limit: ^clamp_limit(...)` at @rows_default_limit 500 / @rows_max_limit 1000. Named failure mode: "bounded HTTP reader has an unbounded LiveView twin."

## Timer (was docstring-only, now proven)

board_live.ex:189 `@refresh_ms 15_000`; :refresh rearmed by `Process.send_after(self(), :refresh, @refresh_ms)` at line 201 (mount, connected only) and line 301 (handle_info :refresh, line 300). Each fire calls `Board.snapshot(dataset:)` (line 308). So the unbounded read repeats every 15s per connected socket.

## Reuse path

- `clamp_limit/1` (query.ex:860-869) is `defp` — NOT reusable cross-module. `@rows_default_limit`/`@rows_max_limit` are private module attrs.
- `collapse_twins/1` (query.ex:132) IS public but SQL NOT-EXISTS form; board collapses in Elixir via `Content.published_id` group_by + published-wins (board.ex:214-216, canonical_twin). Semantically different — swapping is a behavior change, out of scope.
- Ordering trap: board bounds must respect that twin-collapse runs AFTER Repo.all in Elixir. A naive `limit:` truncates raw rows before collapse. Safest slice = a high safety cap (e.g. reuse @rows_max_limit value via an extracted public `Query.max_rows/0` OR a board-local @snapshot_max), NOT pagination.

## Mutation proof shape

`cards_by_id` is the FULL uncapped live set (board.ex:393). Seed cap+1 distinct live (non-cancelled, non-twin) task docs → `Board.snapshot(dataset: "production")` → assert `map_size(board.cards_by_id) <= cap`. Reds on current unbounded form (=cap+1), greens after bound. board_test.exs setup already `Repo.delete_all` the whole task corpus (hermetic).

## Rerun

    git show origin/main:api/lib/barkpark/tasks/board.ex | sed -n '210,216p'
    git grep -n '@refresh_ms\|send_after' origin/main -- api/lib/barkpark/plugins/tasks/web/board_live.ex
    cd api && mix test test/barkpark/tasks/board_test.exs   # 6 tests, 0 failures
