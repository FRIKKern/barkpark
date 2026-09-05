defmodule BarkparkWeb.NonBinaryParamSweepTest do
  @moduledoc """
  Class-sweep regression guard for the non-binary query-param 500
  (task `drafts.loop-param-sweep`).

  Phoenix's `Plug.Conn.Query` parser turns `?q[]=a&q[]=b` into a LIST and
  `?q[k]=v` into a MAP. A controller that then feeds that value to
  `String.split/2`, `escape_like/1`, an Ecto cast, or a `<<_>>`-headed function
  clause raises `FunctionClauseError` / `Ecto.CastError` → HTTP 500 instead of a
  clean 4xx. Every scalar-param read now flows through the one shared
  `BarkparkWeb.ParamCoercion.bin/1` seam (list/map/other → nil), so a hostile or
  malformed query degrades to the missing-param path rather than crashing.

  Two layers:

    * pure unit tests of the shared `bin/1` helper (no DB), and
    * request tests that fire an array param AND a map param at every controller
      endpoint that reads a scalar query param, asserting NONE 500. The endpoint
      list is enumerated in one table so a newly-added controller that reads a
      raw scalar param without the seam trips this test.

  Two of these endpoints genuinely 500'd before the fix:

    * `GET /api/documents/:type?filter[]=x` — `LegacyController.parse_legacy_filter/1`
      called `String.split(list, "=")`, and
    * `GET /v1/media/:dataset?q[]=x` — the media index passed a list `q` through
      to `escape_like/1` (`String.replace(list, …)`).
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content}
  alias Barkpark.Search.SurfaceConfigs
  alias BarkparkWeb.ParamCoercion

  @token "barkpark-dev-token"
  @ds "test"

  describe "ParamCoercion.bin/1 — the shared coercion seam" do
    test "passes a binary through unchanged" do
      assert ParamCoercion.bin("post") == "post"
      assert ParamCoercion.bin("") == ""
    end

    test "collapses every non-binary shape to nil (the absent-param sentinel)" do
      assert ParamCoercion.bin(["a", "b"]) == nil
      assert ParamCoercion.bin(%{"k" => "v"}) == nil
      assert ParamCoercion.bin(nil) == nil
      assert ParamCoercion.bin(42) == nil
      assert ParamCoercion.bin(:atom) == nil
    end
  end

  describe "no controller 500s on a non-binary query param" do
    setup %{conn: conn} do
      Auth.create_token(@token, "dev", "param-sweep", ["read", "write", "admin"])
      SurfaceConfigs.seed_defaults!()

      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
          "production"
        )

      # A read+write+admin token satisfies both :require_token (legacy) and
      # :require_admin (synonyms) routes; the public :api routes ignore it.
      {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> @token)}
    end

    # One row per GET endpoint that reads a scalar query param. Sending BOTH `q`
    # and `filter` on every request is harmless (unused params are ignored) and
    # keeps the table uniform across the search / media / legacy / federated
    # surfaces.
    @endpoints [
      "/api/documents/post",
      "/v1/media/#{@ds}",
      "/v1/data/search/#{@ds}/suggestions",
      "/v1/media/#{@ds}/search/suggestions",
      "/v1/data/search/#{@ds}/synonyms/preview",
      "/v1/media/#{@ds}/search/synonyms/preview",
      "/v1/search/#{@ds}"
    ]

    for path <- @endpoints do
      test "GET #{path} — array param ?q[]=… & ?filter[]=… stays < 500", %{conn: conn} do
        resp = get(conn, unquote(path), %{"q" => ["a", "b"], "filter" => ["x", "y"]})
        refute resp.status == 500
        assert resp.status < 500
      end

      test "GET #{path} — map param ?q[k]=… & ?filter[k]=… stays < 500", %{conn: conn} do
        resp = get(conn, unquote(path), %{"q" => %{"k" => "v"}, "filter" => %{"k" => "v"}})
        refute resp.status == 500
        assert resp.status < 500
      end
    end
  end

  # `limit`/`offset` flow through each controller's private `parse_int/2`, which
  # only matched nil/binary/integer — a list param (`?limit[]=1`) raised
  # FunctionClauseError → 500 before the catch-all clause was added. (ListenController
  # reads the analogous `lastEventId` scalar but streams SSE, so it can't be exercised
  # in a synchronous request test; its catch-all is covered by the code fix.)
  describe "no controller 500s on a non-binary pagination param" do
    setup %{conn: conn} do
      Auth.create_token(@token, "dev", "pagination-sweep", ["read", "write", "admin"])
      SurfaceConfigs.seed_defaults!()

      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
          @ds
        )

      {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> @token)}
    end

    @pagination_endpoints [
      "/v1/data/query/#{@ds}/post",
      "/v1/data/history/#{@ds}/post/does-not-exist"
    ]

    for path <- @pagination_endpoints do
      test "GET #{path} — array ?limit[]=… & ?offset[]=… stays < 500", %{conn: conn} do
        resp = get(conn, unquote(path), %{"limit" => ["1", "2"], "offset" => ["3"]})
        refute resp.status == 500
        assert resp.status < 500
      end

      test "GET #{path} — map ?limit[k]=… & ?offset[k]=… stays < 500", %{conn: conn} do
        resp = get(conn, unquote(path), %{"limit" => %{"k" => "1"}, "offset" => %{"k" => "2"}})
        refute resp.status == 500
        assert resp.status < 500
      end
    end

    test "query index echoes a clamped limit/offset, not the raw over/under-range values",
         %{conn: conn} do
      resp = get(conn, "/v1/data/query/#{@ds}/post", %{"limit" => "999999", "offset" => "-5"})
      assert resp.status == 200
      result = json_response(resp, 200)["result"]
      assert result["limit"] == 1000
      assert result["offset"] == 0
    end
  end
end
