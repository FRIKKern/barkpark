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

  The proof below puts a 1 ms wall on the sandbox connection (a plain `SET`
  inside the sandbox transaction, rolled back with it), then registers a
  production-shaped Thema-sized codelist. Without the `SET LOCAL … = 0` as the
  transaction's first statement the chunked INSERT of ~3,000 rows is cancelled
  and `register/3` returns `{:error, %Postgrex.Error{postgres: %{code:
  :query_canceled}}}` (mutation-proven 2026-09-02 by deleting that one line).
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content.Codelists
  alias Barkpark.Content.Codelists.Codelist
  alias Barkpark.Repo

  @nodes 3_000

  # A statement the 1 ms wall below is guaranteed to cancel (57014).
  @cancellable "SELECT count(*) FROM generate_series(1, 5000000)"

  defp thema_sized_values do
    for i <- 1..@nodes do
      %{
        code: "T#{String.pad_leading(Integer.to_string(i), 5, "0")}",
        translations: [
          %{language: "eng", label: "Thema-sized node #{i}"},
          %{language: "nob", label: "Thema-formet node #{i}"}
        ]
      }
    end
  end

  test "register/3 lifts the connection's statement_timeout for its own transaction" do
    # The wall every pool connection carries in prod, made hostile: 1 ms is
    # below what a ~3,000-row (+6,000 translations) INSERT can finish in.
    Repo.query!("SET statement_timeout = '1ms'")
    assert %{rows: [["1ms"]]} = Repo.query!("SHOW statement_timeout")

    assert {:ok, %Codelist{list_id: "onixedit:thema-wall-proof"}} =
             Codelists.register("onixedit", "onixedit:thema-wall-proof", %{
               issue: "1.6",
               name: "Thema-sized wall proof",
               values: thema_sized_values()
             })

    # NOT asserted here: that the wall is back to 1ms after register/3 returns.
    # Under the SQL sandbox register/3's transaction is a SAVEPOINT inside the
    # test's own transaction, and Postgres scopes `SET LOCAL` to the TOP-LEVEL
    # transaction — releasing a savepoint does not revert it, so `SHOW` reads 0
    # here until the sandbox rolls back. In prod register/3 owns the top-level
    # transaction and the LOCAL dies at its COMMIT; that lifecycle is pinned by
    # `Barkpark.Repo.StatementTimeoutTest` on `with_statement_timeout/2`.

    assert %{rows: [[@nodes]]} =
             Repo.query!(
               "SELECT count(*) FROM codelist_values v JOIN codelists c ON c.id = v.codelist_id WHERE c.list_id = $1",
               ["onixedit:thema-wall-proof"]
             )
  end

  test "a lift the inbound wall cancels is retried inside its savepoint, and the transaction survives" do
    # THE FLAKE, made deterministic. On push:main run 33967719694 (sha
    # 1600379b9, 2026-09-05T13:02Z) the test above went red with 57014 raised
    # at `Barkpark.Repo.set_local_statement_timeout!/1` (repo.ex:160) — the
    # `SET LOCAL` that LIFTS the wall was cancelled BY the wall, before the
    # ~3,000-row INSERT it protects ever ran. Racing a real 1 ms wall against a
    # real `SET` is the coin-flip that made it a flake, so this injects the
    # same failure at the same seam: attempt 1 is a statement the 1 ms wall is
    # GUARANTEED to cancel, issued with the SAME `mode: :savepoint` the lift
    # itself uses; attempt 2 is the real lift.
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    Repo.query!("SET statement_timeout = '1ms'")

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
    Repo.query!("SET statement_timeout = '1ms'")

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

  test "the 1 ms wall really does cancel a statement of that size on this connection" do
    # Non-vacuity guard for the test above: the same wall, the same shape, run
    # WITHOUT register/3's opt-out, must be cancelled by the server — otherwise
    # the first test would pass with the opt-out deleted.
    Repo.query!("SET statement_timeout = '1ms'")

    assert {:error, %Postgrex.Error{postgres: %{code: :query_canceled}}} =
             Repo.query(@cancellable)
  end
end
