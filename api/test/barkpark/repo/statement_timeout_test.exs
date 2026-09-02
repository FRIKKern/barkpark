defmodule Barkpark.Repo.StatementTimeoutTest do
  @moduledoc """
  A server-side `statement_timeout` bounds ONE ledger read, so a slow scan
  cannot hold a pool member for minutes (task-e2f5ecca0be9a6d1, criterion 3).

  ## What was measured

  guerrilla, 2026-09-01T21:43-21:46Z, `statement_timeout = 0`: SIX
  `postgres: barkpark barkpark_prod SELECT` backends at 4-7 MINUTES elapsed on
  a 2-vCPU box. Every later request's token lookup queued behind them, so the
  AUTH PLUGS raised first — 618 "connection not available and request was
  dropped from queue" in one hour, from `auth.ex` verify_token (218),
  `optional_token.ex` (186), `assign_default_scope.ex` (130). 532 `Sent 500`
  that hour against 0 in each of the four hours before.

  ## Why these arms are shaped this way

  Ecto's `:timeout` would NOT have produced this file's result: it is a
  CLIENT-side deadline, so DBConnection stops waiting while the Postgres
  backend keeps running. Only `statement_timeout` CANCELS the backend, and the
  proof of that is arm (2)/(3) raising `%Postgrex.Error{postgres: %{code:
  :query_canceled}}` — 57014 is emitted by the SERVER, so receiving it is
  itself evidence that the server did the cancelling.

  `(1)` is the INSTRUMENT SELF-TEST and it passes with or without the change:
  it proves the composed query still returns the fixture rows and that the
  `pg_sleep` fragment is actually reached. Without it, `(2)`'s raise could be
  any upstream failure — a malformed query, an empty scope — and would prove
  nothing about the timeout.

  Every arm is scoped to a `phase_id` this test mints, because the tasks table
  is written by every other suite and, in this repo, by other agents against
  the same database.

  ## Red without / green with

  Arms (2), (3) and (5) fail without a `statement_timeout` in force: the
  cancelled statements instead run their full `pg_sleep`, so `assert_raise`
  finds no exception and the elapsed-time assertion blows past its bound.
  Arm (4) fails without `Barkpark.Repo.with_statement_timeout/2` (the function
  does not exist) and would fail with a naive implementation that emitted a
  bare `SET` — see its own comment. Arm (6) fails without the `repo_opts`
  change in `config/runtime.exs`.
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content.Document
  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Tasks.Query, as: TasksQuery
  alias Barkpark.Tasks.Queue

  @dataset "production"

  # The wall each arm arms itself with. Comfortably longer than any real work
  # the seeded fixture does, and ~200x shorter than @long_sleep_s — so a raise
  # here can only have come from the sleep, never from an incidentally slow box.
  @wall "150ms"

  # Long enough that a test which does NOT fail fast is unmistakable (the arm's
  # elapsed-time assertion trips at 5 s, a sixth of this).
  @long_sleep_s 30.0

  # Short enough to be free, long enough to prove the fragment was evaluated.
  @short_sleep_s 0.05

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    phase = "phase-st-#{System.unique_integer([:positive])}"
    for n <- 1..3, do: mk_task!("st-#{n}-#{System.unique_integer([:positive])}", scope, phase)

    %{scope: scope, ws: ws, phase: phase}
  end

  defp mk_task!(doc_id, scope, phase) do
    content =
      %{"kind" => "task", "lifecycle_status" => "open", "parent_id" => phase}
      |> Map.merge(Barkpark.LabelFixtures.weighted_labels())

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  # The REAL ready-queue query, with a deliberate stall folded into its WHERE.
  #
  # `length(pg_sleep(?)::text) = 0` is TRUE (void::text is ""), so the predicate
  # does not filter any row out — the query still returns exactly what
  # `Queue.ready_query/1` returns, just slowly. `pg_sleep` is VOLATILE, so
  # Postgres neither constant-folds it at plan time nor caches it.
  defp slow_ready_query(ws, phase, seconds) do
    [workspace_id: ws.id, dataset: @dataset, phase_id: phase]
    |> Queue.ready_query()
    |> then(&from([doc: _d] in &1, where: fragment("length(pg_sleep(?)::text) = 0", ^seconds)))
  end

  # The REAL children shape: `Tasks.Query.maybe_filter_parent_id/2` over
  # `Document` — the `regexp_replace(content->>'parent_id', …)` equality that
  # was measured in flight on guerrilla with LWLock waits.
  defp slow_children_query(phase, seconds) do
    from(d in Document, where: d.type == "task")
    |> TasksQuery.maybe_filter_parent_id(phase)
    |> then(&from(d in &1, where: fragment("length(pg_sleep(?)::text) = 0", ^seconds)))
  end

  # Arm the wall on the connection this test already owns. Under
  # `Ecto.Adapters.SQL.Sandbox` the test body is ALREADY inside a real Postgres
  # transaction (Ecto's own `in_transaction?/0` reports false, which is why this
  # issues the SQL directly rather than through
  # `Repo.set_local_statement_timeout!/1`), so `SET LOCAL` binds for the rest of
  # the test and is reverted with the sandbox rollback.
  defp arm_wall!(value \\ @wall) do
    Repo.query!("SET LOCAL statement_timeout = '#{value}'")
  end

  defp ambient_timeout do
    %{rows: [[value]]} = Repo.query!("SELECT current_setting('statement_timeout')")
    value
  end

  # ── (1) INSTRUMENT SELF-TEST — passes before AND after the change ──────────

  describe "instrument" do
    test "the composed queries still return the fixture rows", %{ws: ws, phase: phase} do
      ready = Repo.all(slow_ready_query(ws, phase, @short_sleep_s))

      assert length(ready) == 3,
             "INSTRUMENT BLIND: the ready query with the pg_sleep fragment returned " <>
               "#{length(ready)} rows, not the 3 seeded — the timeout arms below would " <>
               "be raising for some reason other than the stall, or never evaluating it"

      children = Repo.all(slow_children_query(phase, @short_sleep_s))

      assert length(children) == 3,
             "INSTRUMENT BLIND: the children query returned #{length(children)} rows, " <>
               "not the 3 seeded"
    end
  end

  # ── (2) the ready queue fails fast ─────────────────────────────────────────

  describe "the ready queue under a statement_timeout" do
    test "is CANCELLED BY THE SERVER instead of holding the connection",
         %{ws: ws, phase: phase} do
      query = slow_ready_query(ws, phase, @long_sleep_s)

      {micros, error} =
        :timer.tc(fn ->
          assert_raise Postgrex.Error, fn ->
            # assert_raise sits OUTSIDE Repo.transaction/2 on purpose: letting
            # the error escape the (savepoint) transaction is what makes Ecto
            # ROLLBACK TO SAVEPOINT, so the sandbox connection survives the
            # aborted statement and the assertions below can still run.
            Repo.transaction(fn ->
              arm_wall!()
              # `timeout: :infinity` removes Ecto's CLIENT-side deadline from
              # the picture entirely, so the only thing that can end this
              # statement is the server. That is the distinction the whole
              # change rests on.
              Repo.all(query, timeout: :infinity)
            end)
          end
        end)

      assert %Postgrex.Error{postgres: %{code: :query_canceled}} = error,
             "expected the SERVER's 57014 cancellation; got #{inspect(error)}"

      assert micros < 5_000_000,
             "the ready query took #{div(micros, 1000)} ms to fail. The wall is " <>
               "#{@wall} and the stall is #{@long_sleep_s} s — anything near the stall " <>
               "means the statement ran to completion and held a pool member the whole time"
    end
  end

  # ── (3) the children lookup fails fast ─────────────────────────────────────

  describe "the children lookup under a statement_timeout" do
    test "is CANCELLED BY THE SERVER instead of holding the connection", %{phase: phase} do
      query = slow_children_query(phase, @long_sleep_s)

      {micros, error} =
        :timer.tc(fn ->
          assert_raise Postgrex.Error, fn ->
            Repo.transaction(fn ->
              arm_wall!()
              Repo.all(query, timeout: :infinity)
            end)
          end
        end)

      assert %Postgrex.Error{postgres: %{code: :query_canceled}} = error,
             "expected the SERVER's 57014 cancellation; got #{inspect(error)}"

      assert micros < 5_000_000,
             "the children query took #{div(micros, 1000)} ms to fail"
    end
  end

  # ── (4) the opt-out ────────────────────────────────────────────────────────

  describe "Repo.with_statement_timeout/2" do
    test "lifts the ambient wall for a statement that legitimately needs longer" do
      arm_wall!()
      assert ambient_timeout() == @wall

      # Without the opt-out this sleep is ~3x the wall and would be cancelled.
      assert {:ok, %Postgrex.Result{}} =
               Repo.with_statement_timeout(0, fn ->
                 Repo.query!("SELECT pg_sleep(0.45)")
               end)
    end

    test "emits SET LOCAL, never a bare SET — a bare SET would outlive the checkout" do
      # WHY THIS IS ASSERTED ON THE EMITTED SQL rather than on behaviour: under
      # the SQL sandbox every test already runs inside one transaction, so
      # `with_statement_timeout/2`'s own `Repo.transaction/2` is a SAVEPOINT —
      # and Postgres keeps a `SET LOCAL` made in a subtransaction that COMMITS
      # until the end of the ENCLOSING transaction. A "the wall came back after
      # the helper returned" assertion here would therefore measure the sandbox,
      # not production. In production the helper's transaction IS the outermost
      # one, so its COMMIT is where Postgres reverts the setting and the pooled
      # connection goes back into the pool carrying the config-set 30s again.
      # What IS provable here, and is the load-bearing half, is that the helper
      # asks for the transaction-scoped form at all.
      ref = make_ref()
      test_pid = self()
      handler_id = {__MODULE__, ref}

      :telemetry.attach(
        handler_id,
        [:barkpark, :repo, :query],
        fn _event, _measure, meta, _cfg ->
          if meta[:query] =~ ~r/statement_timeout/, do: send(test_pid, {ref, meta[:query]})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, _} = Repo.with_statement_timeout(0, fn -> :ok end)

      assert_receive {^ref, sql}, 1_000
      assert sql =~ ~r/^\s*SET LOCAL statement_timeout/i, "emitted #{inspect(sql)}"
      refute sql =~ ~r/^\s*SET statement_timeout/i
    end

    test "refuses a value Postgres could not parse, rather than interpolating it" do
      # The value reaches SQL by interpolation (`SET` takes no bind parameters),
      # so the shape guard is the only thing between a caller and the statement.
      assert_raise ArgumentError, ~r/invalid statement_timeout/, fn ->
        Repo.with_statement_timeout("30s'; DROP TABLE documents; --", fn -> :ok end)
      end

      assert_raise ArgumentError, ~r/invalid statement_timeout/, fn ->
        Repo.with_statement_timeout("forever", fn -> :ok end)
      end
    end

    test "refuses SET LOCAL outside a transaction, where it would silently no-op" do
      assert_raise ArgumentError, ~r/must run inside a transaction/, fn ->
        Repo.set_local_statement_timeout!(1_000)
      end
    end
  end

  # ── (5) the wall really is per-STATEMENT, not per-transaction ──────────────

  describe "the bound" do
    test "applies to each statement, so a fast one after a slow one is unaffected" do
      # This is what makes 30s a safe number for the request path: a request
      # that issues four 5s queries is NOT cancelled at 30s of cumulative work.
      assert {:ok, :done} =
               Repo.transaction(fn ->
                 arm_wall!("400ms")
                 for _ <- 1..4, do: Repo.query!("SELECT pg_sleep(0.15)")
                 :done
               end)
    end
  end

  # ── (6) the config pin ─────────────────────────────────────────────────────

  describe "config/runtime.exs" do
    # WHY THIS ARM IS TEXTUAL. `config/runtime.exs` is evaluated at BOOT, and
    # only its `config_env() == :prod` branch carries this setting — `mix test`
    # never runs that branch, and there is no way to observe the prod `repo_opts`
    # from inside the test VM without re-evaluating the file (which would demand
    # DATABASE_URL, SECRET_KEY_BASE and every other prod env var and would then
    # reconfigure the running repo out from under the sandbox). So this arm pins
    # the two things a future edit is most likely to drop silently: that the
    # parameter is declared at all, and that the documented env var name still
    # matches the one the file reads. It cannot prove the value takes effect —
    # arms (2) and (3) prove the MECHANISM, this one proves it is WIRED.
    setup do
      %{source: File.read!(Path.expand("../../../config/runtime.exs", __DIR__))}
    end

    test "the prod repo_opts declare a statement_timeout startup parameter", %{source: src} do
      [_, prod] = String.split(src, "if config_env() == :prod do", parts: 2)
      [repo_opts, _] = String.split(prod, "config :barkpark, Barkpark.Repo", parts: 2)

      assert repo_opts =~ "parameters: [statement_timeout: statement_timeout]",
             "the prod repo_opts no longer pass statement_timeout to Postgrex — every " <>
               "pool connection is back to an unbounded statement, which is the " <>
               "guerrilla incident (task-e2f5ecca0be9a6d1)"

      assert repo_opts =~ ~s|"30s"|, "the documented 30s default is gone from runtime.exs"
    end

    test "the override env var is still named BARKPARK_DB_STATEMENT_TIMEOUT", %{source: src} do
      assert src =~ ~s|System.get_env("BARKPARK_DB_STATEMENT_TIMEOUT")|
    end

    test "config/test.exs does NOT set one — the sandbox owns the connection" do
      test_config = File.read!(Path.expand("../../../config/test.exs", __DIR__))
      refute test_config =~ "statement_timeout"
    end
  end
end
