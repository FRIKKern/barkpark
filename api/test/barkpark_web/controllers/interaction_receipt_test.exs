defmodule BarkparkWeb.InteractionReceiptTest do
  @moduledoc """
  The interaction receipt, pinned WHERE A CALLER READS IT — over HTTP.

  Both interaction endpoints answer a discriminated union
  (`{:ok, id} | {:skipped, reason}`) with a four-way receipt:

    * `{:ok, id}`                       -> 200 `recorded: true`  + interactionEventId
    * `{:skipped, :recording_disabled}` -> 200 `ok: true, recorded: false`, reason
    * `{:skipped, :error}`              -> 500 `ok: false, recorded: false`, reason
    * `{:skipped, other}`               -> 422 `ok: false, recorded: false`, reason

  Before this file, that repair was pinned ONLY at the module seam: the sole
  HTTP test of either endpoint asserted `ok == true` and a binary event id, no
  test posted to the media endpoint at all, and the 422/500 arms had never
  executed on any host. The consequence was measured, not assumed: making
  `Barkpark.Content.SearchIntelligence.record_interaction/3` discard its real
  result and hand back `{:ok, Ecto.UUID.generate()}` restores the original
  defect WITH A FABRICATED event id — and the whole existing apparatus,
  including the gated receipt census (which pins the controller's expression
  fingerprint and never issues a request), stays green through it.

  So these tests assert on the RESPONSE and on the ROW, never on the shape of
  the controller. A receipt that says `recorded: true` must be backed by a
  `search_intel_events` row bearing exactly that id.

  Reachability is the load-bearing judgment and is re-derived from
  `router.ex` (not inherited). THE ROUTES THESE CASES ACTUALLY HIT ARE THE FLAT
  ONES, and they are the only ones cited here — a correction the wave-47
  reviewer made after re-walking the enclosing `scope` blocks:

    * `post("/search/:dataset/interaction", SearchController, …)` inside the
      `scope "/v1/data"` whose `pipe_through` is `[:api, :api_grant_read]`
    * `post("/:dataset/search/interaction", V1.MediaController, …)` inside the
      `scope "/v1/media"` whose `pipe_through` is `:api`

  Both are cited by SYMBOL rather than by `router.ex:<line>`. The line anchors
  they used to carry were already pointing at unrelated blocks and only passed
  the lineref sweep on a weak word match; a 38-line insertion elsewhere in the
  router moved the coincidence away and the gate caught it.

  Neither pipeline carries `:require_token`, `:require_write` or
  `:require_admin`; `:api` authenticates through `Plugs.OptionalToken`, so an
  ANONYMOUS caller reaches both arms.

  `:2190` and `:2416` carry the SAME controller actions but live inside
  `scope "/w/:workspace_slug/p/:project_slug"` on `pipe_through(:scoped_api)` —
  the workspace-scoped mirror. Their full paths are prefixed with the two
  slugs, so nothing in this file dispatches to them and their pipeline is NOT
  the one these cases prove anything about. That mirror is unpinned here and
  deliberately so; naming it as though it were the flat route would be a
  reachability claim that does not descend from the request the test issues.

  Every case below posts WITHOUT an authorization header, and the first two
  tests prove that anonymity is real rather than assumed — a run, not a read.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.Search.Event
  alias Barkpark.Search.MediaIntelligence
  alias Barkpark.Content.SearchIntelligence

  @dataset "production"

  # int4 column, int8 value: the insert raises on parameter encoding, the
  # `rescue` in Intelligence.record_interaction/4 turns it into
  # `{:skipped, :error}`, and the controller must say 500 — the one arm of the
  # status split that had never executed anywhere.
  @int4_overflow "3000000000"

  setup do
    Repo.delete_all(from(e in Event, where: e.surface in ["documents", "media"]))
    :ok
  end

  defp documents_parent_event do
    {:ok, id} =
      SearchIntelligence.record(@dataset, %{"q" => "receipt pin"}, 3, 7, actor_key: "anon")

    id
  end

  defp media_parent_event do
    {:ok, id} =
      MediaIntelligence.record(@dataset, %{"q" => "receipt pin"}, 3, 7, actor_key: "anon")

    id
  end

  # Anonymous on purpose: the receipt has to hold for the caller the routes
  # actually admit, not for an operator with an admin token.
  defp post_documents_interaction(conn, params, headers \\ []) do
    headers
    |> Enum.reduce(conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    |> post(~p"/v1/data/search/#{@dataset}/interaction", params)
  end

  defp post_media_interaction(conn, params, headers \\ []) do
    headers
    |> Enum.reduce(conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    |> post(~p"/v1/media/#{@dataset}/search/interaction", params)
  end

  describe "reachability — the receipt is on a path a real, non-admin caller can hit" do
    test "documents interaction answers an ANONYMOUS post (no token, no admin)", %{conn: conn} do
      resp =
        post_documents_interaction(conn, %{
          "queryEventId" => documents_parent_event(),
          "objectId" => "doc-receipt-1"
        })

      refute resp.status in [401, 403, 404],
             "POST /v1/data/search/#{@dataset}/interaction must be reachable anonymously " <>
               "(router.ex:1655 in scope \"/v1/data\", pipe_through [:api, :api_grant_read] — " <>
               "no :require_token/:require_admin), got #{resp.status}"

      assert resp.status == 200
    end

    test "media interaction answers an ANONYMOUS post (no token, no admin)", %{conn: conn} do
      resp =
        post_media_interaction(conn, %{
          "queryEventId" => media_parent_event(),
          "objectId" => "asset-receipt-1"
        })

      refute resp.status in [401, 403, 404],
             "POST /v1/media/#{@dataset}/search/interaction must be reachable anonymously " <>
               "(router.ex:2111 in scope \"/v1/media\", pipe_through :api — " <>
               "no :require_token/:require_admin), got #{resp.status}"

      assert resp.status == 200
    end
  end

  describe "documents interaction receipt (POST /v1/data/search/:dataset/interaction)" do
    test "a recorded click answers 200 recorded:true AND the id names a real row", %{conn: conn} do
      parent = documents_parent_event()

      body =
        conn
        |> post_documents_interaction(%{
          "queryEventId" => parent,
          "objectId" => "doc-receipt-1",
          "position" => 2,
          "type" => "select"
        })
        |> json_response(200)

      assert body["ok"] == true
      assert body["recorded"] == true
      assert is_binary(body["interactionEventId"])

      # The receipt is only true if a row backs it. This is the assertion the
      # module-seam pin could not make: a fabricated `{:ok, uuid}` in the
      # callee satisfies every other check on this response and dies here.
      row = Repo.get(Event, body["interactionEventId"])

      assert row, "recorded:true handed back an interactionEventId with no event row behind it"
      assert row.surface == "documents"
      assert row.scope == @dataset
      assert row.event_type == "select"
      assert row.object_id == "doc-receipt-1"
      assert row.query_event_id == parent
    end

    test "a switched-off recorder answers 200 recorded:false reason recording_disabled", %{
      conn: conn
    } do
      body =
        conn
        |> post_documents_interaction(
          %{"queryEventId" => documents_parent_event(), "objectId" => "doc-receipt-1"},
          [{"x-bp-search-disable", "1"}]
        )
        |> json_response(200)

      assert body["ok"] == true
      assert body["recorded"] == false
      assert body["reason"] == "recording_disabled"
      refute Map.has_key?(body, "interactionEventId")

      assert Repo.aggregate(
               from(e in Event, where: e.surface == "documents" and e.event_type != "search"),
               :count
             ) == 0
    end

    test "an incomplete reference answers 422 ok:false recorded:false", %{conn: conn} do
      body =
        conn
        |> post_documents_interaction(%{"queryEventId" => documents_parent_event()})
        |> json_response(422)

      assert body["ok"] == false
      assert body["recorded"] == false
      assert body["reason"] == "incomplete_reference"
    end

    test "an unknown query event answers 422 ok:false recorded:false", %{conn: conn} do
      body =
        conn
        |> post_documents_interaction(%{
          "queryEventId" => Ecto.UUID.generate(),
          "objectId" => "doc-receipt-1"
        })
        |> json_response(422)

      assert body["ok"] == false
      assert body["recorded"] == false
      assert body["reason"] == "unknown_query_event"
    end

    test "a lost write answers 500 ok:false recorded:false reason error", %{conn: conn} do
      body =
        conn
        |> post_documents_interaction(%{
          "queryEventId" => documents_parent_event(),
          "objectId" => "doc-receipt-1",
          "position" => @int4_overflow
        })
        |> json_response(500)

      assert body["ok"] == false
      assert body["recorded"] == false
      assert body["reason"] == "error"
    end
  end

  describe "media interaction receipt (POST /v1/media/:dataset/search/interaction)" do
    test "a recorded click answers 200 recorded:true AND the id names a real row", %{conn: conn} do
      parent = media_parent_event()

      body =
        conn
        |> post_media_interaction(%{
          "queryEventId" => parent,
          "objectId" => "asset-receipt-1",
          "position" => 1,
          "type" => "click"
        })
        |> json_response(200)

      assert body["ok"] == true
      assert body["recorded"] == true
      assert is_binary(body["interactionEventId"])

      row = Repo.get(Event, body["interactionEventId"])

      assert row, "recorded:true handed back an interactionEventId with no event row behind it"
      assert row.surface == "media"
      assert row.scope == @dataset
      assert row.event_type == "click"
      assert row.object_id == "asset-receipt-1"
      assert row.query_event_id == parent
    end

    test "a switched-off recorder answers 200 recorded:false reason recording_disabled", %{
      conn: conn
    } do
      body =
        conn
        |> post_media_interaction(
          %{"queryEventId" => media_parent_event(), "objectId" => "asset-receipt-1"},
          [{"x-bp-search-disable", "1"}]
        )
        |> json_response(200)

      assert body["ok"] == true
      assert body["recorded"] == false
      assert body["reason"] == "recording_disabled"
      refute Map.has_key?(body, "interactionEventId")

      assert Repo.aggregate(
               from(e in Event, where: e.surface == "media" and e.event_type != "search"),
               :count
             ) == 0
    end

    test "an incomplete reference answers 422 ok:false recorded:false", %{conn: conn} do
      body =
        conn
        |> post_media_interaction(%{"queryEventId" => media_parent_event()})
        |> json_response(422)

      assert body["ok"] == false
      assert body["recorded"] == false
      assert body["reason"] == "incomplete_reference"
    end

    test "an unknown query event answers 422 ok:false recorded:false", %{conn: conn} do
      body =
        conn
        |> post_media_interaction(%{
          "queryEventId" => Ecto.UUID.generate(),
          "objectId" => "asset-receipt-1"
        })
        |> json_response(422)

      assert body["ok"] == false
      assert body["recorded"] == false
      assert body["reason"] == "unknown_query_event"
    end

    test "a lost write answers 500 ok:false recorded:false reason error", %{conn: conn} do
      body =
        conn
        |> post_media_interaction(%{
          "queryEventId" => media_parent_event(),
          "objectId" => "asset-receipt-1",
          "position" => @int4_overflow
        })
        |> json_response(500)

      assert body["ok"] == false
      assert body["recorded"] == false
      assert body["reason"] == "error"
    end
  end
end
