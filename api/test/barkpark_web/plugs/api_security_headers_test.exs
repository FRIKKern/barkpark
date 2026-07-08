defmodule BarkparkWeb.Plugs.ApiSecurityHeadersTest do
  @moduledoc """
  Pins the baseline security headers `ApiSecurityHeaders` attaches to JSON API
  responses. Covers three pipelines end-to-end:

    * flat `:api` (`/v1/capabilities`, no token, no DB setup),
    * `:scoped_api` (`/w/:ws/p/:project/v1/data/search/:dataset` — the tenancy
      mirror), and
    * `:shared_docs_api` (`/w/:ws/p/:project/v1/data/query/:dataset/:type` — the
      anonymous-shareable document read, which is where the canonical scoped
      `data/query` reads actually dispatch).

  The non-overwrite direction is pinned at the plug unit level so a
  controller/CORS-set value is proven to survive untouched.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content}

  @dataset "sec_headers_scoped_ds"

  # create_token/4 (no explicit workspace_id) binds to the seeded Default
  # workspace AND creates a Default membership — so this token passes
  # ResolveWorkspace's :read gate on /w/default/p/default/*.
  defp default_member_token do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset
      )

    raw = "sec-headers-token-#{System.unique_integer([:positive])}"
    {:ok, _token} = Auth.create_token(raw, "sec headers", @dataset, ["read"])
    raw
  end

  test "GET /v1/capabilities (flat :api) carries nosniff + referrer-policy", %{conn: conn} do
    conn = get(conn, "/v1/capabilities")

    assert conn.status == 200
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

    assert get_resp_header(conn, "referrer-policy") == [
             "strict-origin-when-cross-origin"
           ]
  end

  test "GET scoped search (:scoped_api) carries nosniff + referrer-policy", %{conn: conn} do
    raw = default_member_token()

    resp =
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> get("/w/default/p/default/v1/data/search/#{@dataset}?q=anything")

    # The response is served (header add does not break the body)...
    assert resp.status == 200
    # ...it ran the :scoped_api pipeline (resolvers set the real scope)...
    assert resp.assigns.current_workspace.slug == "default"
    # ...and carries the baseline JSON security headers — the parity fix.
    assert get_resp_header(resp, "x-content-type-options") == ["nosniff"]

    assert get_resp_header(resp, "referrer-policy") == [
             "strict-origin-when-cross-origin"
           ]
  end

  test "GET scoped data/query (:shared_docs_api) carries nosniff + referrer-policy", %{conn: conn} do
    raw = default_member_token()

    resp =
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> get("/w/default/p/default/v1/data/query/#{@dataset}/post")

    assert resp.status == 200
    assert resp.assigns.current_workspace.slug == "default"
    assert get_resp_header(resp, "x-content-type-options") == ["nosniff"]

    assert get_resp_header(resp, "referrer-policy") == [
             "strict-origin-when-cross-origin"
           ]
  end

  test "the plug does not overwrite a header already present on the response" do
    # Both directions of the non-overwrite contract: a value a controller (or
    # CORS layer) already set survives untouched, while the absent header is
    # still added. register_before_send must never stomp a set value.
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_resp_header("referrer-policy", "no-referrer")
      |> BarkparkWeb.Plugs.ApiSecurityHeaders.call([])
      |> Plug.Conn.send_resp(200, "{}")

    # Pre-existing value is preserved (single value, not doubled)...
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    # ...and the absent header is still added.
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end
end
