defmodule BarkparkWeb.Integration.V1MediaProcessingTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Media
  alias Barkpark.Plugins.Media.Assets

  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

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
        build_conn()
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

    test "rejects missing callback token", %{conn: conn} do
      created =
        conn
        |> authed()
        |> post(~p"/v1/media/production/upload", %{"file" => png_upload()})
        |> json_response(201)

      id = created["result"]["id"]

      resp =
        build_conn()
        |> post(~p"/v1/media/production/processing/#{id}/callback", %{"status" => "ready"})

      assert resp.status == 401

      File.rm(Path.join(Media.upload_dir(), created["result"]["path"]))
      Media.Renditions.delete_for_file(id)
      Assets.delete_for_blob(id, "production")
    end
  end
end
