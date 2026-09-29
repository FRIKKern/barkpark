defmodule Barkpark.Content.CodelistsRegisterStatementTimeoutTest do
  @moduledoc """
  `Codelists.register/3` must not be cancellable by the pool-wide
  `statement_timeout` (task-e2f5ecca0be9a6d1, folded finding).

  Measured on guerrilla 2026-09-02, during a busy campaign hour: the OnixEdit
  boot seeder's Thema snapshot (~3,000 nodes, one cascading DELETE plus chunked
  INSERTs inside one transaction) died with ERROR 57014 `query_canceled` on the
  role's 60 s wall. A slot that cannot finish booting on a busy box is the
  incident feeding itself, and `config/runtime.exs` now sends a 30 s wall on
  every connection — so the registration transaction lifts the wall for its own
  statements with `SET LOCAL`.

  The proof below puts a hostile wall on the sandbox connection (a plain `SET`
  inside the sandbox transaction, rolled back with it), then registers a
  Thema-sized codelist. Without the `SET LOCAL … = 0` as the transaction's
  first statement the chunked INSERT of ~3,000 rows is cancelled and
  `register/3` returns `{:error, %Postgrex.Error{postgres: %{code:
  :query_canceled}}}` (mutation-proven 2026-09-02, and again 2026-09-15 at the
  wall below).

  ## Why the wall is 8 ms and not 1 ms (task-3482ecb5d7e0869c)

  This file used a 1 ms wall, and that wall cancelled ITS OWN LIFT. On
  pull_request run 34904651685 attempt 1 (job 104178484899, sha 85e430c01,
  2026-09-14T22:36:26Z) the first test below went red on a PR that does not
  touch this tree:

      ** (DBConnection.ConnectionError) connection is closed because of an error, disconnect or timeout
        (barkpark 0.1.0) lib/barkpark/repo.ex:216: Barkpark.Repo.retry_on_query_canceled/2
        (barkpark 0.1.0) lib/barkpark/repo.ex:164: Barkpark.Repo.set_local_statement_timeout!/1

  — preceded by `Postgrex.Protocol … disconnected: ** (Postgrex.Error) ERROR
  57014 (query_canceled)`. The cancelled statement was the LIFT, not the
  INSERT the lift protects, and it escalated past `retry_on_query_canceled/2`
  because a disconnected connection raises `DBConnection.ConnectionError`,
  which that retry does not rescue (it rescues `Postgrex.Error` only).

  A 1 ms wall was never survivable. Measured on a QUIET box, 2026-09-15
  (2,000 samples of `set_local_statement_timeout!(:infinity)`, Postgrex
  `query_time`): min 18 µs, p50 59 µs, p95 127 µs, p99 226 µs, p99.9 688 µs,
  **max 1,095 µs**. The lift's own tail crosses 1 ms with no load at all; CI
  load only moves a ~1-in-2,000 event into every other run.

  So the wall is chosen to sit between two MEASURED quantities, with both
  margins written down:

  | quantity (quiet box, 2026-09-15)                     | value     |
  |------------------------------------------------------|-----------|
  | lift `SET LOCAL statement_timeout`, worst of 2,000    | 1.095 ms  |
  | **the wall this file arms**                           | **8 ms**  |
  | smallest single chunk INSERT, 40 samples              | 27.1 ms   |

  Margin above the lift's worst case: **7.3×** (6.9 ms of absolute headroom,
  where the old wall sat BELOW it). Margin below the smallest statement the
  wall must still cancel: **3.4×** (19.1 ms). The second margin is the one
  that keeps this test from becoming a green with no subject, and it is the
  margin load makes SAFER, not riskier — a loaded box makes the INSERT slower,
  never faster. The only thing that could close it is faster hardware than the
  M-series box these numbers came from, and CI runners are slower.

  `@row_filler` is why the second margin exists at all. `@insert_chunk` in
  `Codelists` caps a statement at 2,000 rows, so the payload's node COUNT
  cannot make any single statement slower; only the row WIDTH can. With bare
  labels the smallest chunk statement measured 6.5 ms, which leaves no room
  above a 1 ms-class lift tail. A 4 KB `description` per translation and a
  4 KB `metadata` blob per value push the smallest chunk to 27.1 ms. The node
  count (3,000 values / 6,000 translations) and the tree shape are unchanged —
  the rows are just fat.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content.Codelists
  alias Barkpark.Content.Codelists.Codelist
  alias Barkpark.Repo

  @nodes 3_000

  # The hostile wall. MEASURED, not guessed — see the table in @moduledoc.
  @wall "8ms"

  # A statement the wall above is guaranteed to cancel (57014). Run-proven at
  # `@wall` on 2026-09-15: cancelled, having been given ~70 ms.
  @cancellable "SELECT count(*) FROM generate_series(1, 5000000)"

  # Row width, not row count, is what makes one chunked INSERT statement
  # outlast the wall — `Codelists.@insert_chunk` bounds every statement to
  # 2,000 rows regardless of @nodes. See @moduledoc.
  @row_filler String.duplicate("x", 4_000)

  defp thema_sized_values do
    for i <- 1..@nodes do
      %{
        code: "T#{String.pad_leading(Integer.to_string(i), 5, "0")}",
        metadata: %{"blob" => @row_filler},
        translations: [
          %{language: "eng", label: "Thema-sized node #{i}", description: @row_filler},
          %{language: "nob", label: "Thema-formet node #{i}", description: @row_filler}
        ]
      }
    end
  end

  test "register/3 lifts the connection's statement_timeout for its own transaction" do
    # ASYNC LEAK DETECTOR, and the reason `async: true` is still correct here.
    # `setup_sandbox/1` calls `start_owner!(Repo, shared: not async)`, so an
    # async test owns its own checkout and the plain `SET` below is scoped to
    # that connection and dies with the sandbox's ROLLBACK. If it ever leaked
    # into a pooled connection another test would arrive here carrying a wall
    # it never set, and this assertion is what would say so. Test-env ambient
    # is "0" (`config/runtime.exs` sends the 30 s parameter in :prod only) —
    # run-proven 2026-09-15.
    assert %{rows: [["0"]]} = Repo.query!("SHOW statement_timeout")

    # The wall every pool connection carries in prod, made hostile.
    Repo.query!("SET statement_timeout = '#{@wall}'")
    assert %{rows: [[@wall]]} = Repo.query!("SHOW statement_timeout")

    assert {:ok, %Codelist{list_id: "onixedit:thema-wall-proof"}} =
             Codelists.register("onixedit", "onixedit:thema-wall-proof", %{
               issue: "1.6",
               name: "Thema-sized wall proof",
               values: thema_sized_values()
             })

    # NOT asserted here: that the wall is back to @wall after register/3
    # returns. Under the SQL sandbox register/3's transaction is a SAVEPOINT
    # inside the test's own transaction, and Postgres scopes `SET LOCAL` to the
    # TOP-LEVEL transaction — releasing a savepoint does not revert it, so
    # `SHOW` reads 0 here until the sandbox rolls back. In prod register/3 owns
    # the top-level transaction and the LOCAL dies at its COMMIT; that
    # lifecycle is pinned by `Barkpark.Repo.StatementTimeoutTest` on
    # `with_statement_timeout/2`.

    assert %{rows: [[@nodes]]} =
             Repo.query!(
               "SELECT count(*) FROM codelist_values v JOIN codelists c ON c.id = v.codelist_id WHERE c.list_id = $1",
               ["onixedit:thema-wall-proof"]
             )
  end

  test "a lift the inbound wall cancels is retried inside its savepoint, and the transaction survives" do
    # THE FLAKE, made deterministic. On pull_request run 34904651685 attempt 1
    # (job 104178484899, sha 85e430c01, 2026-09-14T22:36:26Z) the test above
    # went red with 57014 raised at `Barkpark.Repo.set_local_statement_timeout!/1`
    # (repo.ex:164) — the `SET LOCAL` that LIFTS the wall was cancelled BY the
    # wall, before the ~3,000-row INSERT it protects ever ran. Racing a real
    # wall against a real `SET` is the coin-flip that made it a flake, so this
    # injects the same failure at the same seam: attempt 1 is a statement the
    # wall is GUARANTEED to cancel, issued with the SAME `mode: :savepoint` the
    # lift itself uses; attempt 2 is the real lift.
    #
    # The injection is what makes THIS test deterministic; it does not make
    # attempt 2 safe, because attempt 2 is a real lift under a real wall — so
    # this test races the same coin-flip the one above does, at the same @wall,
    # and it is load-proofed by the same measurement. (Corrected 2026-09-15:
    # the filing that opened task-3482ecb5d7e0869c said tests 2 and 3 were
    # unaffected. Test 3 is — its attempt 2 never reaches the server. Test 2 is
    # not: its attempt 2 is the lift, under the wall.)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    Repo.query!("SET statement_timeout = '#{@wall}'")

    assert {:ok, "0"} =
             Repo.transaction(fn ->
               Repo.retry_on_query_canceled(fn ->
                 case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
                   0 -> Repo.query!(@cancellable, [], mode: :savepoint)
                   _ -> Repo.set_local_statement_timeout!(:infinity)
                 end
               end)

               %{rows: [[in_force]]} = Repo.query!("SHOW statement_timeout")
               in_force
             end)

    assert Agent.get(attempts, & &1) == 2
  end

  test "mode: :savepoint is load-bearing — without it the cancelled attempt aborts the transaction" do
    # The mirror of the test above, and the non-vacuity guard for the retry:
    # the SAME injected 57014, differing ONLY in that attempt 0 does not carry
    # `mode: :savepoint`. DBConnection marks the transaction :aborted the moment
    # an unguarded query in it errors, so the retry never gets to run — the
    # retry ALONE does not save the lift; the savepoint is what makes the retry
    # reachable.
    #
    # It also pins `mode: :savepoint` on the lift's OWN query in
    # `Repo.set_local_statement_timeout!/1`, which is attempt 1 here: with the
    # option DBConnection refuses the statement locally
    # (`DBConnection.TransactionError`); delete the option from repo.ex and the
    # statement reaches the server instead, which answers `Postgrex.Error` 25P02
    # `in_failed_sql_transaction` — a different exception, so this assertion
    # goes RED. That matters because the sandbox does NOT hand us the option:
    # `Ecto.Adapters.SQL.Sandbox.maybe_savepoint/2` appends `mode: :savepoint`
    # only when `not in_transaction?`, and the lift ALWAYS runs inside
    # register/3's transaction. (Corrected: the predecessor WIP claimed the
    # opposite — that the sandbox made the option invisible.)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    Repo.query!("SET statement_timeout = '#{@wall}'")

    assert_raise DBConnection.TransactionError, fn ->
      Repo.transaction(fn ->
        Repo.retry_on_query_canceled(fn ->
          case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
            # no `mode: :savepoint` — the only difference from the test above
            0 -> Repo.query!(@cancellable)
            _ -> Repo.set_local_statement_timeout!(:infinity)
          end
        end)
      end)
    end
  end

  test "the wall really does cancel a statement of that size on this connection" do
    # Non-vacuity guard for the test above: the same wall, the same shape, run
    # WITHOUT register/3's opt-out, must be cancelled by the server — otherwise
    # the first test would pass with the opt-out deleted.
    Repo.query!("SET statement_timeout = '#{@wall}'")

    assert {:error, %Postgrex.Error{postgres: %{code: :query_canceled}}} =
             Repo.query(@cancellable)
  end
end
