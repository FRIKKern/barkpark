defmodule BarkparkWeb.Integration.V1MediaCollectionsTest do
  use BarkparkWeb.ConnCase, async: false

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
      [] -> :ok
      _ -> if System.monotonic_time(:millisecond) >= deadline, do: :timeout, else: (Process.sleep(50); do_drain(deadline))
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
    id = Map.get(attrs, "id") || Map.get(attrs, :id) || "col-#{System.unique_integer([:positive])}"

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
        build_conn()
        |> get("/v1/media/production/share/#{token}")
        |> json_response(200)

      assert public["result"]["collection"]["title"] == "Shared set"
      assert public["result"]["total"] == 1

      conn
      |> authed()
      |> delete(~p"/v1/media/production/collections/#{collection.doc_id}/share")
      |> json_response(200)

      expired =
        build_conn()
        |> get("/v1/media/production/share/#{token}")

      assert expired.status == 410

      cleanup_upload(created)
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
