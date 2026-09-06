defmodule BarkparkWeb.Integration.V1MediaOffsetClampTest do
  @moduledoc """
  The pagination-offset ceiling on the v1 media read doors
  (task-01c6c2c9b9726409).

  `Delivery.Search.paginate_ids/2` computes `fetch = limit + offset + 20`,
  issues `LIMIT <fetch>` with NO SQL OFFSET, `Repo.all`s the rows, `uniq_by`s
  them and only THEN `Enum.drop(offset)`. So the offset is not a query hint —
  it is a direct multiplier on how many rows land on the BEAM heap, and
  `?offset=5000000` asks the node to materialize five million tuples to return
  nothing. `SearchParams.parse/1` clamped `limit` and not `offset`.

  Every door here echoes the RESOLVED `offset` back in `result.offset`, read
  straight off the opts list the paginator receives — so the echo IS the
  observation of the clamp, not a second, separately-computed number.

  The sibling set was derived by grepping every `params["offset"]` read under
  `api/lib` and following each to its paginator, NOT from the filing's list:
  the filing named `SearchParams.parse/1` and the collections passthrough, and
  did not name `V1.MediaController.index/2`, which builds its own opts and
  reaches the identical paginator through `Media.query_files/2`.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content

  @ceiling 100_000
  @absurd "5000000"

  test "GET /v1/media/:dataset/search clamps offset for a TOKENLESS caller", %{conn: conn} do
    # No Authorization header at all: `[:api, :api_strict_bearer]` only
    # rejects a PRESENTED-but-unverifiable bearer, so this is the anonymous
    # reach the row names. A 200 here is also the control — if this door ever
    # starts refusing anonymous callers the assertion below stops meaning
    # anything and this line says so first.
    body =
      conn
      |> get("/v1/media/production/search", %{"offset" => @absurd, "limit" => "5"})
      |> json_response(200)

    assert body["result"]["offset"] == @ceiling
  end

  test "GET /v1/media/:dataset (index) clamps offset — the door the filing missed",
       %{conn: conn} do
    body =
      conn
      |> get("/v1/media/production", %{"offset" => @absurd, "limit" => "5"})
      |> json_response(200)

    assert body["result"]["offset"] == @ceiling
  end

  test "GET /v1/media/:dataset/collections/:id/assets clamps the passthrough offset",
       %{conn: conn} do
    # `offset` rides `@search_passthrough_keys` into `MediaSearchParams.parse/1`
    # here, so this proves the ONE clamp covers the collection door too.
    id = "col-offset-#{System.unique_integer([:positive])}"

    # `upsert_document/4` lands a DRAFT (`drafts.<id>`); publish so the plain id
    # resolves on the read path.
    {:ok, _doc} =
      Content.upsert_document(
        "mediaCollection",
        %{
          "doc_id" => id,
          "title" => "Offset clamp fixture",
          "content" => %{"kind" => "folder", "slug" => id}
        },
        "production",
        source: :api
      )

    {:ok, _published} = Content.publish_document(id, "mediaCollection", "production")

    # Tokenless, like the sibling `V1MediaCollectionsTest` assets case: an
    # api_token principal hits `restrict_public_read_tier?/1` and 404s on a
    # `mediaCollection` (not a public type), so the anonymous conn is the one
    # that actually reaches the passthrough.
    body =
      conn
      |> get("/v1/media/production/collections/#{id}/assets", %{
        "offset" => @absurd,
        "limit" => "5"
      })
      |> json_response(200)

    assert body["result"]["collectionId"] == id
    assert body["result"]["offset"] == @ceiling
  end

  test "a legitimate in-range offset still reaches the paginator unchanged", %{conn: conn} do
    # Non-vacuity: a clamp written as a constant, or a door that ignored
    # `offset` entirely, would pass all three tests above.
    body =
      conn
      |> get("/v1/media/production/search", %{"offset" => "37", "limit" => "5"})
      |> json_response(200)

    assert body["result"]["offset"] == 37
  end
end
