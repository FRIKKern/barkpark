defmodule BarkparkWeb.DataCountsTest do
  @moduledoc """
  `GET /v1/data/counts/:dataset` — bundled per-type published-document counts in
  ONE `GROUP BY d.type` aggregate (AXI charter decision 19 / manifest
  `data.counts`).

  Proves four contracts:

    * FROZEN response shape — `{ok, dataset, perspective:"published",
      counts:{type => N}}` — the Go bare-noun slice consumes it verbatim.
    * Perspective fixed to `:published` — a created-but-unpublished (drafts.-
      prefixed) doc is NEVER counted.
    * Tenancy FAILS CLOSED — workspace A's counts never include workspace B's
      documents, even when both share the dataset string and doc_ids collide
      (the axi-s1 cross-tenant existence-count-leak precedent; an unscoped
      GROUP BY would leak the mere EXISTENCE of another tenant's docs).
    * Auth is existence-hiding — an anonymous caller gets 404, never a census
      of the tenant's private types.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Tenancy}

  @dataset "data_counts_leak_ds"

  setup do
    # Two workspaces sharing one dataset string — the cross-tenant collision
    # axis. Each holds its own docs; the scoped route resolves the caller's real
    # workspace so the aggregate must filter by workspace_id.
    {:ok, ws_a} = Tenancy.create_workspace(%{slug: "ws-a-counts", name: "WS A"})
    {:ok, proj_a} = Tenancy.create_project(ws_a, %{slug: "proj-a", name: "P A"})

    {:ok, ws_b} = Tenancy.create_workspace(%{slug: "ws-b-counts", name: "WS B"})
    {:ok, proj_b} = Tenancy.create_project(ws_b, %{slug: "proj-b", name: "P B"})

    scope_a = [workspace_id: ws_a.id, project_id: proj_a.id]
    scope_b = [workspace_id: ws_b.id, project_id: proj_b.id]

    for name <- ["post", "note"] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => name,
            "title" => String.capitalize(name),
            "visibility" => "public",
            "fields" => [%{"name" => "title", "type" => "string"}]
          },
          @dataset
        )
    end

    # Workspace A: 2 published posts + 1 published note, plus 1 DRAFT post that
    # must never count (published perspective).
    publish(scope_a, "post", "pa1")
    publish(scope_a, "post", "pa2")
    publish(scope_a, "note", "na1")
    {:ok, _} = Content.create_document("post", %{"_id" => "pa-draft"}, @dataset, scope_a)

    # Workspace B: 3 published posts — the leak signature is A's post count
    # jumping to 5 (2 + B's 3) if the GROUP BY is unscoped.
    publish(scope_b, "post", "pb1")
    publish(scope_b, "post", "pb2")
    publish(scope_b, "post", "pb3")

    raw_a = "counts-a-#{System.unique_integer([:positive])}"
    raw_b = "counts-b-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw_a, "WS A token", @dataset, ["read"], ws_a.id)
    {:ok, _} = Auth.create_token(raw_b, "WS B token", @dataset, ["read"], ws_b.id)

    {:ok, raw_a: raw_a, raw_b: raw_b}
  end

  defp publish(scope, type, id) do
    {:ok, _} = Content.create_document(type, %{"_id" => id, "title" => id}, @dataset, scope)
    {:ok, _} = Content.publish_document(id, type, @dataset, scope)
  end

  defp authed(conn, raw),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> raw)

  describe "GET /w/:ws/p/:project/v1/data/counts/:dataset" do
    test "returns the frozen shape with per-type published counts, drafts excluded",
         %{conn: conn, raw_a: raw_a} do
      body =
        conn
        |> authed(raw_a)
        |> get("/w/ws-a-counts/p/proj-a/v1/data/counts/#{@dataset}")
        |> json_response(200)

      assert body["ok"] == true
      assert body["dataset"] == @dataset
      assert body["perspective"] == "published"
      # Draft `pa-draft` is NOT in the count → post is 2, not 3.
      assert body["counts"] == %{"post" => 2, "note" => 1}
    end

    test "workspace A's counts NEVER include workspace B's documents (tenancy fail-closed)",
         %{conn: conn, raw_a: raw_a} do
      body =
        conn
        |> authed(raw_a)
        |> get("/w/ws-a-counts/p/proj-a/v1/data/counts/#{@dataset}")
        |> json_response(200)

      # The leak signature: an unscoped GROUP BY would return post => 5 (A's 2 +
      # B's 3) and expose that B holds docs at all. Scoped, A sees only its own.
      assert body["counts"]["post"] == 2
      refute body["counts"]["post"] == 5
    end

    test "workspace B sees only its own counts (mirror direction)",
         %{conn: conn, raw_b: raw_b} do
      body =
        conn
        |> authed(raw_b)
        |> get("/w/ws-b-counts/p/proj-b/v1/data/counts/#{@dataset}")
        |> json_response(200)

      assert body["counts"] == %{"post" => 3}
      # B holds no notes — the note type never leaks in from A.
      refute Map.has_key?(body["counts"], "note")
    end
  end

  describe "GET /v1/data/counts/:dataset (flat route)" do
    test "an anonymous caller is existence-hidden (404, never a census)", %{conn: conn} do
      conn
      |> get("/v1/data/counts/#{@dataset}")
      |> json_response(404)
    end

    test "a token caller gets the frozen shape", %{conn: conn, raw_a: raw_a} do
      body =
        conn
        |> authed(raw_a)
        |> get("/v1/data/counts/#{@dataset}")
        |> json_response(200)

      assert body["ok"] == true
      assert body["perspective"] == "published"
      assert is_map(body["counts"])
    end
  end

  describe "?perspective is refused, never silently ignored (PDS-D303)" do
    # It used to be read and dropped: ?perspective=raw and ?perspective=zzzbogus
    # both returned 200 with a byte-identical published body still labelled
    # "perspective":"published" — the caller asked for drafts, got the published
    # number, and had no signal at all. The endpoint honours exactly one
    # perspective, so it now says so.
    test "the honoured value passes: ?perspective=published is 200 and unchanged",
         %{conn: conn, raw_a: raw_a} do
      body =
        conn
        |> authed(raw_a)
        |> get("/w/ws-a-counts/p/proj-a/v1/data/counts/#{@dataset}?perspective=published")
        |> json_response(200)

      assert body["ok"] == true
      assert body["perspective"] == "published"
      assert body["counts"] == %{"post" => 2, "note" => 1}
    end

    test "?perspective=raw is refused with a 400 naming the parameter",
         %{conn: conn, raw_a: raw_a} do
      body =
        conn
        |> authed(raw_a)
        |> get("/w/ws-a-counts/p/proj-a/v1/data/counts/#{@dataset}?perspective=raw")
        |> json_response(400)

      assert body["error"]["code"] == "malformed"
      assert body["error"]["message"] =~ "perspective"
      assert body["error"]["details"]["parameter"] == "perspective"
      assert body["error"]["details"]["supported"] == ["published"]
      assert body["error"]["details"]["received"] == "raw"
      # The refusal is a refusal — no counts leak out beside it.
      refute Map.has_key?(body, "counts")
    end

    test "a garbage perspective is refused too (allowlist, not a denylist)",
         %{conn: conn, raw_a: raw_a} do
      body =
        conn
        |> authed(raw_a)
        |> get("/w/ws-a-counts/p/proj-a/v1/data/counts/#{@dataset}?perspective=zzzbogus")
        |> json_response(400)

      assert body["error"]["code"] == "malformed"
      assert body["error"]["details"]["received"] == "zzzbogus"
    end

    test "the absent-param default is untouched (no perspective → 200 published)",
         %{conn: conn, raw_a: raw_a} do
      body =
        conn
        |> authed(raw_a)
        |> get("/w/ws-a-counts/p/proj-a/v1/data/counts/#{@dataset}")
        |> json_response(200)

      assert body["perspective"] == "published"
      assert body["counts"] == %{"post" => 2, "note" => 1}
    end

    test "the flat route shares the action, so it refuses identically",
         %{conn: conn, raw_a: raw_a} do
      body =
        conn
        |> authed(raw_a)
        |> get("/v1/data/counts/#{@dataset}?perspective=raw")
        |> json_response(400)

      assert body["error"]["code"] == "malformed"
    end

    test "an anonymous caller stays existence-hidden even on a bad perspective (404, not 400)",
         %{conn: conn} do
      conn
      |> get("/v1/data/counts/#{@dataset}?perspective=raw")
      |> json_response(404)
    end
  end
end
