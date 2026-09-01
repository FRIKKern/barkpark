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

  # A real temp file wrapped as a Plug.Upload with a caller-chosen filename +
  # (possibly lying) content_type — the fix must ignore the content_type.
  defp upload(filename, content_type, content) do
    tmp = Path.join(System.tmp_dir!(), "v1-media-#{:rand.uniform(1_000_000)}-#{filename}")
    File.write!(tmp, content)
    %Plug.Upload{path: tmp, filename: filename, content_type: content_type}
  end

  defp put_media_cfg(cfg) do
    prev = Application.get_env(:barkpark, :media_uploads)
    Application.put_env(:barkpark, :media_uploads, cfg)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :media_uploads, prev),
        else: Application.delete_env(:barkpark, :media_uploads)
    end)
  end

  describe "SECURITY: server-derived MIME + config-gated allowlist (PART 1 + PART 2)" do
    test "PART 1: stored mime is server-derived — a lying content_type is ignored", %{conn: conn} do
      # A real PNG whose multipart header LIES that it is text/html. The persisted
      # mimeType must be image/png (derived from the .png name, the same value the
      # serve path returns), proving the client claim can no longer poison it.
      png_bin = Base.decode64!(@png_b64)
      liar = upload("pixel.png", "text/html", png_bin)

      body =
        conn
        |> authed()
        |> post(~p"/v1/media/production/upload", %{"file" => liar})
        |> json_response(201)

      assert body["result"]["asset"]["fileInfo"]["mimeType"] == "image/png"
      rm_uploaded(body["result"])
    end

    test "PART 2 OFF by default: an unusual extension still uploads (allow-all)", %{conn: conn} do
      # No :media_uploads allowlist configured (config.exs default = empty/allow-all)
      # → an octet-stream .bin uploads exactly as before, zero rejections.
      blob = upload("clip.bin", "application/octet-stream", "arbitrary-bytes")

      resp =
        conn
        |> authed()
        |> post(~p"/v1/media/production/upload", %{"file" => blob})

      assert resp.status == 201
      rm_uploaded(json_response(resp, 201)["result"])
    end

    test "PART 2: a MIME outside the configured allowlist → 422 unsupported_media_type", %{
      conn: conn
    } do
      put_media_cfg(
        allowed_mime_types: ["image/png"],
        allowed_extensions: [],
        max_upload_bytes: nil
      )

      blob = upload("notes.txt", "image/png", "not actually a png")

      resp =
        conn
        |> authed()
        |> post(~p"/v1/media/production/upload", %{"file" => blob})

      assert resp.status == 422
      assert json_response(resp, 422)["error"]["code"] == "unsupported_media_type"
    end

    test "PART 2: a file over the configured size cap → 413 payload_too_large", %{conn: conn} do
      put_media_cfg(allowed_mime_types: [], allowed_extensions: [], max_upload_bytes: 4)

      png_bin = Base.decode64!(@png_b64)
      blob = upload("pixel.png", "image/png", png_bin)

      resp =
        conn
        |> authed()
        |> post(~p"/v1/media/production/upload", %{"file" => blob})

      assert resp.status == 413
      assert json_response(resp, 413)["error"]["code"] == "payload_too_large"
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

      # The store's own row, read BEFORE the delete. `filename` is generated at
      # upload; the DELETE request carries nothing but `:dataset` and `:id`.
      stored = Barkpark.Repo.get(Barkpark.Media.Storage.MediaFile, id)
      assert %Barkpark.Media.Storage.MediaFile{} = stored
      refute stored.filename == id

      resp =
        conn
        |> authed()
        |> delete(~p"/v1/media/production/#{id}")

      assert resp.status == 200
      body = json_response(resp, 200)
      assert body["result"]["deleted"] == id

      # RECEIPT LAW (pds w40, task-aa1194c2c4aac214): `deleted == id` alone is
      # VACUOUS for the request-echo species — the path param and the row id are
      # the same value in the happy path, so it stays green over BOTH the
      # repaired shape and the old `%{deleted: id}` echo. `filename` is the
      # differential: the request cannot produce it, so reverting the emitter to
      # the path-param echo drops the key and reds this line.
      assert body["result"]["filename"] == stored.filename,
             "receipt did not descend from the write return — it echoed the :id path param"

      refute File.exists?(Path.join(Media.upload_dir(), relative))
    end
  end
end
