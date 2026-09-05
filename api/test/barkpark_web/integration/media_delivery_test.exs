defmodule BarkparkWeb.Integration.MediaDeliveryTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Plugins.Media.Assets
  alias Barkpark.Repo

  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  # Visibility-aware policy for PUBLIC local media (charter http-edge-truth
  # D12). Uploads default to bp_visibility "public", so every asset served in
  # this file lands on the public arm; the non-public arms are pinned at the
  # unit level in test/barkpark/media/delivery/urls_test.exs.
  @public_policy "public, max-age=86400, must-revalidate"

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
        scoped_conn()
        |> get(url)

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == [@public_policy]
      assert get_resp_header(conn, "etag") != []

      etag = List.first(get_resp_header(conn, "etag"))

      conn =
        scoped_conn()
        |> put_req_header("if-none-match", etag)
        |> get(url)

      assert conn.status == 304

      cleanup(created)
    end
  end

  describe "GET /media/renditions/:id/:preset" do
    # Excluded by default (test_helper.exs) so a machine without libvips stays
    # green via a real ExUnit skip instead of an in-test `assert true`. Opt in
    # with `mix test --include requires_vips` — on a box that lacks `vips`,
    # this then fails for real instead of passing vacuously.
    @tag :requires_vips
    test "serves generated thumb rendition", %{conn: conn} do
      created =
        conn
        |> authed()
        |> post(~p"/v1/media/production/upload", %{"file" => png_upload()})
        |> json_response(201)

      thumb_url = created["result"]["thumbnailUrl"]

      conn =
        scoped_conn()
        |> get(thumb_url)

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == [@public_policy]

      cleanup(created)
    end
  end

  # ── stored-XSS hardening on the serve edge ────────────────────────────────
  #
  # A blob whose on-disk path ends in a browser-executable extension
  # (svg/html/xml) must never be served with its honest, executable
  # content-type inline: `MIME.from_path` would resolve `image/svg+xml` /
  # `text/html` and the browser would run embedded <script> on the API/Studio
  # origin (default asset visibility is public). We assert it is instead pinned
  # to a non-executable type + nosniff + attachment.

  # Write a blob straight to the media store and insert its row, bypassing the
  # upload pipeline so we can control the on-disk extension precisely.
  defp put_blob!(rel_path, bytes) do
    full = Path.join(Media.upload_dir(), rel_path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, bytes)

    # Stamp the Default workspace/project so the flat serve pipeline
    # (AssignDefaultScope → Default workspace) resolves the row — a real upload
    # is stamped the same way. scope_to_workspace_or_global with a workspace_id
    # is fail-closed (workspace-only), so a NULL-workspace row would 404.
    proj = Barkpark.Tenancy.get_default_project()

    {:ok, file} =
      %MediaFile{}
      |> MediaFile.changeset(%{
        filename: Path.basename(rel_path),
        original_name: Path.basename(rel_path),
        path: rel_path,
        mime_type: "application/octet-stream",
        size: byte_size(bytes),
        dataset: "production",
        workspace_id: proj && proj.workspace_id,
        project_id: proj && proj.id
      })
      |> Repo.insert()

    {file, full}
  end

  describe "GET /media/files/* — dangerous-type neutralization" do
    test "a stored .svg is served nosniff + attachment + non-executable type", %{conn: _conn} do
      suffix = System.unique_integer([:positive])
      svg = ~s|<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>|
      {_file, full} = put_blob!("test/xss/evil-#{suffix}.svg", svg)

      conn = get(scoped_conn(), "/media/files/test/xss/evil-#{suffix}.svg")

      assert conn.status == 200
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "content-disposition") == ["attachment"]

      content_type = List.first(get_resp_header(conn, "content-type"))
      refute content_type =~ "image/svg+xml"
      assert content_type =~ "application/octet-stream"

      File.rm(full)
    end

    test "a stored .html is served nosniff + attachment + non-executable type", %{conn: _conn} do
      suffix = System.unique_integer([:positive])
      {_file, full} = put_blob!("test/xss/evil-#{suffix}.html", "<script>alert(1)</script>")

      conn = get(scoped_conn(), "/media/files/test/xss/evil-#{suffix}.html")

      assert conn.status == 200
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "content-disposition") == ["attachment"]
      refute List.first(get_resp_header(conn, "content-type")) =~ "text/html"

      File.rm(full)
    end

    test "a normal image still serves inline with its honest type + nosniff", %{conn: conn} do
      created =
        conn
        |> authed()
        |> post(~p"/v1/media/production/upload", %{"file" => png_upload()})
        |> json_response(201)

      url = created["result"]["originalUrl"]
      served = get(scoped_conn(), url)

      assert served.status == 200
      assert get_resp_header(served, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(served, "content-disposition") == ["inline"]
      assert List.first(get_resp_header(served, "content-type")) =~ "image/png"

      cleanup(created)
    end
  end
end
