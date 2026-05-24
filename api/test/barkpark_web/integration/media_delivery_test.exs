defmodule BarkparkWeb.Integration.MediaDeliveryTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Media
  alias Barkpark.Plugins.Media.Assets

  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  setup do
    Auth.create_token(
      "barkpark-dev-token",
      "dev",
      "media-delivery-test",
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
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(50)
          do_drain(deadline)
        end
    end
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer barkpark-dev-token")

  defp png_upload do
    png_bin = Base.decode64!(@png_b64)
    tmp_path = Path.join(System.tmp_dir!(), "delivery-#{:rand.uniform(1_000_000)}.png")
    File.write!(tmp_path, png_bin)

    %Plug.Upload{
      path: tmp_path,
      filename: "pixel.png",
      content_type: "image/png"
    }
  end

  defp cleanup(%{"result" => %{"id" => id, "path" => path}}) do
    File.rm(Path.join(Media.upload_dir(), path))
    Media.Renditions.delete_for_file(id)
    Assets.delete_for_blob(id, "production")
  end

  describe "delivery URLs in v1 API" do
    test "upload returns WoodWing-style delivery URLs and dimensions", %{conn: conn} do
      created =
        conn
        |> authed()
        |> post(~p"/v1/media/production/upload", %{"file" => png_upload()})
        |> json_response(201)

      result = created["result"]
      assert result["originalUrl"] =~ "/media/files/"
      assert result["thumbnailUrl"] =~ "/media/renditions/"
      assert result["previewUrl"] =~ "/media/renditions/"
      assert result["renditions"]["thumb"] =~ "/media/renditions/"
      assert result["asset"]["fileInfo"]["width"] == "1"
      assert result["asset"]["fileInfo"]["height"] == "1"
      assert result["asset"]["bp_processing_status"] == "ready"

      cleanup(created)
    end
  end

  describe "GET /media/files/*" do
    test "serves originals with cache-control and etag", %{conn: conn} do
      created =
        conn
        |> authed()
        |> post(~p"/v1/media/production/upload", %{"file" => png_upload()})
        |> json_response(201)

      url = created["result"]["originalUrl"]

      conn =
        build_conn()
        |> get(url)

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
      assert get_resp_header(conn, "etag") != []

      etag = List.first(get_resp_header(conn, "etag"))

      conn =
        build_conn()
        |> put_req_header("if-none-match", etag)
        |> get(url)

      assert conn.status == 304

      cleanup(created)
    end
  end

  describe "GET /media/renditions/:id/:preset" do
    @tag :requires_vips
    test "serves generated thumb rendition", %{conn: conn} do
      unless vips_available?() do
        assert true
      else
        created =
          conn
          |> authed()
          |> post(~p"/v1/media/production/upload", %{"file" => png_upload()})
          |> json_response(201)

        thumb_url = created["result"]["thumbnailUrl"]

        conn =
          build_conn()
          |> get(thumb_url)

        assert conn.status == 200
        assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]

        cleanup(created)
      end
    end
  end

  defp vips_available?() do
    case System.find_executable("vips") do
      nil -> false
      _ -> true
    end
  end
end
