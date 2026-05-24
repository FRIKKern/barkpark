defmodule BarkparkWeb.Integration.V1MediaTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Media
  alias Barkpark.Plugins.Media.Assets

  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  setup do
    Auth.create_token(
      "barkpark-dev-token",
      "dev",
      "v1-media-test",
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

  defp read_only(conn) do
    {:ok, _} =
      Auth.create_token("read-only-media", "dev", "v1-media-read", ["read"])

    put_req_header(conn, "authorization", "Bearer read-only-media")
  end

  defp png_upload do
    png_bin = Base.decode64!(@png_b64)
    tmp_path = Path.join(System.tmp_dir!(), "v1-media-#{:rand.uniform(1_000_000)}.png")
    File.write!(tmp_path, png_bin)

    %Plug.Upload{
      path: tmp_path,
      filename: "pixel.png",
      content_type: "image/png"
    }
  end

  defp rm_uploaded(%{"result" => %{"id" => id, "url" => "/media/files/" <> relative}}) do
    File.rm(Path.join(Media.upload_dir(), relative))
    Barkpark.Media.Renditions.delete_for_file(id)
    Assets.delete_for_blob(id, "production")
  end

  defp rm_uploaded(%{"id" => id, "url" => "/media/files/" <> relative}) do
    File.rm(Path.join(Media.upload_dir(), relative))
    Barkpark.Media.Renditions.delete_for_file(id)
    Assets.delete_for_blob(id, "production")
  end

  describe "GET /v1/media/:dataset" do
    test "returns paginated unified assets envelope", %{conn: conn} do
      created =
        conn
        |> authed()
        |> post(~p"/v1/media/production/upload", %{"file" => png_upload()})
        |> json_response(201)

      resp =
        conn
        |> get(~p"/v1/media/production?limit=10&offset=0")
        |> json_response(200)

      assert resp["result"]["count"] >= 1
      assert is_list(resp["result"]["assets"])
      assert resp["result"]["limit"] == 10
      asset = Enum.find(resp["result"]["assets"], &(&1["id"] == created["result"]["id"]))
      assert asset["assetDocId"]
      assert asset["asset"]["_type"] == "mediaAsset"
      assert asset["url"] =~ "/media/files/"

      rm_uploaded(created["result"])
    end
  end

  describe "POST /v1/media/:dataset/upload" do
    test "creates blob + linked asset document", %{conn: conn} do
      resp =
        conn
        |> authed()
        |> post(~p"/v1/media/production/upload", %{"file" => png_upload()})

      assert resp.status == 201
      body = json_response(resp, 201)
      assert body["result"]["asset"]["fileInfo"]["mimeType"] == "image/png"
      rm_uploaded(body["result"])
    end

    test "read-only token → 403", %{conn: conn} do
      resp =
        conn
        |> read_only()
        |> post(~p"/v1/media/production/upload", %{"file" => png_upload()})

      assert resp.status == 403
    end
  end

  describe "PATCH /v1/media/:dataset/:id" do
    test "patches mediaAsset metadata", %{conn: conn} do
      created =
        conn
        |> authed()
        |> post(~p"/v1/media/production/upload", %{"file" => png_upload()})
        |> json_response(201)

      id = created["result"]["id"]

      patched =
        conn
        |> authed()
        |> patch(~p"/v1/media/production/#{id}", %{
          "title" => "Hero photo",
          "tags" => ["hero", "homepage"]
        })
        |> json_response(200)

      assert patched["result"]["asset"]["title"] == "Hero photo"
      assert patched["result"]["asset"]["tags"] == ["hero", "homepage"]

      rm_uploaded(created["result"])
    end
  end

  describe "DELETE /v1/media/:dataset/:id" do
    test "deletes blob and returns envelope", %{conn: conn} do
      created =
        conn
        |> authed()
        |> post(~p"/v1/media/production/upload", %{"file" => png_upload()})
        |> json_response(201)

      id = created["result"]["id"]
      [_, relative] = String.split(created["result"]["url"], "/media/files/", parts: 2)

      resp =
        conn
        |> authed()
        |> delete(~p"/v1/media/production/#{id}")

      assert resp.status == 200
      assert json_response(resp, 200)["result"]["deleted"] == id
      refute File.exists?(Path.join(Media.upload_dir(), relative))
    end
  end
end
