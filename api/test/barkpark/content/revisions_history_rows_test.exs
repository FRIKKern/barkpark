defmodule Barkpark.Content.RevisionsHistoryRowsTest do
  @moduledoc """
  task-50a2e2a101ca5ec2: `GET /v1/data/history/…?limit=10` answered p50 76 ms /
  p95 136 ms on guerrilla and 6 ms locally. `list_revisions/4` does push the
  limit into SQL, but no index matched `doc_id = … ORDER BY inserted_at DESC,
  id DESC`: Postgres walked the table-wide `inserted_at` index backwards and
  filtered out every newer revision of every other document until it had a
  page. The cost was the table's recent writes, not this document's history.
  This pins the rows one page reads.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Revision
  alias Barkpark.Repo

  defp row(doc_id, seconds_ago, i) do
    %{
      id: Ecto.UUID.generate(),
      doc_id: doc_id,
      type: "post",
      dataset: "production",
      title: "#{doc_id} #{i}",
      status: "draft",
      content: %{"n" => i},
      action: "update",
      inserted_at: DateTime.utc_now() |> DateTime.add(-seconds_ago, :second)
    }
  end

  # Every scan node's rows read: the rows it returned plus the rows it filtered out.
  defp rows_read(%{"Plans" => plans} = node),
    do: own_rows(node) + Enum.sum(Enum.map(plans, &rows_read/1))

  defp rows_read(node), do: own_rows(node)

  defp own_rows(%{"Node Type" => type} = node) do
    if type =~ "Scan",
      do: Map.get(node, "Actual Rows", 0) + Map.get(node, "Rows Removed by Filter", 0),
      else: 0
  end

  test "a page of a document's history reads that page, not every newer revision in the table" do
    # The document was last edited before 1,500 revisions of other documents.
    deep = for i <- 1..200, do: row("deep", 100_000 + i, i)
    others = for d <- 1..30, i <- 1..50, do: row("other-#{d}", i, i)
    for chunk <- Enum.chunk_every(deep ++ others, 500), do: Repo.insert_all(Revision, chunk)
    Repo.query!("ANALYZE revisions")

    me = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:barkpark, :repo, :query],
      fn _, _, meta, _ ->
        if self() == me and meta[:source] == "revisions",
          do: send(me, {:sql, meta.query, meta.params})
      end,
      nil
    )

    page =
      try do
        Content.list_revisions("deep", "post", "production", limit: 11)
      after
        :telemetry.detach(handler)
      end

    assert Enum.map(page, & &1.title) == Enum.map(1..11, &"deep #{&1}")

    assert_received {:sql, sql, params}

    params =
      Enum.map(params, fn
        %Ecto.Query.Tagged{value: v} -> v
        v -> v
      end)

    %{rows: [[[plan]]]} = Repo.query!("EXPLAIN (ANALYZE, FORMAT JSON) " <> sql, params)
    read = rows_read(plan["Plan"])
    assert read <= 24, "one page of 11 read #{read} revision rows"
  end
end
