defmodule BarkparkWeb.Integration.MediaMetaVisibilityTest do
  @moduledoc """
  Field-visibility gate on GET /media/:id/meta (felix W14 leak).

  `MediaController.show/2` must run the SAME `Access.allowed?/4` gate as its
  siblings `serve/2`/`serve_rendition/2`: an anonymous caller must NOT read a
  private asset's filename/path/size while being refused the bytes. RED-FIRST
  proof: before the gate, the anonymous meta request returned 200.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Media
  alias Barkpark.Plugins.Media.Assets

  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  setup do
    Auth.create_token(
      "meta-vis-dev-token",
      "dev",
      "media-meta-visibility",
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

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer meta-vis-dev-token")

  defp png_upload do
    png_bin = Base.decode64!(@png_b64)
    tmp_path = Path.join(System.tmp_dir!(), "meta-vis-#{:rand.uniform(1_000_000)}.png")
    File.write!(tmp_path, png_bin)

    %Plug.Upload{
      path: tmp_path,
      filename: "pixel.png",
      content_type: "image/png"
    }
  end

  defp upload_asset(conn) do
    conn
    |> authed()
    |> post(~p"/v1/media/production/upload", %{"file" => png_upload()})
    |> json_response(201)
  end

  defp make_private!(conn, id) do
    conn
    |> authed()
    |> patch(~p"/v1/media/production/#{id}", %{"bp_visibility" => "private"})
    |> json_response(200)
  end

  defp cleanup(%{"result" => %{"id" => id, "path" => path}}) do
    File.rm(Path.join(Media.upload_dir(), path))
    Media.Renditions.delete_for_file(id)
    Assets.delete_for_blob(id, "production")
  end

  describe "GET /media/:id/meta — field-visibility gate" do
    test "anonymous meta on a PRIVATE asset is refused (403), matching the bytes path",
         %{conn: conn} do
      created = upload_asset(conn)
      id = created["result"]["id"]

      make_private!(conn, id)

      # The bytes are already refused for this caller…
      assert scoped_conn() |> get(created["result"]["originalUrl"]) |> Map.get(:status) == 403

      # …and the metadata must be refused the same way — no filename/path/size peek.
      meta = get(scoped_conn(), "/media/#{id}/meta")
      assert meta.status == 403

      body = json_response(meta, 403)
      refute Map.has_key?(body, "filename")
      refute Map.has_key?(body, "path")
      refute Map.has_key?(body, "size")

      cleanup(created)
    end

    test "positive control: authorized meta on a PRIVATE asset is still 200", %{conn: conn} do
      created = upload_asset(conn)
      id = created["result"]["id"]

      make_private!(conn, id)

      body =
        scoped_conn()
        |> authed()
        |> get("/media/#{id}/meta")
        |> json_response(200)

      assert body["id"] == id
      assert is_binary(body["filename"])
      assert is_binary(body["path"])

      cleanup(created)
    end

    test "positive control: anonymous meta on a PUBLIC asset is still 200", %{conn: conn} do
      created = upload_asset(conn)
      id = created["result"]["id"]

      body =
        scoped_conn()
        |> get("/media/#{id}/meta")
        |> json_response(200)

      assert body["id"] == id

      cleanup(created)
    end
  end
end
