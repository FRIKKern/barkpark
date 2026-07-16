defmodule BarkparkWeb.Controllers.LegacyFilterParseTest do
  @moduledoc """
  Task `wbqs-api-legacy-filter-failopen`: `LegacyController.parse_legacy_filter/1`
  had a catch-all `_ -> %{}` that turned any non-`field=value` filter string
  (e.g. `?filter=price>10`) into an EMPTY filter — a fail-OPEN 200 returning
  every document instead of erroring. This is the same fail-open class
  `query_controller.ex` already guards for its filter operators
  (`invalid_filter_op` -> 400).

  MANDATORY FLAG: this converts a previously-silently-accepted malformed
  `filter=` string on the deprecated, token-gated `/api/documents/:type`
  surface from 200 (all documents) to 400 `invalid_filter`. Real behavior
  change on a shipped endpoint — low blast radius (deprecated + authed), but
  callers relying on the old fail-open leniency will now see a 400.

  `async: false` — mutates the shared `production` dataset + dev token,
  matching the sibling `legacy_crud_test.exs` convention.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content}

  @token "barkpark-legacy-filter-parse-token"
  @type_name "lfp_post"

  setup do
    Auth.create_token(@token, "dev", "legacy-filter-parse", ["read", "write", "admin"])

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => @type_name, "title" => "LFP Post", "visibility" => "public", "fields" => []},
        "production"
      )

    # `Content.create_document/3` coerces a caller-supplied "published" status
    # to "draft" (a drafts-prefixed row can't coherently carry "published") —
    # this doc lands with status "draft", not "published".
    {:ok, _} =
      Content.create_document(
        @type_name,
        %{"_id" => "lfp-1", "title" => "Alpha"},
        "production"
      )

    :ok
  end

  defp authed(conn) do
    put_req_header(conn, "authorization", "Bearer " <> @token)
  end

  describe "GET /api/documents/:type?filter=... — malformed filter fails CLOSED" do
    test "a garbage filter string (no field=value) -> 400 invalid_filter", %{conn: conn} do
      resp = conn |> authed() |> get(~p"/api/documents/#{@type_name}?filter=price>10")

      assert resp.status == 400
      error = json_response(resp, 400)["error"]
      assert error["code"] == "invalid_filter"
      assert error["message"] =~ "price>10"
      assert error["details"]["filter"] == "price>10"
    end

    test "a bare field name with no '=' at all -> 400 invalid_filter", %{conn: conn} do
      resp = conn |> authed() |> get(~p"/api/documents/#{@type_name}?filter=nonsense")

      assert resp.status == 400
      error = json_response(resp, 400)["error"]
      assert error["code"] == "invalid_filter"
      assert error["details"]["filter"] == "nonsense"
    end

    test "a valid field=value filter still works (200, filtered)", %{conn: conn} do
      body =
        conn
        |> authed()
        |> get(~p"/api/documents/#{@type_name}?filter=status=draft")
        |> json_response(200)

      assert body["type"] == @type_name
      assert body["count"] == 1
      assert Enum.map(body["documents"], & &1["id"]) == ["drafts.lfp-1"]
    end

    test "no filter param at all -> 200, all documents (regression)", %{conn: conn} do
      body =
        conn
        |> authed()
        |> get(~p"/api/documents/#{@type_name}")
        |> json_response(200)

      assert body["type"] == @type_name
      assert body["count"] == 1
    end

    test "an empty filter string -> 200, all documents (regression)", %{conn: conn} do
      body =
        conn
        |> authed()
        |> get(~p"/api/documents/#{@type_name}?filter=")
        |> json_response(200)

      assert body["type"] == @type_name
      assert body["count"] == 1
    end
  end
end
