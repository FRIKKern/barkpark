# The migration is not part of the compiled app (migrations live outside the lib
# path), so it is loaded HERE — before this file compiles — because the test
# calls the migration's own guard builders.
unless Code.ensure_loaded?(BarkparkCloud.Repo.Migrations.IndexNotificationDeliveryLowerRecipient) do
  Code.require_file(
    Path.expand(
      "../../../priv/repo/migrations/20260925120000_index_notification_delivery_lower_recipient.exs",
      __DIR__
    )
  )
end

defmodule BarkparkCloud.Notifications.DeliveryRecipientIndexTest do
  @moduledoc """
  cch-w34-bl-lower-recipient-index — the self-scoped delivery log's index, and
  the guard that refuses to ship it invalid.

  ## What this file does NOT prove

  The PLAN. A test database holds a handful of rows, so the planner's choice here
  says nothing about a 200k-row team. The plans, before and after, at both
  cardinality shapes and with the index set named, were measured with
  EXPLAIN (ANALYZE, BUFFERS) and are quoted in the route comment above
  `GET /v1/notifications/deliveries` and in the PR.

  ## What it does prove

  §1 — the index exists in the DATABASE, is valid, and carries the expression
  key the fence compares on (`lower(recipient)`, not `recipient`: an index on
  the raw column cannot serve `lower(recipient) = $1`).

  §2 — the guard, against a CONSTRUCTED invalid index, since production has
  none to observe. The fail-green is reproduced first as a CONTROL (so a guard
  test that passes cannot be passing because the construction failed), then
  each guard arm is shown firing. Every construction happens on a probe table
  created inside the sandbox transaction, so no shared table is locked and the
  catalog edit rolls back with the test.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.Repo.Migrations.IndexNotificationDeliveryLowerRecipient, as: M

  defp index_state(name) do
    case Repo.query!(
           """
           SELECT i.indisvalid, i.indisready, pg_get_indexdef(i.indexrelid)
             FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
            WHERE c.relname = $1
           """,
           [name]
         ) do
      %{rows: [[valid, ready, def]]} -> %{valid: valid, ready: ready, def: def}
      %{rows: []} -> :missing
    end
  end

  # A raising statement aborts the sandbox transaction; running it inside a
  # nested transaction (a SAVEPOINT) lets the test keep going after it.
  defp run_expecting_raise(sql) do
    assert_raise Postgrex.Error, fn -> Repo.transaction(fn -> Repo.query!(sql) end) end
  end

  describe "§1 the index is real, valid, and keyed on the EXPRESSION" do
    test "(team_id, lower(recipient), inserted_at) exists and is valid" do
      assert %{valid: true, ready: true, def: def} = index_state(M.index_name())
      assert def =~ "ON public.notification_deliveries"
      assert def =~ M.key()
    end

    test "the name fits Postgres' 63-byte identifier limit" do
      # Over 63 bytes Postgres truncates with only a NOTICE, and every later
      # lookup by the declared name misses the object it created.
      assert byte_size(M.index_name()) <= 63
    end
  end

  describe "§2 the indisvalid guard, against a CONSTRUCTED invalid index" do
    setup do
      n = System.unique_integer([:positive])
      table = "cch_w34_guard_probe_#{n}"
      index = "cch_w34_guard_probe_#{n}_idx"

      Repo.query!(
        "CREATE TABLE #{table} (team_id uuid, recipient varchar(255), inserted_at timestamp)"
      )

      create =
        "CREATE INDEX IF NOT EXISTS #{index} ON #{table} (team_id, lower(recipient), inserted_at)"

      Repo.query!(create)
      %{table: table, index: index, create: create}
    end

    defp invalidate!(index) do
      # The state an interrupted `CREATE INDEX CONCURRENTLY` leaves behind.
      Repo.query!(
        "UPDATE pg_index SET indisvalid = false WHERE indexrelid = $1::text::regclass",
        [
          index
        ]
      )

      assert %{valid: false} = index_state(index)
    end

    test "CONTROL: IF NOT EXISTS silently adopts the invalid index (the fail-green)", ctx do
      invalidate!(ctx.index)

      assert {:ok, _} = Repo.query(ctx.create)
      assert %{valid: false} = index_state(ctx.index)
    end

    test "the tripwire RAISES over an invalid index", ctx do
      invalidate!(ctx.index)

      error = run_expecting_raise(M.assert_valid_sql(ctx.index, M.key()))
      assert Exception.message(error) =~ "is INVALID"
    end

    test "drop-and-rebuild turns the invalid index into a valid one", ctx do
      invalidate!(ctx.index)

      Repo.query!(M.drop_invalid_sql(ctx.index))
      assert index_state(ctx.index) == :missing

      Repo.query!(ctx.create)
      Repo.query!(M.assert_valid_sql(ctx.index, M.key()))
      assert %{valid: true, ready: true} = index_state(ctx.index)
    end

    test "drop_invalid_sql leaves a VALID index alone", ctx do
      Repo.query!(M.drop_invalid_sql(ctx.index))
      assert %{valid: true} = index_state(ctx.index)
    end

    test "the tripwire RAISES over a valid same-named index with the WRONG key", ctx do
      Repo.query!("DROP INDEX #{ctx.index}")
      Repo.query!("CREATE INDEX #{ctx.index} ON #{ctx.table} (team_id, recipient)")

      error = run_expecting_raise(M.assert_valid_sql(ctx.index, M.key()))
      assert Exception.message(error) =~ "wrong definition"
    end

    test "the tripwire RAISES when the index is missing", ctx do
      Repo.query!("DROP INDEX #{ctx.index}")

      error = run_expecting_raise(M.assert_valid_sql(ctx.index, M.key()))
      assert Exception.message(error) =~ "is missing"
    end
  end
end
