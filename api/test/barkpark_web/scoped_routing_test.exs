defmodule BarkparkWeb.ScopedRoutingTest do
  @moduledoc """
  End-to-end conn tests for the path-based tenancy routing layer (task
  barkpark-nf5z):

    * the scoped /w/:ws/p/:project/v1/data/query/:dataset/:type route resolves
      the workspace + project and reaches the controller (200),
    * an unknown workspace slug → 404,
    * a token that is not a member of the target workspace → 403
      (the cross-dataset read-leak fix at the routing layer),
    * the flat /v1/data/query/:dataset/:type route still works and gets the
      Default scope assigned (back-compat alias).
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tenancy}

  @dataset "scoped_routing_ds"

  setup do
    # The test DB is migrated, so the Default Workspace ("default") + Default
    # Project ("default") are already seeded by the backfill migration.
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset
      )

    # A second, isolated workspace + project the Default-bound token is NOT a
    # member of — used to prove the 403 membership gate.
    {:ok, other_ws} = Tenancy.create_workspace(%{slug: "other-ws", name: "Other WS"})
    {:ok, _other_project} = Tenancy.create_project(other_ws, %{slug: "other-proj", name: "Other"})

    # create_token/4 (no explicit workspace_id) binds to the seeded Default
    # Workspace AND creates a membership — so this token is a Default member
    # with read/write perms, but NOT a member of "other-ws".
    raw = "scoped-routing-token-#{System.unique_integer([:positive])}"
    {:ok, _token} = Auth.create_token(raw, "scoped routing", @dataset, ["read", "write"])

    {:ok, raw_token: raw}
  end

  defp authed(conn, raw) do
    conn
    |> put_req_header("authorization", "Bearer " <> raw)
  end

  describe "scoped /w/:ws/p/:project routes" do
    test "resolves workspace+project and reaches the controller (200)", %{
      conn: conn,
      raw_token: raw
    } do
      resp =
        conn
        |> authed(raw)
        |> get("/w/default/p/default/v1/data/query/#{@dataset}/post")

      assert resp.status == 200
      assert resp.assigns.current_workspace.slug == "default"
      assert resp.assigns.current_project.slug == "default"
    end

    test "unknown workspace slug → 404", %{conn: conn, raw_token: raw} do
      resp =
        conn
        |> authed(raw)
        |> get("/w/no-such-ws/p/default/v1/data/query/#{@dataset}/post")

      assert resp.status == 404
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "not_found"
    end

    test "unknown project slug within a real workspace → 404", %{conn: conn, raw_token: raw} do
      resp =
        conn
        |> authed(raw)
        |> get("/w/default/p/no-such-proj/v1/data/query/#{@dataset}/post")

      assert resp.status == 404
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "not_found"
    end

    test "token not a member of the target workspace → 403 (read-leak gate)", %{
      conn: conn,
      raw_token: raw
    } do
      resp =
        conn
        |> authed(raw)
        |> get("/w/other-ws/p/other-proj/v1/data/query/#{@dataset}/post")

      assert resp.status == 403
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "forbidden"
    end

    test "anonymous caller (no token) → 403 — authorize/3 fails closed", %{conn: conn} do
      resp = get(conn, "/w/default/p/default/v1/data/query/#{@dataset}/post")

      assert resp.status == 403
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "forbidden"
    end
  end

  describe "back-compat flat routes" do
    test "flat /v1/data/query/:dataset/:type still works and gets the Default scope" do
      # Public schema, no token needed on the flat path (unchanged behavior).
      resp = get(scoped_conn(), "/v1/data/query/#{@dataset}/post")

      assert resp.status == 200
      # AssignDefaultScope populated the scope for downstream code.
      assert resp.assigns.current_workspace.slug == "default"
      assert resp.assigns.current_project.slug == "default"
    end
  end
end
