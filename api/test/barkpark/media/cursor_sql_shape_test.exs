defmodule Barkpark.Media.CursorSqlShapeTest do
  @moduledoc """
  THE SHAPE OF THE SQL THE MEDIA SEARCH KEYSET CURSOR EMITS —
  cch-w34-bl-media-search-cursor-or-decomposition.

  This is the api/ sibling of `cloud/test/barkpark_cloud/cursor_sql_shape_test.exs`
  (cch-w34-s4 / charter D389), and it exists for the same reason: every
  behavioural assertion about this cursor is structurally blind to the defect.

    * the OR-decomposition
      (`inserted_at < ^at or (inserted_at == ^at and id < ^id)`) selects
      EXACTLY the same rows as the ROW comparator `(inserted_at, id) < (^at, ^id)`.
      They differ only in whether the planner can SEEK. Measured on a 200k-row
      clone of `media_files` carrying its exact seven indexes plus
      `(dataset_id, inserted_at DESC, id DESC)`: the OR form keeps the stamp
      bound in `Filter` (100001 rows removed, 718 buffers, 6.832 ms), the
      comparator lifts the whole cursor into `Index Cond` (4 buffers, 0.067 ms).
      No assertion about ROWS can see that difference;
    * a CAST stamp param (`type(^at, :utc_datetime_usec)` → `$N::timestamp`) is
      what drops the bound back out of `Index Cond` into `Filter`. Also invisible
      to any row assertion.

  So this file asserts the SQL Ecto RENDERS, captured off the Repo's own
  telemetry from the REAL public entry point (`Search.search/2`). Without it a
  refactor that reintroduces either spelling ships with the whole suite green.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Media.Delivery.Search
  alias Barkpark.Media.Storage.MediaFile

  @event [:barkpark, :repo, :query]
  @handler_id :media_cursor_sql_shape_probe

  # Capture the SQL of every query the Repo runs inside `fun`. Attached and
  # detached per call so a failure never leaks a handler into another test.
  defp capture_sql(fun) do
    test = self()

    :telemetry.attach(
      {@handler_id, make_ref()},
      @event,
      fn _event, _measure, meta, _cfg -> send(test, {:sql, meta.query}) end,
      nil
    )

    try do
      fun.()
    after
      for {id, _, _, _} <- :telemetry.list_handlers(@event),
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

  # `search/2` runs a page query, a count, and one query per facet field. Only
  # the PAGE query carries both the id/inserted_at projection and a LIMIT.
  defp page_sql(statements) do
    Enum.find(statements, fn sql ->
      String.contains?(sql, ~s(FROM "media_files")) and
        String.contains?(sql, ~s(m0."inserted_at")) and
        String.contains?(sql, "LIMIT")
    end)
  end

  @at ~U[2026-08-06 10:00:00.000000Z]

  defp run_search(opts) do
    cursor =
      Search.encode_cursor(%MediaFile{id: Ecto.UUID.generate(), inserted_at: @at})

    capture_sql(fn ->
      Search.search("production", Keyword.merge([cursor: cursor, limit: 5], opts))
    end)
    |> page_sql()
  end

  test "the media search cursor renders a ROW comparator with an uncast stamp" do
    sql = run_search([])

    assert sql,
           "no page query reached the Repo — the probe did not observe what it claims to assert"

    assert sql =~ ~r/\(m0\."inserted_at",m0\."id"\) < \(\$\d+,\$\d+::uuid\)/,
           """
           The cursor is not a ROW comparator on (stamp, id::uuid).

           Rendered: #{sql}
           """

    refute String.contains?(sql, "::timestamp"),
           """
           The stamp parameter is CAST. A cast on either side of the ROW is what
           drops the bound out of `Index Cond` back into `Filter` — the planner
           can no longer seek, and every behavioural test still passes because
           the SAME ROWS come back. Leave the stamp param uncast.

           Rendered: #{sql}
           """

    refute sql =~ ~r/m0\."inserted_at" = \$\d+/,
           """
           An equality tiebreak is back — this is the OR-decomposition. It selects
           the same rows as the comparator but cannot SEEK: measured, the stamp
           bound sits in `Filter` and Postgres walks 100001 index entries to
           return 70 (718 buffers, 6.832 ms) where the comparator reads 4 buffers
           in 0.067 ms. Same rows, so no row assertion can see it.

           Rendered: #{sql}
           """

    refute sql =~ ~r/m0\."inserted_at" < \$\d+/,
           """
           A bare `inserted_at < $n` half-bound is back — the other limb of the
           OR-decomposition.

           Rendered: #{sql}
           """

    assert sql =~ ~r/ORDER BY m0\."inserted_at" DESC, m0\."id" DESC/,
           """
           The default arm lost its `m.id` tiebreak. The comparator tiebreaks on
           `id`; an ORDER BY that does not is not the order the cursor is paging,
           and rows sharing an `inserted_at` are then skipped and repeated
           (measured: 2 of 12 each way on a corpus with 3-way ties).

           Rendered: #{sql}
           """
  end

  test "the comparator survives a non-default sort — in that sort's OWN direction" do
    # `apply_sort/2` has four arms. The cursor predicate USED to be applied
    # unconditionally on all four, which was the separate correctness finding
    # this test's earlier revision pointed at (task-a00f46ef36eca19e, now
    # fixed): a strictly-less-than bound run against an ASCENDING sort, and a
    # bound on `inserted_at` while ordering by `d.updated_at`.
    #
    # The shape guard still has to hold on the non-default arms — otherwise a
    # future fix that special-cases the sort can silently reintroduce the OR
    # form on a path this test does not cover. So it is now asserted PER ARM,
    # against what that arm is supposed to render. Every refutation the earlier
    # revision made (no `::timestamp` cast, no `inserted_at = $n` equality
    # tiebreak, no bare `inserted_at < $n` half-bound) is retained on both arms;
    # what changed is that the expected COMPARATOR is now the arm's own.

    # created-asc — a ROW comparator, but GREATER-THAN. `<` here is the defect.
    asc = run_search(sort: "created-asc")
    assert asc, "no page query reached the Repo for sort=created-asc"

    assert asc =~ ~r/\(m0\."inserted_at",m0\."id"\) > \(\$\d+,\$\d+::uuid\)/,
           """
           sort=created-asc did not render a GREATER-THAN ROW comparator.

           Rendered: #{asc}
           """

    refute asc =~ ~r/\(m0\."inserted_at",m0\."id"\) < \(/,
           """
           sort=created-asc is bounded by a strictly-LESS-THAN comparator while
           ordering ASCENDING. That predicate selects the rows BEFORE the page
           just served, so page 2 restarts at the top of the corpus: measured,
           4 of 12 rows returned, 9 skipped, 1 repeated.

           Rendered: #{asc}
           """

    assert asc =~ ~r/ORDER BY m0\."inserted_at", m0\."id"/,
           """
           sort=created-asc lost its `m.id` tiebreak. The cursor comparator
           tiebreaks on `id`; without it in the ORDER BY, rows sharing an
           `inserted_at` come back in planner-chosen order and the cursor is
           paging an order the query is not serving.

           Rendered: #{asc}
           """

    # updated-desc — the `(inserted_at, id)` token is NOT this arm's ordering
    # key, so NO cursor predicate may be rendered at all.
    upd = run_search(sort: "updated-desc")
    assert upd, "no page query reached the Repo for sort=updated-desc"

    refute upd =~ ~r/\(m0\."inserted_at",m0\."id"\)/,
           """
           sort=updated-desc rendered an `(inserted_at, id)` keyset bound while
           ordering by `d.updated_at`. A bound on an axis the rows are not
           ordered by is not a page boundary: measured, 6 of 12 rows skipped and
           3 repeated. This arm pages by OFFSET and mints no cursor.

           Rendered: #{upd}
           """

    assert upd =~ ~r/ORDER BY d1\."updated_at" DESC, m0\."inserted_at" DESC, m0\."id" DESC/,
           """
           sort=updated-desc lost its total ORDER BY. Offset paging is only
           consistent over a TOTAL order — the `m.id` tiebreak is what makes the
           prefix reproducible across requests.

           Rendered: #{upd}
           """

    for {sort, sql} <- [{"created-asc", asc}, {"updated-desc", upd}] do
      refute String.contains?(sql, "::timestamp"), "sort=#{sort} cast the stamp.\n\n#{sql}"

      refute sql =~ ~r/m0\."inserted_at" = \$\d+/,
             "sort=#{sort} reintroduced the OR-decomposition equality tiebreak.\n\n#{sql}"

      refute sql =~ ~r/m0\."inserted_at" [<>] \$\d+/,
             "sort=#{sort} reintroduced a bare half-bound limb.\n\n#{sql}"
    end
  end

  test "a malformed cursor renders NO comparator at all" do
    sql =
      capture_sql(fn ->
        Search.search("production", cursor: "%%%not-base64%%%", limit: 5)
      end)
      |> page_sql()

    assert sql, "no page query reached the Repo"
    refute String.contains?(sql, "::uuid)")
    refute sql =~ ~r/m0\."inserted_at" < \$\d+/
  end
end
