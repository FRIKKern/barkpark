defmodule Barkpark.Search.ViewsTest do
  @moduledoc """
  `Barkpark.Search.Views`: recording, dedupe, the flush to
  `document_view_days`, the rollup into `document_popularity`, and what the
  tables hold. Fixtures are synthetic.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.WriteScope
  alias Barkpark.Search.Views
  alias Barkpark.Search.Views.Buffer

  @dataset "views_ds"

  setup do
    Buffer.reset()
    ws = create_workspace!()
    project = create_project!(ws)
    scope = [workspace_id: ws.id, project_id: project.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "book", "title" => "Book", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    for id <- ~w(b1 b2 b3) do
      {:ok, _} = Content.create_document("book", %{"_id" => id, "name" => id}, @dataset, scope)
      {:ok, _} = Content.publish_document(id, "book", @dataset, scope)
    end

    # A draft that was never published: views of it are dropped.
    {:ok, _} = Content.create_document("book", %{"_id" => "d1", "name" => "d1"}, @dataset, scope)

    dataset_id = WriteScope.resolve_read_dataset_id(@dataset, scope)
    on_exit(&Buffer.reset/0)
    {:ok, dataset_id: dataset_id}
  end

  defp day_rows(dataset_id) do
    Repo.query!(
      "SELECT doc_id, day, type, views FROM document_view_days WHERE dataset_id = $1 ORDER BY doc_id, day",
      [Ecto.UUID.dump!(dataset_id)]
    ).rows
  end

  test "a view is buffered, then flushed into one day row per document", %{dataset_id: ds} do
    today = Date.utc_today()

    assert {:ok, %{accepted: 2, duplicates: 0}} = Views.record(ds, ["b1", "b2"], nil)
    assert {:ok, %{accepted: 1, duplicates: 0}} = Views.record(ds, ["b1"], nil)
    assert day_rows(ds) == []

    assert Views.flush() == 3
    assert day_rows(ds) == [["b1", today, "book", 2], ["b2", today, "book", 1]]

    # A second flush adds to the same rows.
    {:ok, _} = Views.record(ds, ["b1"], nil)
    assert Views.flush() == 1
    assert day_rows(ds) == [["b1", today, "book", 3], ["b2", today, "book", 1]]
  end

  test "one visitor counts once per document per day", %{dataset_id: ds} do
    assert {:ok, %{accepted: 1}} = Views.record(ds, ["b1"], "ip:1.2.3.4|ua")
    assert {:ok, %{accepted: 0, duplicates: 1}} = Views.record(ds, ["b1"], "ip:1.2.3.4|ua")
    assert {:ok, %{accepted: 1}} = Views.record(ds, ["b2"], "ip:1.2.3.4|ua")
    assert {:ok, %{accepted: 1}} = Views.record(ds, ["b1"], "ip:5.6.7.8|ua")

    # The next day the same visitor counts again.
    tomorrow = Date.add(Date.utc_today(), 1)
    assert {:ok, %{accepted: 1}} = Views.record(ds, ["b1"], "ip:1.2.3.4|ua", tomorrow)

    assert Views.flush() == 4
  end

  test "ids that are not published documents of the dataset are dropped at flush", %{
    dataset_id: ds
  } do
    {:ok, %{accepted: 3}} = Views.record(ds, ["b1", "nope", "d1"], nil)
    assert Views.flush() == 1
    assert [["b1", _, "book", 1]] = day_rows(ds)
  end

  test "a draft id counts for its published document", %{dataset_id: ds} do
    {:ok, %{accepted: 1}} = Views.record(ds, ["drafts.b2"], nil)
    Views.flush()
    assert [["b2", _, "book", 1]] = day_rows(ds)
  end

  test "empty, oversized and too many ids are refused", %{dataset_id: ds} do
    assert {:error, :no_ids} = Views.record(ds, [""], nil)
    assert {:error, :no_ids} = Views.record(ds, [String.duplicate("x", 256)], nil)
    assert {:error, :too_many_ids} = Views.record(ds, Enum.map(1..51, &"id#{&1}"), nil)
  end

  test "rollup sums 7 and 30 days, decays the score and drops documents with no recent view",
       %{dataset_id: ds} do
    today = ~D[2026-10-14]
    raw = Ecto.UUID.dump!(ds)

    rows = [
      {"b1", today, 4},
      {"b1", Date.add(today, -7), 8},
      {"b1", Date.add(today, -40), 100},
      {"b2", Date.add(today, -3), 1},
      {"b3", Date.add(today, -35), 50}
    ]

    for {id, day, n} <- rows do
      Repo.query!(
        "INSERT INTO document_view_days (dataset_id, doc_id, day, type, views) VALUES ($1, $2, $3, 'book', $4)",
        [raw, id, day, n]
      )
    end

    # A row left over from an earlier rollup with no views in the window.
    Repo.query!(
      "INSERT INTO document_popularity (dataset_id, doc_id, type, views_7d, views_30d, score, updated_at) VALUES ($1, 'b3', 'book', 9, 9, 9, now() - interval '1 day')",
      [raw]
    )

    assert %{documents: 2, pruned: 0} = Views.rollup(today: today)

    counts = Views.lookup(ds, ~w(b1 b2 b3))
    assert counts["b1"]["_views7d"] == 4
    assert counts["b1"]["_views30d"] == 12
    # 4 today plus 8 a week ago at half weight.
    assert_in_delta counts["b1"]["_popularity"], 8.0, 0.0001
    assert counts["b2"]["_views7d"] == 1
    assert_in_delta counts["b2"]["_popularity"], :math.pow(0.5, 3 / 7), 0.0001
    refute Map.has_key?(counts, "b3")

    # Day rows past the 90-day retention are deleted.
    Repo.query!(
      "INSERT INTO document_view_days (dataset_id, doc_id, day, type, views) VALUES ($1, 'b1', $2, 'book', 1)",
      [raw, Date.add(today, -90)]
    )

    assert %{pruned: 1} = Views.rollup(today: today)
  end

  test "the tables hold no IP address, user agent or visitor key" do
    columns =
      Repo.query!(
        "SELECT table_name, column_name FROM information_schema.columns WHERE table_name IN ('document_view_days', 'document_popularity') ORDER BY 1, 2"
      ).rows

    assert columns == [
             ["document_popularity", "dataset_id"],
             ["document_popularity", "doc_id"],
             ["document_popularity", "score"],
             ["document_popularity", "type"],
             ["document_popularity", "updated_at"],
             ["document_popularity", "views_30d"],
             ["document_popularity", "views_7d"],
             ["document_view_days", "dataset_id"],
             ["document_view_days", "day"],
             ["document_view_days", "doc_id"],
             ["document_view_days", "type"],
             ["document_view_days", "views"]
           ]
  end

  test "visitor keys depend on a per-day salt and earlier days are pruned" do
    today = Date.utc_today()
    yesterday = Date.add(today, -1)

    a = Buffer.visitor_key(today, "ip:1.2.3.4|ua")
    assert a == Buffer.visitor_key(today, "ip:1.2.3.4|ua")
    assert byte_size(a) == 16
    refute a == Buffer.visitor_key(yesterday, "ip:1.2.3.4|ua")

    Buffer.add("ds", "b1", yesterday, Buffer.visitor_key(yesterday, "v"))
    assert :ets.info(:barkpark_view_seen, :size) == 3

    Buffer.prune_seen(today)
    # Only today's salt is left.
    assert [{{:salt, _}, _}] = :ets.tab2list(:barkpark_view_seen)
    Buffer.take_counts()
  end

  test "referenced?/1 finds the view fields in a parsed query" do
    {:ok, tree} = Barkpark.Groq.Parser.parse(~s'*[_type == "book"] | order(_views30d desc)', %{})
    assert Views.referenced?(tree)

    {:ok, tree} = Barkpark.Groq.Parser.parse(~s'*[_type == "book"]{name}', %{})
    refute Views.referenced?(tree)
  end
end
