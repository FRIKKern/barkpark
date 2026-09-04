defmodule BarkparkWeb.Integration.V1MediaProcessingTest do
  use BarkparkWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Auth
  alias Barkpark.Media
  alias Barkpark.Plugins.Media.Assets

  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  # Minimal SVG — a legit `image/svg+xml` blob that has NO libvips loader on the
  # CI/ARM build. Must be skipped by the rendition gate, not sent to Image.open.
  @svg_bytes ~s(<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"></svg>)

  # Stub backend reproducing the libvips/ARM "Failed to find load" failure for
  # EVERY preset, so a PNG's whole rendition set fails deterministically.
  defmodule FailBackend do
    @behaviour Barkpark.Media.ImageBackend
    @impl true
    def render(_src, _dest, _spec, _watermark),
      do: {:error, %{__struct__: Image.Error, message: "Failed to find load"}}

    @impl true
    def available?, do: true
  end

  defp swap_backend(module) do
    original = Application.get_env(:barkpark, :image_backend)
    Application.put_env(:barkpark, :image_backend, module)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:barkpark, :image_backend)
        val -> Application.put_env(:barkpark, :image_backend, val)
      end
    end)
  end

  defp svg_upload do
    tmp_path = Path.join(System.tmp_dir!(), "proc-#{:rand.uniform(1_000_000)}.svg")
    File.write!(tmp_path, @svg_bytes)
    %Plug.Upload{path: tmp_path, filename: "vec.svg", content_type: "image/svg+xml"}
  end

  setup do
    Auth.create_token(
      "barkpark-dev-token",
      "dev",
      "v1-media-processing",
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

  defp callback(conn),
    do: put_req_header(conn, "authorization", "Bearer test-media-processing-callback-token")

  defp png_upload do
    png_bin = Base.decode64!(@png_b64)
    tmp_path = Path.join(System.tmp_dir!(), "proc-#{:rand.uniform(1_000_000)}.png")
    File.write!(tmp_path, png_bin)

    %Plug.Upload{path: tmp_path, filename: "pixel.png", content_type: "image/png"}
  end

  describe "POST /v1/media/:dataset/processing/:id/callback" do
    test "external processor marks asset ready", %{conn: conn} do
      created =
        conn
        |> authed()
        |> post(~p"/v1/media/production/upload", %{"file" => png_upload()})
        |> json_response(201)

      id = created["result"]["id"]

      resp =
        scoped_conn()
        |> callback()
        |> post(~p"/v1/media/production/processing/#{id}/callback", %{
          "status" => "ready",
          "provider" => "transcoder",
          "jobId" => "job-123"
        })
        |> json_response(200)

      assert resp["result"]["asset"]["bp_processing_status"] == "ready"

      assert get_in(resp, ["result", "asset", "bp_external_processing", "provider"]) ==
               "transcoder"

      assert get_in(resp, ["result", "asset", "bp_cdn_status"]) in ["skipped", "published"]

      File.rm(Path.join(Media.upload_dir(), created["result"]["path"]))
      Media.Renditions.delete_for_file(id)
      Assets.delete_for_blob(id, "production")
    end

    test "SVG upload makes no rendition and logs no 'Failed to find load'", %{conn: conn} do
      # Real Vix stays selected here — the gate must skip SVG BEFORE reaching it.
      log =
        capture_log(fn ->
          created =
            conn
            |> authed()
            |> post(~p"/v1/media/production/upload", %{"file" => svg_upload()})
            |> json_response(201)

          id = created["result"]["id"]
          doc = Assets.find_by_media_file_id(id, "production")

          # Non-raster image/* is skipped cleanly → asset is ready on the
          # original, with no preset ever generated on disk.
          assert doc.content["bp_processing_status"] == "ready"

          rendition_dir = Path.join([Media.upload_dir(), "_renditions", id])
          refute File.exists?(rendition_dir)

          File.rm(Path.join(Media.upload_dir(), created["result"]["path"]))
          Media.Renditions.delete_for_file(id)
          Assets.delete_for_blob(id, "production")
        end)

      refute log =~ "Failed to find load"
    end

    test "raster upload whose entire rendition set fails is marked failed, not ready",
         %{conn: conn} do
      swap_backend(FailBackend)

      created =
        conn
        |> authed()
        |> post(~p"/v1/media/production/upload", %{"file" => png_upload()})
        |> json_response(201)

      id = created["result"]["id"]
      doc = Assets.find_by_media_file_id(id, "production")

      # A bare "ready" here would lie — serve_rendition would 404 on every
      # preset. The whole-set failure must surface as the "failed" state.
      assert doc.content["bp_processing_status"] == "failed"

      File.rm(Path.join(Media.upload_dir(), created["result"]["path"]))
      Media.Renditions.delete_for_file(id)
      Assets.delete_for_blob(id, "production")
    end

    test "rejects missing callback token", %{conn: conn} do
      created =
        conn
        |> authed()
        |> post(~p"/v1/media/production/upload", %{"file" => png_upload()})
        |> json_response(201)

      id = created["result"]["id"]

      resp =
        scoped_conn()
        |> post(~p"/v1/media/production/processing/#{id}/callback", %{"status" => "ready"})

      assert resp.status == 401

      File.rm(Path.join(Media.upload_dir(), created["result"]["path"]))
      Media.Renditions.delete_for_file(id)
      Assets.delete_for_blob(id, "production")
    end
  end
end
