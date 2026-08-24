defmodule BarkparkWeb.LegacyListTruncationTest do
  @moduledoc """
  `GET /api/documents/:type` must not report a capped page as the corpus.

  THE DEFECT. `LegacyController.index/2` passed `limit: 10_000` to
  `Content.list_documents/3` — which CLAMPS `:limit` to 1000 — and then
  answered `count: length(documents)`. A client holding 4,000 documents of a
  type was told by the API, in its own `count` field, that it had exactly
  1000. Nothing errored and no field disclosed the cut.

  THE FIX under test: the action WALKS the corpus
  (`Content.collect_all_documents/3`) up to the 10_000-document ceiling it
  always meant to serve, and carries an explicit `truncated` flag so a caller
  that DOES hit the ceiling learns about it.

  MUTATION PROOF: this seeds 1001 published documents — one past the clamp.
  Restore the old `list_documents(limit: 10_000)` call and `count` comes back
  1000, so `assert body["count"] == 1001` fails. Verified by mutation.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @token "barkpark-legacy-trunc-token"
  @type_name "trunc_post"

  setup do
    Auth.create_token(@token, "dev", "legacy-truncation", ["read", "write", "admin"])

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => @type_name, "title" => "TruncPost", "visibility" => "public", "fields" => []},
        "production"
      )

    :ok
  end

  # Seed `n` published rows. The FIRST goes through the real create+publish path
  # so it carries whatever tenancy scope this install resolves (workspace /
  # project / dataset_id) — `Content.Scope.scope_to_workspace/3` is STRICT on
  # workspace_id, so rows seeded outside that scope are invisible to the request
  # and would make this test vacuous. The remaining n-1 are bulk-inserted as
  # copies of that scope: 1001 create+publish round-trips would make the proof
  # too slow to keep, and the read path under test reads rows, not revisions.
  defp seed_published!(n) do
    {:ok, _} =
      Content.create_document(
        @type_name,
        %{"_id" => "lt-00001", "title" => "legacy trunc 1"},
        "production"
      )

    {:ok, _} = Content.publish_document("lt-00001", @type_name, "production")

    seed = Repo.get_by!(Document, doc_id: "lt-00001", type: @type_name)
    now = DateTime.utc_now()

    rows =
      for i <- 2..n//1 do
        %{
          id: Ecto.UUID.generate(),
          doc_id: "lt-#{String.pad_leading(Integer.to_string(i), 5, "0")}",
          type: @type_name,
          dataset: seed.dataset,
          dataset_id: seed.dataset_id,
          workspace_id: seed.workspace_id,
          project_id: seed.project_id,
          title: "legacy trunc #{i}",
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

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  test "a corpus past the 1000-row clamp is served whole, and count is the real total", %{
    conn: conn
  } do
    seed_published!(1001)

    body =
      conn
      |> authed()
      |> get(~p"/api/documents/#{@type_name}")
      |> json_response(200)

    assert body["count"] == 1001,
           "count must be the real corpus size, not the 1000-row page cap the query clamps to"

    assert length(body["documents"]) == 1001

    assert length(Enum.uniq(Enum.map(body["documents"], & &1["id"]))) == 1001,
           "the walk must return 1001 DISTINCT documents, never a page re-read"
  end

  test "the response carries an explicit truncated flag, false when the corpus was exhausted", %{
    conn: conn
  } do
    seed_published!(3)

    body =
      conn
      |> authed()
      |> get(~p"/api/documents/#{@type_name}")
      |> json_response(200)

    assert Map.has_key?(body, "truncated"),
           "an exhausted list and a cut-short one must not be byte-identical"

    assert body["truncated"] == false
    assert body["count"] == 3
  end

  test "an empty type still answers count 0 and truncated false", %{conn: conn} do
    body =
      conn
      |> authed()
      |> get(~p"/api/documents/#{@type_name}")
      |> json_response(200)

    assert body["count"] == 0
    assert body["truncated"] == false
  end
end
