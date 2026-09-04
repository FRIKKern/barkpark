defmodule BarkparkWeb.Controllers.MediaAbsoluteUrlTest do
  @moduledoc """
  jf-backlog-media-absolute-url — the asset record must carry ONE url a client
  can fetch as-is.

  Before this, every url in an upload receipt (`url`, `originalUrl`,
  `previewUrl`, `thumbnailUrl`, `renditions.*`, `cdnUrls.*`) was a relative
  delivery PATH, and nothing in the 201 or in `GET /v1/media/:dataset/:id`
  named the origin that serves them — a path pasted cross-origin silently 404s.

  `absoluteUrl` is ADDITIVE. The tests below therefore assert BOTH halves:

    * the new field starts with the origin (`BarkparkWeb.Endpoint.url/0`, or the
      configured `:media_cdn, :base_url` when one is set), and
    * every pre-existing url field is byte-for-byte what it was — still the
      relative path — because persisted webhook payloads and the JS SDK read
      them.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Media
  alias Barkpark.Media.Delivery.AssetResponse
  alias Barkpark.Plugins.Media.Assets

  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  setup do
    Auth.create_token(
      "barkpark-dev-token",
      "dev",
      "media-absolute-url-test",
      ["read", "write", "admin"]
    )

    :ok
  end

  describe "POST /v1/media/:dataset/upload — the 201 receipt" do
    test "carries absoluteUrl rooted at the endpoint origin", %{conn: conn} do
      result =
        conn
        |> authed()
        |> post(~p"/v1/media/production/upload", %{"file" => png_upload()})
        |> json_response(201)
        |> Map.fetch!("result")

      origin = BarkparkWeb.Endpoint.url()

      assert absolute = result["absoluteUrl"],
             "the upload 201 carries no absoluteUrl — every url in the receipt is a " <>
               "relative path and nothing names the origin that serves it"

      assert String.starts_with?(absolute, origin),
             "absoluteUrl #{inspect(absolute)} is not rooted at the endpoint origin " <>
               "#{inspect(origin)}"

      assert absolute == origin <> result["url"],
             "absoluteUrl must be the SAME resource as url, just origin-qualified"

      # ADDITIVE: the relative fields did not move.
      assert result["url"] == "/media/files/#{result["path"]}"
      assert result["originalUrl"] == result["url"]
      assert String.starts_with?(result["cdnUrls"]["original"], "/media/files/")

      rm_uploaded(result)
    end
  end

  describe "GET /v1/media/:dataset/:id — the media get" do
    test "carries absoluteUrl rooted at the endpoint origin", %{conn: conn} do
      # Upload over HTTP, not Media.upload/2 — the GET resolves the blob under
      # the caller's tenancy scope, so a fixture row written with no workspace
      # is invisible to it (404) and the assertion below would never run.
      uploaded =
        conn
        |> authed()
        |> post(~p"/v1/media/production/upload", %{"file" => png_upload()})
        |> json_response(201)
        |> Map.fetch!("result")

      result =
        conn
        |> authed()
        |> get(~p"/v1/media/production/#{uploaded["id"]}")
        |> json_response(200)
        |> Map.fetch!("result")

      origin = BarkparkWeb.Endpoint.url()

      assert absolute = result["absoluteUrl"],
             "GET /v1/media/production/:id carries no absoluteUrl"

      assert String.starts_with?(absolute, origin)
      assert absolute == origin <> "/media/files/#{result["path"]}"
      assert result["url"] == "/media/files/#{result["path"]}"

      rm_uploaded(result)
    end
  end

  describe "the origin comes from the CDN base when one is configured" do
    test "absoluteUrl is the CDN url, and it honours the request scope prefix" do
      file = upload_direct!()
      doc = Media.asset_doc_for_file(file, "production")

      prev = Application.get_env(:barkpark, :media_cdn, [])
      Application.put_env(:barkpark, :media_cdn, Keyword.put(prev, :base_url, "https://cdn.test"))

      on_exit(fn -> Application.put_env(:barkpark, :media_cdn, prev) end)

      flat = AssetResponse.render(file, doc, dataset: "production")

      assert flat.absoluteUrl == "https://cdn.test/media/files/#{file.path}",
             "with :media_cdn, :base_url set the CDN owns the origin"

      scoped =
        AssetResponse.render(file, doc, dataset: "production", conn: scoped_conn("acme", "site"))

      assert scoped.absoluteUrl == "https://cdn.test/w/acme/p/site/media/files/#{file.path}",
             "absoluteUrl must carry the request's /w/:ws/p/:proj prefix like cdnUrls does — " <>
               "a flat path that 404s under a scoped request is not resolvable"

      cleanup!(file)
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer barkpark-dev-token")

  defp png_upload do
    tmp_path =
      Path.join(System.tmp_dir!(), "media-abs-#{System.unique_integer([:positive])}.png")

    File.write!(tmp_path, Base.decode64!(@png_b64))

    %Plug.Upload{path: tmp_path, filename: "pixel.png", content_type: "image/png"}
  end

  defp upload_direct! do
    {:ok, file} = Media.upload(png_upload(), "production")
    file
  end

  defp scoped_conn(ws, proj) do
    %{
      Phoenix.ConnTest.build_conn()
      | path_params: %{"workspace_slug" => ws, "project_slug" => proj}
    }
  end

  defp rm_uploaded(%{"id" => id, "path" => relative}) do
    File.rm(Path.join(Media.upload_dir(), relative))
    Barkpark.Media.Renditions.delete_for_file(id)
    Assets.delete_for_blob(id, "production")
  end

  defp cleanup!(file) do
    File.rm(Path.join(Media.upload_dir(), file.path))
    Barkpark.Media.Renditions.delete_for_file(file.id)
    Assets.delete_for_blob(file.id, "production")
  end
end
