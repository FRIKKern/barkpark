defmodule BarkparkWeb.Integration.MediaDeliveryAcceptTest do
  @moduledoc """
  Strict `Accept` headers on the media delivery routes (task-701191424b8d15e8).

  The delivery GETs rode pipelines that run `plug(:accepts, ["json"])`, so
  `Accept: image/webp` (no json, no `*/*`) raised Phoenix.NotAcceptableError
  and answered 406 with `internal_error` and a "Retry shortly" hint. A browser
  header worked only because it carries `*/*`. Sanity's CDN serves any Accept.

  This file pins three things:

    * every delivery route kind (flat `/media/files` and `/media/renditions`,
      their `/w/:ws/p/:proj` mirrors, Sanity `/images` and `/files`) answers
      `image/webp`, `image/avif`, `image/*` and `application/pdf` with the
      same status a browser header gets;
    * a strict image header still picks the format for `auto=format`;
    * a JSON route still refuses a header that cannot take JSON, now as 406
      `not_acceptable` with no retry hint.

  MUTATION PROOF: dropping `:delivery_accept` from a delivery scope's
  `pipe_through` reds that route's tests here with a raised
  Phoenix.NotAcceptableError. Dropping the NotAcceptableError clause from
  `BarkparkWeb.ErrorJSON` reds the `not_acceptable` tests (code
  `internal_error`).
  """
  use BarkparkWeb.ConnCase, async: false

  # The media plugin owns the upload route and the Sanity asset lookup.
  @moduletag :requires_plugins

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Media, Repo, Tenancy}
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Plugins.Media.Assets

  @project_id "abc123de"
  @browser "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"
  @strict ["image/webp", "image/avif", "image/*", "application/pdf"]

  setup do
    ws = create_workspace!()
    proj = create_project!(ws)
    raw = "delivery-accept-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "delivery-accept", "production", ["read", "write"], ws.id)

    %{ws: ws, proj: proj, raw: raw, base: "/w/#{ws.slug}/p/#{proj.slug}"}
  end

  defp as(raw), do: scoped_conn() |> put_req_header("authorization", "Bearer #{raw}")

  defp jpeg_path do
    {:ok, image} = Image.new(64, 48, color: [200, 30, 30])
    path = Path.join(System.tmp_dir!(), "accept-#{System.unique_integer([:positive])}.jpg")
    {:ok, _} = Image.write(image, path, quality: 90)
    path
  end

  defp pdf_path do
    path = Path.join(System.tmp_dir!(), "accept-#{System.unique_integer([:positive])}.pdf")
    File.write!(path, "%PDF-1.4\n% accept #{System.unique_integer([:positive])}\n%%EOF\n")
    path
  end

  defp upload(ctx, path, filename, content_type, source_id) do
    file = %Plug.Upload{path: path, filename: filename, content_type: content_type}

    resp =
      as(ctx.raw)
      |> post("#{ctx.base}/v1/media/production/upload", %{
        "file" => file,
        "sourceId" => source_id
      })

    assert resp.status in [200, 201], resp.resp_body
    result = json_response(resp, resp.status)["result"]

    on_exit(fn ->
      File.rm(Path.join(Media.upload_dir(), result["path"]))
      Media.Renditions.delete_for_file(result["id"])
      Assets.delete_for_blob(result["id"], "production")
    end)

    result
  end

  # A row in the seeded Default workspace, which the flat `/media` routes pin.
  defp default_scope_file(source, filename, mime) do
    {ws, project} = ensure_default_scope!()
    {:ok, dataset} = Tenancy.get_or_create_dataset(project.id, "production")

    path = "2026/10/accept-#{System.unique_integer([:positive])}-#{filename}"
    dest = Path.join(Media.upload_dir(), path)
    File.mkdir_p!(Path.dirname(dest))
    File.cp!(source, dest)

    file =
      %MediaFile{}
      |> MediaFile.changeset(%{
        filename: filename,
        original_name: filename,
        path: path,
        mime_type: mime,
        size: File.stat!(dest).size,
        dataset: "production",
        workspace_id: ws.id,
        project_id: project.id,
        dataset_id: dataset.id
      })
      |> Repo.insert!()

    on_exit(fn ->
      File.rm(dest)
      Media.Renditions.delete_for_file(file.id)
    end)

    file
  end

  defp sha(n), do: n |> to_string() |> String.duplicate(40) |> binary_part(0, 40)

  defp fetch(conn, url, accept), do: conn |> put_req_header("accept", accept) |> get(url)

  defp content_type(resp) do
    [value] = get_resp_header(resp, "content-type")
    value |> String.split(";") |> hd()
  end

  # Each strict header gets the status the browser header gets, and that is a
  # 200 carrying bytes, never a 406 or a JSON error.
  defp assert_like_browser(conn_fun, url) do
    browser = fetch(conn_fun.(), url, @browser)
    assert browser.status == 200, "browser Accept: #{browser.status} #{browser.resp_body}"

    for accept <- @strict do
      resp = fetch(conn_fun.(), url, accept)

      assert resp.status == browser.status,
             "Accept: #{accept} on #{url} gave #{resp.status}: #{resp.resp_body}"

      refute content_type(resp) == "application/json", "Accept: #{accept} got a JSON body"
      assert resp.resp_body != ""
    end

    browser
  end

  describe "flat /media delivery routes" do
    test "GET /media/files/*path answers every strict Accept like a browser" do
      jpeg = default_scope_file(jpeg_path(), "photo.jpg", "image/jpeg")
      pdf = default_scope_file(pdf_path(), "doc.pdf", "application/pdf")

      assert_like_browser(&scoped_conn/0, "/media/files/#{jpeg.path}")
      assert_like_browser(&scoped_conn/0, "/media/files/#{jpeg.path}?w=32&auto=format")
      resp = assert_like_browser(&scoped_conn/0, "/media/files/#{pdf.path}")
      assert content_type(resp) == "application/pdf"

      webp = fetch(scoped_conn(), "/media/files/#{jpeg.path}?w=32&auto=format", "image/webp")
      assert content_type(webp) == "image/webp"
    end

    test "GET /media/renditions/:id/:preset answers every strict Accept like a browser" do
      jpeg = default_scope_file(jpeg_path(), "photo.jpg", "image/jpeg")

      assert_like_browser(&scoped_conn/0, "/media/renditions/#{jpeg.id}/thumb")
    end

    test "the JSON index still refuses a strict image Accept, as 406 not_acceptable" do
      {status, _headers, body} =
        assert_error_sent(406, fn -> fetch(scoped_conn(), "/media", "image/webp") end)

      assert status == 406
      error = Jason.decode!(body)["error"]
      assert error["code"] == "not_acceptable"
      refute (error["hint"] || "") =~ ~r/retry/i
      refute error["message"] =~ "NotAcceptableError"
    end
  end

  describe "scoped /w/:ws/p/:proj/media delivery routes" do
    test "GET .../media/files/*path answers every strict Accept like a browser", ctx do
      jpeg = upload(ctx, jpeg_path(), "photo.jpg", "image/jpeg", "image-#{sha("c")}-64x48-jpg")
      pdf = upload(ctx, pdf_path(), "doc.pdf", "application/pdf", "file-#{sha("d")}-pdf")
      conn = fn -> as(ctx.raw) end

      assert_like_browser(conn, "#{ctx.base}/media/files/#{jpeg["path"]}")
      assert_like_browser(conn, "#{ctx.base}/media/files/#{jpeg["path"]}?w=32&auto=format")
      resp = assert_like_browser(conn, "#{ctx.base}/media/files/#{pdf["path"]}")
      assert content_type(resp) == "application/pdf"
    end

    test "GET .../media/renditions/:id/:preset answers every strict Accept like a browser",
         ctx do
      jpeg = upload(ctx, jpeg_path(), "photo.jpg", "image/jpeg", "image-#{sha("e")}-64x48-jpg")

      assert_like_browser(
        fn -> as(ctx.raw) end,
        "#{ctx.base}/media/renditions/#{jpeg["id"]}/thumb"
      )
    end

    test "the scoped JSON index and meta still refuse a strict Accept, as 406 not_acceptable",
         ctx do
      jpeg = upload(ctx, jpeg_path(), "photo.jpg", "image/jpeg", "image-#{sha("f")}-64x48-jpg")

      for url <- ["#{ctx.base}/media", "#{ctx.base}/media/#{jpeg["id"]}/meta"] do
        {406, _headers, body} =
          assert_error_sent(406, fn -> fetch(as(ctx.raw), url, "image/webp") end)

        error = Jason.decode!(body)["error"]
        assert error["code"] == "not_acceptable"
        refute (error["hint"] || "") =~ ~r/retry/i
      end
    end
  end

  describe "Sanity-shaped /images and /files" do
    test "GET .../images/... answers every strict Accept like a browser", ctx do
      sanity_sha = sha("a")
      upload(ctx, jpeg_path(), "photo.jpg", "image/jpeg", "image-#{sanity_sha}-64x48-jpg")
      url = "#{ctx.base}/images/#{@project_id}/production/#{sanity_sha}-64x48.jpg"
      conn = fn -> as(ctx.raw) end

      assert_like_browser(conn, url)
      assert_like_browser(conn, url <> "?w=32&auto=format")
    end

    test "Accept: image/webp alone on auto=format returns 200 image/webp", ctx do
      sanity_sha = sha("1")
      upload(ctx, jpeg_path(), "photo.jpg", "image/jpeg", "image-#{sanity_sha}-64x48-jpg")
      url = "#{ctx.base}/images/#{@project_id}/production/#{sanity_sha}-64x48.jpg"

      resp = fetch(as(ctx.raw), url <> "?w=32&auto=format", "image/webp")
      assert resp.status == 200
      assert get_resp_header(resp, "content-type") == ["image/webp"]

      # `image/*` names neither avif nor webp, so auto=format keeps the source format.
      star = fetch(as(ctx.raw), url <> "?w=32&auto=format", "image/*")
      assert star.status == 200
      assert content_type(star) == "image/jpeg"
    end

    test "GET .../files/... answers every strict Accept like a browser", ctx do
      sanity_sha = sha("b")
      upload(ctx, pdf_path(), "doc.pdf", "application/pdf", "file-#{sanity_sha}-pdf")
      url = "#{ctx.base}/files/#{@project_id}/production/#{sanity_sha}.pdf"

      resp = assert_like_browser(fn -> as(ctx.raw) end, url)
      assert content_type(resp) == "application/pdf"
    end
  end

  describe "a JSON API route" do
    test "a strict Accept answers 406 not_acceptable with no retry hint", ctx do
      {406, _headers, body} =
        assert_error_sent(406, fn ->
          fetch(as(ctx.raw), "#{ctx.base}/v1/data/counts/production", "image/webp")
        end)

      error = Jason.decode!(body)["error"]
      assert error["code"] == "not_acceptable"
      assert error["message"] == "the Accept header names no format this route can return"
      assert is_binary(error["hint"])
      refute error["hint"] =~ ~r/retry/i
    end

    test "a JSON Accept on the same route is unchanged", ctx do
      resp = fetch(as(ctx.raw), "#{ctx.base}/v1/data/counts/production", "application/json")
      refute resp.status == 406
    end
  end
end
