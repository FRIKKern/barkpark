defmodule BarkparkWeb.WsBVisibilityTest do
  @moduledoc """
  WS-B negative tests — a private field NEVER reaches a non-authorized caller
  through the legacy `/api/documents/*` dump (HIGH-1) nor as a filter/order
  oracle on `/v1/data/query` (MEDIUM-4), and the query body itself redacts it.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Tenancy}

  @prod "production"
  @dataset "wsb_query_test"

  @admin_token "wsb-admin-#{System.unique_integer([:positive])}"
  @reader_token "wsb-reader-#{System.unique_integer([:positive])}"

  setup do
    ws = Tenancy.get_default_workspace()
    project = Tenancy.get_default_project()
    scope = [workspace_id: ws.id, project_id: project.id]

    # ── Legacy fixtures (HIGH-1) live in the production dataset the
    #    LegacyController hardcodes, Default-scoped like every flat-route row.
    Content.upsert_schema(
      %{
        "name" => "wsbsecretdoc",
        "title" => "Secret Doc",
        "visibility" => "public",
        "fields" => [
          %{"name" => "name", "type" => "string"},
          %{"name" => "secret", "type" => "string", "private" => true}
        ]
      },
      @prod
    )

    {:ok, _} =
      Content.create_document(
        "wsbsecretdoc",
        %{
          "_id" => "wsb-secret-1",
          "title" => "Doc",
          "content" => %{"name" => "pub", "secret" => "TOPSECRET"}
        },
        @prod,
        scope
      )

    {:ok, _} = Content.publish_document("wsb-secret-1", "wsbsecretdoc", @prod, scope)

    # ── Query fixtures (MEDIUM-4) — public schema so an anonymous caller reaches
    #    the query, with a private `salary` field that must stay hidden.
    Content.upsert_schema(
      %{
        "name" => "report",
        "title" => "Report",
        "visibility" => "public",
        "fields" => [
          %{"name" => "name", "type" => "string"},
          %{"name" => "salary", "type" => "string", "private" => true}
        ]
      },
      @dataset
    )

    {:ok, _} =
      Content.create_document(
        "report",
        %{
          "_id" => "rep-1",
          "title" => "R",
          "content" => %{"name" => "alice", "salary" => "99999"}
        },
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("rep-1", "report", @dataset, scope)

    {:ok, _} = Auth.create_token(@admin_token, "wsb admin", @prod, ["admin"])
    {:ok, _} = Auth.create_token(@reader_token, "wsb reader", @prod, ["read", "write"])

    :ok
  end

  defp bearer(conn, token),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)

  # ── HIGH-1: legacy /api/documents/* must not dump a private field ───────────

  describe "GET /api/documents/:type (legacy)" do
    test "non-admin token does NOT see a private field", %{conn: conn} do
      body =
        conn
        |> bearer(@reader_token)
        |> get("/api/documents/wsbsecretdoc/wsb-secret-1")
        |> json_response(200)

      assert body["values"]["name"] == "pub"
      refute Map.has_key?(body["values"], "secret")
    end

    test "non-admin token list view redacts the private field", %{conn: conn} do
      body =
        conn
        |> bearer(@reader_token)
        |> get("/api/documents/wsbsecretdoc")
        |> json_response(200)

      doc = Enum.find(body["documents"], &(&1["id"] == "wsb-secret-1"))
      assert doc["values"]["name"] == "pub"
      refute Map.has_key?(doc["values"], "secret")
    end

    test "admin token DOES see the private field", %{conn: conn} do
      body =
        conn
        |> bearer(@admin_token)
        |> get("/api/documents/wsbsecretdoc/wsb-secret-1")
        |> json_response(200)

      assert body["values"]["secret"] == "TOPSECRET"
    end

    test "non-admin filter on a private field is rejected (no count oracle)", %{conn: conn} do
      resp =
        conn
        |> bearer(@reader_token)
        |> get("/api/documents/wsbsecretdoc?filter=secret=TOPSECRET")

      assert resp.status == 422
      body = json_response(resp, 422)
      # Canonical envelope: code + details.field (was a bare top-level `field`).
      assert body["error"]["code"] == "forbidden_field"
      assert body["error"]["details"]["field"] == "secret"
      # The oracle side channel (`count`) must never leak from a forbidden filter.
      refute Map.has_key?(body, "count")
    end

    test "non-admin filter on a PUBLIC field is allowed", %{conn: conn} do
      body =
        conn
        |> bearer(@reader_token)
        |> get("/api/documents/wsbsecretdoc?filter=name=pub")
        |> json_response(200)

      assert body["count"] == 1
    end

    test "admin MAY filter on the private field", %{conn: conn} do
      body =
        conn
        |> bearer(@admin_token)
        |> get("/api/documents/wsbsecretdoc?filter=secret=TOPSECRET")
        |> json_response(200)

      assert Enum.any?(body["documents"], &(&1["id"] == "wsb-secret-1"))
    end
  end

  # ── Revision-detail must redact like the live read path ─────────────────────

  describe "GET /v1/data/revision/:dataset/:id (history snapshot)" do
    setup %{conn: conn} do
      ws = Tenancy.get_default_workspace()
      project = Tenancy.get_default_project()
      scope = [workspace_id: ws.id, project_id: project.id]

      [rev | _] =
        Content.list_revisions("wsb-secret-1", "wsbsecretdoc", @prod, scope)

      %{conn: conn, rev_id: rev.id}
    end

    test "non-admin token does NOT see a private field in the snapshot", %{
      conn: conn,
      rev_id: rev_id
    } do
      body =
        conn
        |> bearer(@reader_token)
        |> get("/v1/data/revision/#{@prod}/#{rev_id}")
        |> json_response(200)

      assert body["revision"]["content"]["name"] == "pub"
      refute Map.has_key?(body["revision"]["content"], "secret")
    end

    test "admin token DOES see the private field in the snapshot", %{
      conn: conn,
      rev_id: rev_id
    } do
      body =
        conn
        |> bearer(@admin_token)
        |> get("/v1/data/revision/#{@prod}/#{rev_id}")
        |> json_response(200)

      assert body["revision"]["content"]["secret"] == "TOPSECRET"
    end
  end

  # ── MEDIUM-4: filter/order oracle + body redaction on /v1/data/query ────────

  describe "GET /v1/data/query (filter/order oracle)" do
    test "anonymous query redacts the private field in the body", %{conn: conn} do
      body =
        conn
        |> get("/v1/data/query/#{@dataset}/report")
        |> json_response(200)

      doc = Enum.find(body["result"]["documents"], &(&1["_id"] == "rep-1"))
      assert doc["name"] == "alice"
      refute Map.has_key?(doc, "salary")
    end

    test "anonymous filter on a private field is rejected (422)", %{conn: conn} do
      resp = get(conn, "/v1/data/query/#{@dataset}/report?filter[salary][eq]=99999")
      assert resp.status == 422
      assert json_response(resp, 422)["error"]["details"]["field"] == "salary"
    end

    test "anonymous order by a private field is rejected (422)", %{conn: conn} do
      resp = get(conn, "/v1/data/query/#{@dataset}/report?order=salary:asc")
      assert resp.status == 422
      assert json_response(resp, 422)["error"]["details"]["field"] == "salary"
    end

    test "anonymous filter on a PUBLIC field is allowed", %{conn: conn} do
      body =
        conn
        |> get("/v1/data/query/#{@dataset}/report?filter[name][eq]=alice")
        |> json_response(200)

      assert Enum.any?(body["result"]["documents"], &(&1["_id"] == "rep-1"))
    end

    test "admin token MAY filter on the private field", %{conn: conn} do
      body =
        conn
        |> bearer(@admin_token)
        |> get("/v1/data/query/#{@dataset}/report?filter[salary][eq]=99999")
        |> json_response(200)

      assert Enum.any?(body["result"]["documents"], &(&1["_id"] == "rep-1"))
    end
  end
end
