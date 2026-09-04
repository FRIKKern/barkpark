defmodule BarkparkWeb.RestoreWriteGateTest do
  @moduledoc """
  Route-authorization coverage for the revision RESTORE surface.

  Restore is a real content WRITE (HistoryController.restore →
  Revisions.restore_revision → Content.upsert_document), yet the flat
  (`POST /v1/data/revision/:dataset/:id/restore`) and scoped
  (`POST /w/:ws/p/:project/v1/data/revision/:dataset/:id/restore`) routes sat on
  the token-only read pipelines ([:api, :require_token] /
  [:scoped_api, :require_token]) — MISSING the :require_write gate that
  /v1/data/mutate enforces. A read / public-read token could therefore overwrite
  or create a draft via restore. This test pins the gate on BOTH routes:

    * read-only token  → restore → 403 (write-gate)   ← fail-before / pass-after
    * write-capable    → restore → still succeeds (200) ← positive control
    * scoped route respects workspace scope (non-member → 403)

  The same finding covered the deprecated legacy write surface
  (`POST /api/documents/:type`, `DELETE /api/documents/:type/:id`) — see the
  legacy_document_write_gate assertions below.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  # ── Flat restore (Default-scoped) ─────────────────────────────────────────
  describe "flat restore write-gate (/v1/data/revision/:dataset/:id/restore)" do
    setup do
      Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])
      Auth.create_token("barkpark-readonly-token", "ro", "test", ["read"])

      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        "test"
      )

      {:ok, _} =
        Content.create_document("post", %{"doc_id" => "drafts.wg1", "title" => "V1"}, "test")

      Content.publish_document("wg1", "post", "test")

      Content.apply_mutations(
        [%{"patch" => %{"id" => "wg1", "type" => "post", "set" => %{"title" => "V2"}}}],
        "test"
      )

      oldest = Content.list_revisions("wg1", "post", "test") |> List.last()
      {:ok, rev_id: oldest.id}
    end

    defp restore(conn, raw, rev_id) do
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("content-type", "application/json")
      |> post("/v1/data/revision/test/#{rev_id}/restore", Jason.encode!(%{type: "post"}))
    end

    test "read-only token is rejected with 403 at the write-gate", %{conn: conn, rev_id: rev_id} do
      resp = restore(conn, "barkpark-readonly-token", rev_id)

      assert resp.status == 403,
             "read-only token reached restore (a content write) — status #{resp.status}"

      assert Jason.decode!(resp.resp_body)["error"]["code"] == "forbidden"
    end

    test "write-capable token still succeeds (positive control)", %{conn: conn, rev_id: rev_id} do
      resp = restore(conn, "barkpark-dev-token", rev_id)

      assert resp.status == 200,
             "legitimate writer was over-denied on restore — status #{resp.status}"

      assert Jason.decode!(resp.resp_body)["restored"] == true
    end
  end

  # ── Scoped restore (/w/:ws/p/:project/...) ────────────────────────────────
  describe "scoped restore write-gate" do
    @dataset "restore_write_gate_ds"

    setup do
      {:ok, ws} = Tenancy.create_workspace(%{slug: "restore-wg", name: "Restore WG"})
      {:ok, _proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})

      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
          @dataset,
          workspace_id: ws.id
        )

      # WRITE member: global write cap + member of the workspace.
      write_raw = "restore-wg-writer-#{System.unique_integer([:positive])}"
      {:ok, write_token} = Auth.create_token(write_raw, "writer", @dataset, ["read", "write"])
      {:ok, _} = TenancyAuth.create_membership(ws.id, write_token.id)

      # READ-ONLY member: member of the workspace, but NO global write cap.
      read_raw = "restore-wg-reader-#{System.unique_integer([:positive])}"
      {:ok, read_token} = Auth.create_token(read_raw, "reader", @dataset, ["read"])
      {:ok, _} = TenancyAuth.create_membership(ws.id, read_token.id)

      # NON-MEMBER: global write cap, but not a member of this workspace.
      nonmember_raw = "restore-wg-nonmember-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(nonmember_raw, "outsider", @dataset, ["read", "write"])

      # Drive doc creation over HTTP through the SAME scope the restore route
      # resolves, so the revision is guaranteed to live in the scoped dataset.
      base = "/w/restore-wg/p/default/v1/data"

      mutate = fn raw, mutations ->
        scoped_conn()
        |> put_req_header("authorization", "Bearer " <> raw)
        |> put_req_header("content-type", "application/json")
        |> post("#{base}/mutate/#{@dataset}", Jason.encode!(%{mutations: mutations}))
      end

      assert mutate.(write_raw, [
               %{"create" => %{"_id" => "swg1", "_type" => "post", "title" => "V1"}}
             ]).status == 200

      assert mutate.(write_raw, [
               %{"patch" => %{"id" => "swg1", "type" => "post", "set" => %{"title" => "V2"}}}
             ]).status == 200

      hist =
        scoped_conn()
        |> put_req_header("authorization", "Bearer " <> write_raw)
        |> get("#{base}/history/#{@dataset}/post/swg1")

      %{"revisions" => revisions} = Jason.decode!(hist.resp_body)
      oldest = List.last(revisions)

      {:ok,
       base: base,
       rev_id: oldest["id"],
       write_raw: write_raw,
       read_raw: read_raw,
       nonmember_raw: nonmember_raw}
    end

    defp scoped_restore(base, raw, rev_id) do
      scoped_conn()
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("content-type", "application/json")
      |> post("#{base}/revision/#{@dataset}/#{rev_id}/restore", Jason.encode!(%{type: "post"}))
    end

    test "read-only member is rejected with 403 at the write-gate", ctx do
      resp = scoped_restore(ctx.base, ctx.read_raw, ctx.rev_id)

      assert resp.status == 403,
             "read-only member reached scoped restore (a content write) — status #{resp.status}"

      assert Jason.decode!(resp.resp_body)["error"]["code"] == "forbidden"
    end

    test "write-capable member still succeeds (positive control)", ctx do
      resp = scoped_restore(ctx.base, ctx.write_raw, ctx.rev_id)

      assert resp.status == 200,
             "legitimate writer over-denied on scoped restore — status #{resp.status}"

      assert Jason.decode!(resp.resp_body)["restored"] == true
    end

    test "non-member write token cannot restore in this workspace (scope respected)", ctx do
      resp = scoped_restore(ctx.base, ctx.nonmember_raw, ctx.rev_id)

      assert resp.status == 403,
             "a non-member write token restored into a workspace it isn't in — status #{resp.status}"
    end
  end

  # ── Legacy document write surface (same route-authz finding) ──────────────
  describe "legacy document write-gate (/api/documents/:type)" do
    setup do
      Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])
      Auth.create_token("barkpark-readonly-token", "ro", "test", ["read"])

      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        "production"
      )

      :ok
    end

    defp legacy_create(conn, raw, id) do
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("content-type", "application/json")
      |> post("/api/documents/post", Jason.encode!(%{id: id, title: "L"}))
    end

    test "read-only token cannot create a document via legacy surface (403)", %{conn: conn} do
      resp = legacy_create(conn, "barkpark-readonly-token", "legacy-ro-1")

      assert resp.status == 403,
             "read-only token created a document via legacy /api/documents — status #{resp.status}"

      assert Jason.decode!(resp.resp_body)["error"]["code"] == "forbidden"
    end

    test "write-capable token still creates via legacy surface (positive control)", %{conn: conn} do
      resp = legacy_create(conn, "barkpark-dev-token", "legacy-rw-1")

      assert resp.status == 201,
             "legitimate writer over-denied on legacy create — status #{resp.status}"
    end

    test "read-only token cannot delete a document via legacy surface (403)", %{conn: conn} do
      # Seed a doc first with the write token.
      assert legacy_create(conn, "barkpark-dev-token", "legacy-del-1").status == 201

      resp =
        conn
        |> put_req_header("authorization", "Bearer barkpark-readonly-token")
        |> delete("/api/documents/post/legacy-del-1")

      assert resp.status == 403,
             "read-only token deleted a document via legacy /api/documents — status #{resp.status}"
    end
  end
end
