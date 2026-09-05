defmodule BarkparkWeb.Integration.V1MediaUploadReceiptTest do
  @moduledoc """
  task-57ee9fff4aae9217 #11 + #13 — the upload response must be a COMPLETE
  RECEIPT, and metadata must be accepted inline.

  Three concrete complaints from the report, and one test each:

    * `mediaFileId` "had to be REGEXED out of a rendition URL". The receipt
      carried `id` and `assetDocId`, and nothing said which id `id` was. It is
      now named outright.
    * `cdnUrls.original` "is the FLAT path, which 404s outside the default
      workspace". `Cdn.url_map/1` emitted `/media/files/...` unconditionally,
      ignoring the request scope the sibling `url` / `originalUrl` fields
      already honoured.
    * "No metadata accepted at upload — altText/caption/tags each need a
      separate update call." One POST now carries them.

  Server-side `lqip`/`blurhash` is NOT built here and is deferred deliberately:
  it is a PROCESSING-time concern (`Barkpark.Media.Processing`), it needs the
  image backend to decode and downsample every upload, and it changes no wire
  contract this criterion names. Nothing above depends on it.
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
      "v1-media-receipt-test",
      ["read", "write", "admin"]
    )

    :ok
  end

  describe "POST /v1/media/:dataset/upload — the receipt names every id" do
    test "carries mediaFileId alongside assetDocId, with no regexing", %{conn: conn} do
      body =
        conn
        |> authed()
        |> post(~p"/v1/media/production/upload", %{"file" => png_upload()})
        |> json_response(201)

      result = body["result"]

      assert result["mediaFileId"],
             "the upload receipt carries no mediaFileId — a client has to regex it out of " <>
               "a rendition URL, which is the reported defect"

      assert result["mediaFileId"] == result["id"]
      assert result["assetDocId"], "the upload receipt carries no assetDocId"
      refute result["mediaFileId"] == result["assetDocId"]

      # The named id is the one the write routes actually take.
      assert {:ok, _file} = Media.get_file(result["mediaFileId"])

      rm_uploaded(result)
    end
  end

  describe "POST /v1/media/:dataset/upload — metadata inline" do
    test "altText, caption and tags land in ONE call", %{conn: conn} do
      body =
        conn
        |> authed()
        |> post(~p"/v1/media/production/upload", %{
          "file" => png_upload(),
          "altText" => "A single red pixel",
          "caption" => "Test fixture",
          "tags" => "fixture, pixel , red"
        })
        |> json_response(201)

      asset = body["result"]["asset"]

      assert asset["altText"] == "A single red pixel",
             "altText was not accepted at upload — it still costs a second PATCH"

      assert asset["caption"] == "Test fixture"

      # A multipart `tags` part is ONE string; it is split, not stored whole.
      assert asset["tags"] == ["fixture", "pixel", "red"]

      rm_uploaded(body["result"])
    end

    test "an upload with no metadata parts is unchanged", %{conn: conn} do
      body =
        conn
        |> authed()
        |> post(~p"/v1/media/production/upload", %{"file" => png_upload()})
        |> json_response(201)

      assert body["result"]["assetDocId"]
      refute body["result"]["asset"]["altText"]

      rm_uploaded(body["result"])
    end

    test "a multipart part outside the metadata allowlist cannot touch the blob", %{conn: conn} do
      body =
        conn
        |> authed()
        |> post(~p"/v1/media/production/upload", %{
          "file" => png_upload(),
          "path" => "../../etc/passwd",
          "mimeType" => "text/html",
          "size" => "999999"
        })
        |> json_response(201)

      result = body["result"]

      assert result["mimeType"] == "image/png"
      assert result["path"] =~ ~r"^(d/[^/]+/)?\d{4}/\d{2}/"
      refute result["path"] =~ "passwd"

      rm_uploaded(result)
    end
  end

  describe "the receipt's URLs are SERVABLE from the scope that uploaded" do
    test "cdnUrls carry the request's /w/:ws/p/:proj prefix" do
      file = upload_direct!()
      doc = Media.asset_doc_for_file(file, "production")

      scoped =
        AssetResponse.render(file, doc, dataset: "production", conn: scoped_conn("acme", "site"))

      assert scoped.cdnUrls.original == "/w/acme/p/site/media/files/#{file.path}",
             "cdnUrls.original is the FLAT path — it 404s for a caller resolved under " <>
               "/w/acme/p/site, which is the reported defect"

      assert String.starts_with?(scoped.cdnUrls.thumbnail, "/w/acme/p/site/")
      assert String.starts_with?(scoped.cdnUrls.preview, "/w/acme/p/site/")

      Enum.each(scoped.cdnUrls.renditions, fn {_preset, url} ->
        assert String.starts_with?(url, "/w/acme/p/site/")
      end)

      # And the FLAT conn is byte-identical to before — persisted-URL consumers
      # and the webhook payload (Cdn.url_map/1, still arity 1) do not move.
      flat = AssetResponse.render(file, doc, dataset: "production")
      assert flat.cdnUrls.original == "/media/files/#{file.path}"

      cleanup!(file)
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer barkpark-dev-token")

  defp png_upload do
    tmp_path =
      Path.join(System.tmp_dir!(), "v1-receipt-#{System.unique_integer([:positive])}.png")

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
