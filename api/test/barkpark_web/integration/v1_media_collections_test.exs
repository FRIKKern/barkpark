defmodule BarkparkWeb.Integration.V1MediaCollectionsTest do
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Media
  alias Barkpark.Plugins.Media.Assets

  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  setup do
    Auth.create_token(
      "barkpark-dev-token",
      "dev",
      "v1-media-collections",
      ["read", "write", "admin"]
    )

    drain_task_supervisor(30_000)
    :ok
  end

  defp drain_task_supervisor(deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_drain(deadline)
  end

  defp do_drain(deadline) do
    case Task.Supervisor.children(Barkpark.TaskSupervisor) do
      [] ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: :timeout,
          else:
            (
              Process.sleep(50)
              do_drain(deadline)
            )
    end
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer barkpark-dev-token")

  defp png_upload do
    png_bin = Base.decode64!(@png_b64)
    tmp_path = Path.join(System.tmp_dir!(), "col-#{:rand.uniform(1_000_000)}.png")
    File.write!(tmp_path, png_bin)

    %Plug.Upload{path: tmp_path, filename: "pixel.png", content_type: "image/png"}
  end

  defp create_collection!(attrs \\ %{}) when is_map(attrs) do
    id =
      Map.get(attrs, "id") || Map.get(attrs, :id) || "col-#{System.unique_integer([:positive])}"

    title = Map.get(attrs, "title") || Map.get(attrs, :title) || "Campaign"
    content = Map.get(attrs, "content") || Map.get(attrs, :content) || %{}

    {:ok, doc} =
      Content.upsert_document(
        "mediaCollection",
        %{
          "doc_id" => id,
          "title" => title,
          "content" => Map.merge(%{"kind" => "folder", "slug" => id}, content)
        },
        "production",
        source: :api
      )

    doc
  end

  defp upload_asset(conn) do
    conn
    |> authed()
    |> post(~p"/v1/media/production/upload", %{"file" => png_upload()})
    |> json_response(201)
  end

  defp cleanup_upload(%{"result" => %{"id" => id, "path" => path}}) do
    File.rm(Path.join(Media.upload_dir(), path))
    Media.Renditions.delete_for_file(id)
    Assets.delete_for_blob(id, "production")
  end

  defp cleanup_collection(%Document{doc_id: id}) do
    Content.delete_document(id, "mediaCollection", "production")
  end

  describe "folder collections" do
    test "membership and assets listing", %{conn: conn} do
      collection = create_collection!(%{title: "Hero shots"})
      created = upload_asset(conn)
      file_id = created["result"]["id"]

      conn
      |> authed()
      |> post(~p"/v1/media/production/collections/#{collection.doc_id}/members", %{
        "assetId" => file_id
      })
      |> json_response(200)

      assets =
        conn
        |> get(~p"/v1/media/production/collections/#{collection.doc_id}/assets")
        |> json_response(200)

      assert assets["result"]["total"] == 1
      assert hd(assets["result"]["hits"])["id"] == file_id

      cleanup_upload(created)
      cleanup_collection(collection)
    end
  end

  describe "virtual collections" do
    test "virtual filter resolves matching assets", %{conn: conn} do
      collection =
        create_collection!(%{
          title: "All images",
          content: %{
            "kind" => "virtual",
            "virtualFilter" => %{"kind" => "image"}
          }
        })

      created = upload_asset(conn)

      assets =
        conn
        |> get(~p"/v1/media/production/collections/#{collection.doc_id}/assets")
        |> json_response(200)

      assert assets["result"]["total"] >= 1
      assert Enum.any?(assets["result"]["hits"], &(&1["id"] == created["result"]["id"]))

      cleanup_upload(created)
      cleanup_collection(collection)
    end
  end

  describe "share links" do
    test "public share token lists collection assets", %{conn: conn} do
      collection = create_collection!(%{title: "Shared set"})
      created = upload_asset(conn)

      conn
      |> authed()
      |> post(~p"/v1/media/production/collections/#{collection.doc_id}/members", %{
        "assetId" => created["result"]["id"]
      })
      |> json_response(200)

      share =
        conn
        |> authed()
        |> post(~p"/v1/media/production/collections/#{collection.doc_id}/share")
        |> json_response(200)

      token = share["result"]["token"]

      public =
        scoped_conn()
        |> get("/v1/media/production/share/#{token}")
        |> json_response(200)

      assert public["result"]["collection"]["title"] == "Shared set"
      assert public["result"]["total"] == 1

      conn
      |> authed()
      |> delete(~p"/v1/media/production/collections/#{collection.doc_id}/share")
      |> json_response(200)

      expired =
        scoped_conn()
        |> get("/v1/media/production/share/#{token}")

      assert expired.status == 410

      cleanup_upload(created)
      cleanup_collection(collection)
    end
  end

  # ── Tenancy: workspace-scope isolation (w1.5-E, Goal barkpark-qprk) ──────
  #
  # The flat `/v1/media/:dataset/collections` surface assigns the seeded
  # Default workspace via `AssignDefaultScope` and threads `scope_opts(conn)`
  # into `Collections.list/get`. A Default-scoped `index` must therefore return
  # ONLY Default-scope collections — a collection stamped to a different
  # workspace must not leak across the boundary.
  describe "tenancy scope" do
    test "Default-scoped collection list never returns workspace-A's collection", %{conn: conn} do
      {default_ws, default_proj} = ensure_default_scope!()

      # A collection in a DIFFERENT (non-Default) workspace.
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)

      other_id = "col-ten-otherws-#{System.unique_integer([:positive])}"

      {:ok, _other} =
        Content.upsert_document(
          "mediaCollection",
          %{"doc_id" => other_id, "title" => "OtherWS", "content" => %{"kind" => "folder"}},
          "production",
          source: :api,
          workspace_id: ws_a.id,
          project_id: proj_a.id
        )

      # A collection explicitly in Default — the row the list SHOULD surface.
      mine_id = "col-ten-default-#{System.unique_integer([:positive])}"

      {:ok, _mine} =
        Content.upsert_document(
          "mediaCollection",
          %{"doc_id" => mine_id, "title" => "DefaultWS", "content" => %{"kind" => "folder"}},
          "production",
          source: :api,
          workspace_id: default_ws.id,
          project_id: default_proj.id
        )

      body =
        conn
        |> authed()
        |> get(~p"/v1/media/production/collections")
        |> json_response(200)

      ids = Enum.map(body["result"]["collections"], & &1["id"])

      assert "drafts.#{mine_id}" in ids or mine_id in ids,
             "expected the Default-scope collection to be visible, got #{inspect(ids)}"

      refute "drafts.#{other_id}" in ids or other_id in ids,
             "CROSS-WORKSPACE LEAK: workspace-A's collection leaked into the Default-scoped list"
    end
  end

  # ── Tenancy: cross-workspace membership isolation (Goal barkpark-qprk) ───
  #
  # `add_member`/`remove_member` resolve the asset via `Media.get_file/2`, which
  # MUST carry the request scope. `ensure_dataset/2` only compares the dataset
  # STRING (shared across tenants), so without scope a workspace-B writer could
  # pass a workspace-A blob id: it would resolve cross-tenant and membership
  # would be written under the FILE's own (workspace-A) scope — mutating another
  # tenant's asset doc. Scoping the read makes the foreign id resolve to
  # not_found (404) instead of leaking.
  describe "tenancy scope — membership" do
    setup do
      {default_ws, _default_proj} = ensure_default_scope!()

      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)

      # A blob owned by workspace A (NOT the request's Default scope).
      {:ok, foreign_file} =
        Media.upload(png_upload(), "production", workspace_id: ws_a.id, project_id: proj_a.id)

      on_exit(fn ->
        File.rm(Path.join(Media.upload_dir(), foreign_file.path))
        Media.Renditions.delete_for_file(foreign_file.id)
        Assets.delete_for_blob(foreign_file.id, "production")
      end)

      %{default_ws: default_ws, foreign_file: foreign_file}
    end

    test "Default-scoped writer cannot add a workspace-A asset (not_found, no leak)",
         %{conn: conn, foreign_file: foreign_file} do
      collection = create_collection!(%{title: "Default folder"})

      resp =
        conn
        |> authed()
        |> post(~p"/v1/media/production/collections/#{collection.doc_id}/members", %{
          "assetId" => foreign_file.id
        })

      assert resp.status == 404

      # The foreign asset must still have zero collection membership — the
      # rejected call must not have mutated workspace-A's asset doc.
      assets =
        conn
        |> get(~p"/v1/media/production/collections/#{collection.doc_id}/assets")
        |> json_response(200)

      assert assets["result"]["total"] == 0

      cleanup_collection(collection)
    end

    test "Default-scoped writer cannot remove a workspace-A asset (not_found)",
         %{conn: conn, foreign_file: foreign_file} do
      collection = create_collection!(%{title: "Default folder"})

      resp =
        conn
        |> authed()
        |> delete(
          ~p"/v1/media/production/collections/#{collection.doc_id}/members/#{foreign_file.id}"
        )

      assert resp.status == 404

      cleanup_collection(collection)
    end
  end

  describe "relations" do
    test "outbound and inbound relation graph", %{conn: conn} do
      first = upload_asset(conn)
      second = upload_asset(conn)

      first_id = first["result"]["id"]
      second_doc_id = second["result"]["assetDocId"]

      conn
      |> authed()
      |> patch(~p"/v1/media/production/#{first_id}", %{
        "relatedAssets" => [%{"relation" => "variant", "target" => second_doc_id}]
      })
      |> json_response(200)

      outbound =
        conn
        |> get(~p"/v1/media/production/#{first_id}/relations")
        |> json_response(200)

      assert length(outbound["result"]["outbound"]) == 1
      assert hd(outbound["result"]["outbound"])["relation"] == "variant"

      inbound =
        conn
        |> get(~p"/v1/media/production/#{second["result"]["id"]}/relations")
        |> json_response(200)

      assert length(inbound["result"]["inbound"]) == 1
      assert hd(inbound["result"]["inbound"])["relation"] == "variant"

      cleanup_upload(first)
      cleanup_upload(second)
    end
  end
end
