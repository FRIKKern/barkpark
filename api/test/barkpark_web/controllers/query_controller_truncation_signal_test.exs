defmodule BarkparkWeb.QueryControllerTruncationSignalTest do
  @moduledoc """
  `GET /v1/data/query/:dataset/:type` must let a caller tell an EXHAUSTED page
  from a TRUNCATED one.

  THE DEFECT. The response carried `count` (page rows), `limit`, `offset` and
  `perspective`. `total` appeared only if the caller opted in with
  `?count=true`, and there was no `hasMore`, no `nextOffset`, no cursor and no
  Link header. So a page that had run out and a page hiding 2,647 more rows
  came back BYTE-IDENTICAL. The only inference available was `count == limit`,
  which is exactly the ambiguous case — a type holding exactly `limit` rows
  looks the same as one holding a million. With a default page of 100, every
  type past 100 documents silently truncated for every consumer that did not
  know the `?count=true` trick.

  THE FIX under test: `hasMore` on every list response (exact, from a
  `limit + 1` probe — not a COUNT), plus `nextOffset` when there is a next page.

  MUTATION PROOF is `"an exhausted page and a truncated page are now
  DISTINGUISHABLE"`: it asserts the two metadata maps differ. Drop `hasMore`
  from the envelope and the two become equal again, which is the defect
  restored, and that test fails.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @ds "query_truncation_signal_test"
  @type_name "post"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => @type_name, "title" => "Post", "visibility" => "public", "fields" => []},
        @ds
      )

    :ok
  end

  # Seed `n` published rows. The FIRST goes through the real create+publish path
  # so it carries whatever tenancy scope this install resolves (workspace /
  # project / dataset_id); `Content.Scope.scope_to_workspace/3` is STRICT, so
  # rows seeded outside that scope are invisible to the request and would make
  # every assertion here vacuous. The rest are bulk-inserted as copies of that
  # scope — the 1000-row-page proof needs 1001 of them, and the read path under
  # test reads rows, not revisions.
  defp seed!(n) do
    {:ok, _} =
      Content.create_document(
        @type_name,
        %{"_id" => "ts-00001", "title" => "trunc signal 1"},
        @ds
      )

    {:ok, _} = Content.publish_document("ts-00001", @type_name, @ds)

    seed = Repo.get_by!(Document, doc_id: "ts-00001", type: @type_name)
    now = DateTime.utc_now()

    rows =
      for i <- 2..n//1 do
        %{
          id: Ecto.UUID.generate(),
          doc_id: "ts-#{String.pad_leading(Integer.to_string(i), 5, "0")}",
          type: @type_name,
          dataset: seed.dataset,
          dataset_id: seed.dataset_id,
          workspace_id: seed.workspace_id,
          project_id: seed.project_id,
          title: "trunc signal #{i}",
          status: "published",
          content: %{},
          rev: Ecto.UUID.generate(),
          inserted_at: now,
          updated_at: now
        }
      end

    if rows != [] do
      {inserted, _} = Repo.insert_all(Document, rows)
      ^inserted = n - 1
    end

    :ok
  end

  defp query(conn, params) do
    conn |> get("/v1/data/query/#{@ds}/#{@type_name}", params) |> json_response(200)
  end

  defp meta(result), do: Map.drop(result, ["documents"])

  test "an exhausted page and a truncated page are now DISTINGUISHABLE", %{conn: conn} do
    seed!(3)
    exhausted = meta(query(conn, %{"limit" => "3"})["result"])

    # Same request shape, a corpus that has more behind it. Before the fix these
    # two maps were equal — that equality WAS the bug.
    Repo.delete_all(Document)
    Content.delete_document("ts-00001", @type_name, @ds)
    seed!(10)
    truncated = meta(query(conn, %{"limit" => "3"})["result"])

    assert exhausted["count"] == truncated["count"],
           "the ambiguity is real: both pages carry the same row count"

    assert exhausted["limit"] == truncated["limit"]
    assert exhausted["offset"] == truncated["offset"]

    refute exhausted == truncated,
           "an exhausted page and a truncated page must NOT be byte-identical"

    assert exhausted["hasMore"] == false
    assert truncated["hasMore"] == true
  end

  test "hasMore is present on every list response, without ?count=true", %{conn: conn} do
    seed!(2)
    result = query(conn, %{})["result"]

    assert Map.has_key?(result, "hasMore")
    assert result["hasMore"] == false
    refute Map.has_key?(result, "total"), "total still costs an explicit ?count=true"
  end

  test "hasMore true carries the nextOffset that reads the next page", %{conn: conn} do
    seed!(5)
    result = query(conn, %{"limit" => "3"})["result"]

    assert result["hasMore"] == true
    assert result["nextOffset"] == 3

    next = query(conn, %{"limit" => "3", "offset" => "3"})["result"]

    assert next["count"] == 2
    assert next["hasMore"] == false
    refute Map.has_key?(next, "nextOffset"), "a page with no successor offers no next offset"
  end

  test "the walk over hasMore/nextOffset sees every row exactly once", %{conn: conn} do
    seed!(7)

    {ids, pages} = walk(conn, 0, 2, [], 0)

    assert length(ids) == 7
    assert length(Enum.uniq(ids)) == 7, "paging must neither skip nor duplicate a row"
    assert pages == 4
  end

  defp walk(conn, offset, limit, acc, pages) do
    result = query(conn, %{"limit" => to_string(limit), "offset" => to_string(offset)})["result"]
    acc = acc ++ Enum.map(result["documents"], & &1["_id"])

    if result["hasMore"] do
      walk(conn, result["nextOffset"], limit, acc, pages + 1)
    else
      {acc, pages + 1}
    end
  end

  test "hasMore stays truthful at the maximum page size", %{conn: conn} do
    # THE CLAMP TRAP. `list_documents/3` clamps :limit to 1000, so a probe
    # implemented as `limit + 1` through the PUBLIC path would be clamped back
    # to 1000 and report hasMore=false at exactly the page size where truncation
    # is most likely. `list_documents_page/3` runs the probe past that clamp.
    seed!(1001)
    result = query(conn, %{"limit" => "1000"})["result"]

    assert result["count"] == 1000
    assert result["hasMore"] == true, "a full 1000-row page with a 1001st row behind it HAS more"
    assert result["nextOffset"] == 1000
  end

  test "an exactly-full maximum page reports no more", %{conn: conn} do
    seed!(1000)
    result = query(conn, %{"limit" => "1000"})["result"]

    assert result["count"] == 1000
    assert result["hasMore"] == false
  end
end
