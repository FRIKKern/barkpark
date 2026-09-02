defmodule Barkpark.Plugins.Sheets.Web.ExportScopeTest do
  @moduledoc """
  The `auth: :ingest` sheets doors must read and write ONE tenant
  (task-ef3eb91bf7f87d4c).

  Before this fix the `:ingest` pipeline was `[:accepts json,
  RequireIngestToken]` and mounted NO workspace producer, so
  `conn.assigns[:current_workspace]` was always nil on
  `/v1/plugins/sheets/*`. `ExportController.fetch_sheet/2` then called
  `Content.get_document/3` with no opts at all, `Content.Scope.
  scope_to_workspace_or_global/3` took its permissive nil arm, and ANY
  ingest-token holder exported ANY tenant's sheet by slug — while a same-slug
  collision across two tenants raised `Ecto.MultipleResultsError` (a 500)
  inside `Repo.one`.

  The write door had the mirror-image defect: `ImportController.save/4` wrote
  with no scope opts, so `Content.WriteScope.resolve_write_scope/1` stamped the
  seeded Default Workspace no matter which token was presented.

  The tenant rule this file pins:

    * an ADMIN api-token authorizes its OWN workspace (`api_tokens.workspace_id`
      → `DeriveWorkspaceFromToken`);
    * the shared INGEST SECRET (`Barkpark.Secrets.ingest_token/0`, the `:global`
      tier — instance-wide, no workspace binding) authorizes the seeded Default
      Workspace via `AssignDefaultScope`, which is exactly the workspace
      `WriteScope` already stamped, so sheets imported before this change stay
      exportable.

  NON-VACUITY is deliberate throughout: every isolation assertion is paired
  with a positive one on the SAME request, so an export that started returning
  nothing for everyone would fail this file rather than pass it.

  `async: false` — sheet sessions are globally registered processes and the
  fixtures touch the seeded Default workspace.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "sheets_export_scope_test"
  @shared_secret "barkpark-test-ingest-token"

  @a_secret "TENANT-A-CONFIDENTIAL"
  @b_own "TENANT-B-OWN-CELL"
  @default_own "DEFAULT-TENANT-CELL"

  setup do
    stop_all_sessions()
    on_exit(&stop_all_sessions/0)

    default_ws = ensure_default!()

    ws_a = create_workspace!("sheets-scope-a")
    ws_b = create_workspace!("sheets-scope-b")

    raw_b = "sheets-scope-admin-b-#{System.unique_integer([:positive])}"

    {:ok, _token_b} =
      Auth.create_token(
        raw_b,
        "sheets scope ws-b admin",
        @dataset,
        ["read", "write", "admin"],
        ws_b.id
      )

    %{default_ws: default_ws, ws_a: ws_a, ws_b: ws_b, raw_b: raw_b}
  end

  # ── 1. FAIL-FIRST: the colliding slug ───────────────────────────────────────

  describe "a same-slug collision across two tenants" do
    test "a ws-B admin token exports B's cells, never A's, and never 500s",
         %{conn: conn, ws_a: ws_a, ws_b: ws_b, raw_b: raw_b} do
      slug = unique_slug("collide")

      create_sheet!(ws_a, slug, @a_secret)
      create_sheet!(ws_b, slug, @b_own)

      resp =
        conn
        |> bearer(raw_b)
        |> get(export_csv(slug))

      # Not a 500: the unscoped read raised Ecto.MultipleResultsError here.
      assert resp.status == 200,
             "the colliding slug must not blow up the export door (got #{resp.status})"

      body = resp.resp_body

      # Non-vacuous: B must actually see its OWN sheet...
      assert body =~ @b_own,
             "the ws-B token should export ws-B's own sheet"

      # ...and never the other tenant's.
      refute body =~ @a_secret,
             "the sheets export door leaked workspace A's cells to a workspace-B token"
    end

    test "the shared-secret arm exports Default's sheet, never A's",
         %{conn: conn, default_ws: default_ws, ws_a: ws_a} do
      slug = unique_slug("collide-default")

      create_sheet!(ws_a, slug, @a_secret)
      create_sheet!(default_ws, slug, @default_own)

      resp =
        conn
        |> bearer(@shared_secret)
        |> get(export_csv(slug))

      assert resp.status == 200
      assert resp.resp_body =~ @default_own
      refute resp.resp_body =~ @a_secret
    end
  end

  # ── 2. A foreign slug is simply not there ───────────────────────────────────

  describe "a slug that exists only in another tenant" do
    test "404s for a ws-B admin token", %{conn: conn, ws_a: ws_a, ws_b: ws_b, raw_b: raw_b} do
      foreign = unique_slug("a-only")
      own = unique_slug("b-only")

      create_sheet!(ws_a, foreign, @a_secret)
      create_sheet!(ws_b, own, @b_own)

      body =
        conn
        |> bearer(raw_b)
        |> get(export_csv(foreign))
        |> json_response(404)

      assert body["error"]["code"] == "not_found"

      # Non-vacuity on the SAME token: it is not that this token can read
      # nothing — its own sheet still exports.
      assert conn
             |> bearer(raw_b)
             |> get(export_csv(own))
             |> Map.get(:resp_body) =~ @b_own
    end

    test "404s for the shared secret", %{conn: conn, ws_a: ws_a} do
      foreign = unique_slug("a-only-shared")
      create_sheet!(ws_a, foreign, @a_secret)

      body =
        conn
        |> bearer(@shared_secret)
        |> get(export_csv(foreign))
        |> json_response(404)

      assert body["error"]["code"] == "not_found"
    end
  end

  # ── 3. NON-VACUITY: import → export round-trips on ONE tenant ───────────────

  describe "import and export agree on one tenant" do
    @tag :tmp_dir
    test "the shared secret exports what the shared secret imported",
         %{conn: conn, tmp_dir: tmp_dir} do
      slug = unique_slug("shared-roundtrip")
      upload = csv_upload!(tmp_dir, "#{slug}.csv", "Item,Cost\r\nSHARED-IMPORTED-CELL,42\r\n")

      assert %{"ok" => true} =
               conn
               |> bearer(@shared_secret)
               |> post("/v1/plugins/sheets/import", %{
                 "file" => upload,
                 "slug" => slug,
                 "dataset" => @dataset
               })
               |> json_response(200)

      body =
        conn
        |> bearer(@shared_secret)
        |> get(export_csv(slug))
        |> Map.get(:resp_body)

      assert body =~ "SHARED-IMPORTED-CELL",
             "a sheet imported with the shared secret must export with it"
    end

    @tag :tmp_dir
    test "a ws-B admin token exports what it imported, and Default cannot see it",
         %{conn: conn, tmp_dir: tmp_dir, raw_b: raw_b, ws_b: ws_b} do
      slug = unique_slug("b-roundtrip")
      upload = csv_upload!(tmp_dir, "#{slug}.csv", "Item,Cost\r\nB-IMPORTED-CELL,7\r\n")

      assert %{"ok" => true} =
               conn
               |> bearer(raw_b)
               |> post("/v1/plugins/sheets/import", %{
                 "file" => upload,
                 "slug" => slug,
                 "dataset" => @dataset
               })
               |> json_response(200)

      # The write landed in B, not the seeded Default.
      assert {:ok, doc} =
               Content.get_document(Content.draft_id(slug), "sheet", @dataset,
                 workspace_id: ws_b.id
               )

      assert doc.workspace_id == ws_b.id,
             "the import stamped #{inspect(doc.workspace_id)} instead of the token's workspace"

      # And the read door agrees with the write door.
      assert conn
             |> bearer(raw_b)
             |> get(export_csv(slug))
             |> Map.get(:resp_body) =~ "B-IMPORTED-CELL"

      # The shared secret (Default) must not reach into B.
      assert conn
             |> bearer(@shared_secret)
             |> get(export_csv(slug))
             |> json_response(404)
    end
  end

  # ── 4. The ops door shares the boundary ─────────────────────────────────────

  describe "the ops door" do
    test "a ws-B token cannot drive ops against a ws-A sheet, but can against its own",
         %{conn: conn, ws_a: ws_a, ws_b: ws_b, raw_b: raw_b} do
      foreign = unique_slug("ops-a-only")
      own = unique_slug("ops-b-own")

      create_sheet!(ws_a, foreign, @a_secret)
      create_sheet!(ws_b, own, @b_own)

      ops = %{"ops" => [%{"op" => "set_cell", "tab" => 0, "ref" => "B1", "raw" => "written"}]}

      assert %{"error" => %{"code" => "not_found"}} =
               conn
               |> bearer(raw_b)
               |> put_req_header("content-type", "application/json")
               |> post(ops_url(foreign), ops)
               |> json_response(404)

      # Non-vacuity: the same token, the same body, its OWN sheet — 200.
      assert %{"ok" => true} =
               conn
               |> bearer(raw_b)
               |> put_req_header("content-type", "application/json")
               |> post(ops_url(own), ops)
               |> json_response(200)
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp export_csv(slug), do: "/v1/plugins/sheets/#{slug}/export.csv?dataset=#{@dataset}"

  defp ops_url(slug), do: "/v1/plugins/sheets/#{slug}/ops?dataset=#{@dataset}"

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp csv_upload!(tmp_dir, filename, content) do
    path = Path.join(tmp_dir, filename)
    File.write!(path, content)
    %Plug.Upload{path: path, filename: filename, content_type: "text/csv"}
  end

  # A sheet STAMPED into `workspace`. The dataset string is deliberately the
  # same across workspaces, so isolation must come from workspace_id and not
  # from the dataset leaf.
  defp create_sheet!(workspace, slug, marker) do
    {:ok, doc} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => slug,
          "title" => slug,
          "content" => %{
            "tabs" => [%{"name" => "Sheet1", "cells" => %{"A1" => %{"v" => marker}}}]
          }
        },
        @dataset,
        workspace_id: workspace.id
      )

    assert doc.workspace_id == workspace.id,
           "fixture did not stamp the workspace — the test would be vacuous"

    doc
  end

  defp create_workspace!(prefix) do
    slug = unique_slug(prefix)
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug, name: slug})
    {:ok, _proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
    ws
  end

  defp ensure_default! do
    ws =
      case Tenancy.get_default_workspace() do
        nil ->
          {:ok, ws} = Tenancy.create_workspace(%{slug: "default", name: "Default"})
          ws

        ws ->
          ws
      end

    case Tenancy.get_default_project() do
      nil -> {:ok, _proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
      _proj -> :ok
    end

    ws
  end

  defp stop_all_sessions do
    for {_, pid, _, _} <-
          DynamicSupervisor.which_children(Barkpark.Plugins.Sheets.SessionSupervisor),
        is_pid(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end
end
