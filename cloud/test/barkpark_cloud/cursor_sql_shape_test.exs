defmodule BarkparkCloud.CursorSqlShapeTest do
  @moduledoc """
  THE SHAPE OF THE SQL THE THREE KEYSET CURSORS EMIT — cch-w34-s4, review addition.

  Every behavioural assertion about these cursors is structurally blind to the
  defect the slice was actually about. Both wrong spellings return the SAME ROWS
  as the right one in the test environment:

    * `type(^ts, :utc_datetime_usec)` renders `$2::timestamp` — a NAIVE timestamp
      compared against a `timestamptz` column, which Postgres coerces through the
      SESSION TimeZone. Every `barkpark_cloud_test*` database is pinned
      `TimeZone=Etc/UTC` while the server default is `Europe/Oslo`, so the
      two-hour page-boundary slip is invisible to a green local run and to CI;
    * the OR-decomposition (`inserted_at < ^ts or (inserted_at == ^ts and id <
      ^id)`) selects exactly the same rows as the ROW comparator and differs only
      in whether the planner can SEEK — a property no assertion about ROWS can
      see.

  So this file asserts the SQL Ecto RENDERS, captured off the Repo's own
  telemetry from the three REAL public entry points. Without it, a refactor that
  reintroduces either spelling ships with the whole suite green — which is the
  exact class of quiet lie wave 34 exists to remove.
  """
  use BarkparkCloud.DataCase, async: false

  alias BarkparkCloud.{Accounts, DeployLedger, Notifications}

  @handler_id :cursor_sql_shape_probe

  # Capture the SQL of every query this Repo runs inside `fun`. Attached and
  # detached per call so a failure never leaks a handler into another test.
  defp capture_sql(fun) do
    test = self()

    :telemetry.attach(
      {@handler_id, make_ref()},
      [:barkpark_cloud, :repo, :query],
      fn _event, _measure, meta, _cfg -> send(test, {:sql, meta.query}) end,
      nil
    )

    try do
      fun.()
    after
      for {id, _, _, _} <- :telemetry.list_handlers([:barkpark_cloud, :repo, :query]),
          match?({@handler_id, _}, id),
          do: :telemetry.detach(id)
    end

    drain_sql([])
  end

  defp drain_sql(acc) do
    receive do
      {:sql, sql} -> drain_sql([sql | acc])
    after
      0 -> acc
    end
  end

  defp cursor_sql(statements, table) do
    Enum.find(statements, fn sql ->
      String.contains?(sql, ~s(FROM "#{table}")) and String.contains?(sql, "inserted_at\",")
    end)
  end

  defp assert_row_comparator(sql, alias_) do
    assert sql,
           "no cursor query reached the Repo — the probe did not observe what it claims to assert"

    assert String.contains?(sql, ~s{((#{alias_}."inserted_at",#{alias_}."id") < ($2,$3::uuid))}),
           """
           The cursor is not a ROW comparator on ($2,$3::uuid).

           Rendered: #{sql}
           """

    refute String.contains?(sql, "::timestamp"),
           """
           The stamp parameter is CAST. `$2::timestamp` is a naive timestamp against
           a timestamptz column: Postgres coerces it through the SESSION TimeZone and
           the page boundary slips by the server's UTC offset. Every test database is
           pinned Etc/UTC, so no behavioural test can ever see this. Leave `$2`
           uncast — Postgres infers timestamptz from the ROW's left operand.

           Rendered: #{sql}
           """

    refute String.contains?(sql, ~s{"inserted_at" = $}),
           """
           An equality tiebreak is back — this is the OR-decomposition, which selects
           the same rows but cannot SEEK (the stamp bound drops out of Index Cond
           into Filter). Same rows, so no row assertion can see it.

           Rendered: #{sql}
           """
  end

  @ts ~U[2026-08-06 10:00:00.000000Z]

  test "the delivery-log cursor renders a ROW comparator with an uncast stamp" do
    team_id = Ecto.UUID.generate()
    before_id = Ecto.UUID.generate()

    sql =
      capture_sql(fn ->
        Notifications.list_deliveries(team_id, before: @ts, before_id: before_id, limit: 5)
      end)
      |> cursor_sql("notification_deliveries")

    assert_row_comparator(sql, "n0")
  end

  test "the audit-trail cursor renders a ROW comparator with an uncast stamp" do
    team_id = Ecto.UUID.generate()
    before_id = Ecto.UUID.generate()

    sql =
      capture_sql(fn ->
        Accounts.list_audit_events(team_id, before: @ts, before_id: before_id, limit: 5)
      end)
      |> cursor_sql("audit_events")

    assert_row_comparator(sql, "a0")
  end

  test "the deploy-ledger cursor renders a ROW comparator with an uncast stamp" do
    site_id = Ecto.UUID.generate()

    cursor =
      Base.url_encode64("#{DateTime.to_iso8601(@ts)}|#{Ecto.UUID.generate()}", padding: false)

    sql =
      capture_sql(fn ->
        {:ok, _} = DeployLedger.list_page(site_id, before: cursor, limit: 5)
      end)
      |> cursor_sql("deployments")

    assert_row_comparator(sql, "d0")
  end

  test "a malformed cursor still degrades instead of rendering a comparator" do
    # The degradation arms are byte-identical to before the rewrite: an unparseable
    # id falls back to the stamp-only bound, and the ledger's own codec refuses.
    team_id = Ecto.UUID.generate()

    sql =
      capture_sql(fn ->
        Notifications.list_deliveries(team_id, before: @ts, before_id: "not-a-uuid", limit: 5)
      end)
      |> cursor_sql("notification_deliveries")

    assert sql
    assert String.contains?(sql, ~s{(n0."inserted_at" < $2)})
    refute String.contains?(sql, "$3::uuid")

    assert {:error, :invalid_cursor} =
             DeployLedger.list_page(Ecto.UUID.generate(), before: "%%%bogus%%%")
  end
end
