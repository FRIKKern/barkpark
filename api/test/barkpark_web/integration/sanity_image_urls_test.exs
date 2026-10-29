defmodule BarkparkWeb.Integration.SanityImageUrlsTest do
  @moduledoc """
  Sanity CDN URLs answered from Barkpark media (task-0bc9247eca1bd741).

  A site keeps `@sanity/image-url` and sets `baseUrl` to
  `<host>/w/<ws>/p/<proj>`. The query strings below are what
  `@sanity/image-url` 2.1.1 builds for a 600x400 JPEG with
  `createImageUrlBuilder({projectId: 'abc123de', dataset: 'production', baseUrl})`:

      .width(300)                                   ?w=300
      crop {top 0, bottom .5, left .5, right 0},
      hotspot {x .75, y .25, w .2, h .2},
      .width(150).height(100)                       ?rect=300,0,300,200&w=150&h=100
      .width(100).auto('format')                    ?w=100&auto=format
      .width(100).height(100).fit('crop')
      .focalPoint(0.95, 0.5)                        ?fp-x=0.95&fp-y=0.5&w=100&h=100&fit=crop

  The test image is red on its left half and blue on its right, so a crop's
  position shows in its pixels.
  """
  use BarkparkWeb.ConnCase, async: false

  # The media plugin owns mediaAsset, its upload hook and the media routes.
  @moduletag :requires_plugins

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Media, Repo}
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Plugins.Media.Assets

  @project_id "abc123de"

  setup do
    ws = create_workspace!()
    proj = create_project!(ws)
    raw = "sanity-urls-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "sanity-urls", "production", ["read", "write"], ws.id)

    %{ws: ws, proj: proj, raw: raw, base: "/w/#{ws.slug}/p/#{proj.slug}"}
  end

  defp as(raw), do: scoped_conn() |> put_req_header("authorization", "Bearer #{raw}")

  # 600x400 JPEG: left half red, right half blue.
  defp two_tone_jpeg do
    {:ok, red} = Image.new(300, 400, color: [255, 0, 0])
    {:ok, blue} = Image.new(300, 400, color: [0, 0, 255])
    {:ok, joined} = Vix.Vips.Operation.join(red, blue, :VIPS_DIRECTION_HORIZONTAL)
    path = Path.join(System.tmp_dir!(), "sanity-#{System.unique_integer([:positive])}.jpg")
    {:ok, _} = Image.write(joined, path, quality: 95)
    path
  end

  defp pdf_file do
    path = Path.join(System.tmp_dir!(), "sanity-#{System.unique_integer([:positive])}.pdf")
    File.write!(path, "%PDF-1.4\n% sanity file #{System.unique_integer([:positive])}\n%%EOF\n")
    path
  end

  defp upload(ctx, path, filename, content_type, extra \\ %{}) do
    file = %Plug.Upload{path: path, filename: filename, content_type: content_type}

    resp =
      as(ctx.raw)
      |> post("#{ctx.base}/v1/media/production/upload", Map.put(extra, "file", file))

    body = json_response(resp, resp.status)
    assert resp.status in [200, 201], resp.resp_body
    result = body["result"]
    on_exit(fn -> cleanup(result) end)
    result
  end

  defp upload_image(ctx, extra \\ %{}),
    do: upload(ctx, two_tone_jpeg(), "two-tone.jpg", "image/jpeg", extra)

  defp cleanup(%{"id" => id, "path" => path}) do
    File.rm(Path.join(Media.upload_dir(), path))
    Media.Renditions.delete_for_file(id)
    Assets.delete_for_blob(id, "production")
  end

  defp sha(n), do: n |> to_string() |> String.duplicate(40) |> binary_part(0, 40)

  defp image_url(ctx, sha1, dims, query, dataset \\ "production"),
    do: "#{ctx.base}/images/#{@project_id}/#{dataset}/#{sha1}-#{dims}.jpg?#{query}"

  defp decode(body) do
    {:ok, image} = Image.from_binary(body)
    image
  end

  defp size(image), do: {Image.width(image), Image.height(image)}

  defp centre_rgb(image) do
    {:ok, [r, g, b | _]} =
      Vix.Vips.Image.get_pixel(image, div(Image.width(image), 2), div(Image.height(image), 2))

    {round(r), round(g), round(b)}
  end

  defp content_type(resp) do
    [value] = get_resp_header(resp, "content-type")
    value |> String.split(";") |> hd()
  end

  describe "GET /w/:ws/p/:proj/images/:project/:dataset/<sha1>-<w>x<h>.<ext>" do
    test "resolves by sourceId and serves @sanity/image-url width, crop and hotspot, auto=format and fit",
         ctx do
      sanity_sha = sha("a")
      result = upload_image(ctx, %{"sourceId" => "image-#{sanity_sha}-600x400-jpg"})
      assert result["sourceId"] == "image-#{sanity_sha}-600x400-jpg"

      width = as(ctx.raw) |> get(image_url(ctx, sanity_sha, "600x400", "w=300"))
      assert width.status == 200, width.resp_body
      assert content_type(width) == "image/jpeg"
      assert size(decode(width.resp_body)) == {300, 200}
      assert get_resp_header(width, "vary") == ["Accept"]
      assert [_etag] = get_resp_header(width, "etag")

      crop =
        as(ctx.raw)
        |> get(image_url(ctx, sanity_sha, "600x400", "rect=300,0,300,200&w=150&h=100"))

      assert crop.status == 200, crop.resp_body
      image = decode(crop.resp_body)
      assert size(image) == {150, 100}
      {r, _g, b} = centre_rgb(image)
      assert b > 200 and r < 60, "the crop keeps the right half, which is blue"

      auto =
        as(ctx.raw)
        |> put_req_header("accept", "image/avif,image/webp,*/*")
        |> get(image_url(ctx, sanity_sha, "600x400", "w=100&auto=format"))

      assert auto.status == 200
      assert content_type(auto) in ["image/avif", "image/webp"]

      fit =
        as(ctx.raw)
        |> get(image_url(ctx, sanity_sha, "600x400", "fp-x=0.95&fp-y=0.5&w=100&h=100&fit=crop"))

      assert fit.status == 200
      image = decode(fit.resp_body)
      assert size(image) == {100, 100}
      {r, _g, b} = centre_rgb(image)
      assert b > 200 and r < 60, "a focal point on the right keeps the blue half"
    end

    test "the transform is cached: the second request reads the same file", ctx do
      sanity_sha = sha("b")
      result = upload_image(ctx, %{"sourceId" => "image-#{sanity_sha}-600x400-jpg"})
      url = image_url(ctx, sanity_sha, "600x400", "w=120")

      first = as(ctx.raw) |> get(url)
      assert first.status == 200

      dir = Path.join([Media.upload_dir(), "_renditions", result["id"], "t"])
      assert {:ok, [cached]} = File.ls(dir)

      second = as(ctx.raw) |> get(url)
      assert second.resp_body == first.resp_body
      assert File.ls(dir) == {:ok, [cached]}

      [etag] = get_resp_header(first, "etag")
      assert (as(ctx.raw) |> put_req_header("if-none-match", etag) |> get(url)).status == 304
    end

    test "moves rect into the stored size when the import stored a smaller image", ctx do
      # Sanity declared 1200x800; Barkpark stored 600x400, as an import that
      # downloaded a capped copy from the CDN would.
      sanity_sha = sha("c")
      upload_image(ctx, %{"sourceId" => "image-#{sanity_sha}-1200x800-jpg"})

      resp =
        as(ctx.raw)
        |> get(image_url(ctx, sanity_sha, "1200x800", "rect=600,0,600,400&w=150&h=100"))

      assert resp.status == 200, resp.resp_body
      image = decode(resp.resp_body)
      assert size(image) == {150, 100}
      {r, _g, b} = centre_rgb(image)
      assert b > 200 and r < 60, "the scaled rect still keeps the blue half"
    end

    test "falls back to the sha1 of the stored bytes when no sourceId matches", ctx do
      result = upload_image(ctx)
      %MediaFile{sha1: stored_sha} = Repo.get!(MediaFile, result["id"])

      resp = as(ctx.raw) |> get(image_url(ctx, stored_sha, "600x400", "w=60"))
      assert resp.status == 200, resp.resp_body
      assert size(decode(resp.resp_body)) == {60, 40}
    end

    test "without transform parameters serves the original bytes", ctx do
      sanity_sha = sha("d")
      result = upload_image(ctx, %{"sourceId" => "image-#{sanity_sha}-600x400-jpg"})

      resp = as(ctx.raw) |> get("#{ctx.base}/images/any/production/#{sanity_sha}-600x400.jpg")
      assert resp.status == 200
      original = File.read!(Path.join(Media.upload_dir(), result["path"]))
      assert resp.resp_body == original
    end

    test "Sanity's dl downloads the original and a transform", ctx do
      sanity_sha = sha("5")
      upload_image(ctx, %{"sourceId" => "image-#{sanity_sha}-600x400-jpg"})

      for query <- ["dl=", "w=30&dl="] do
        resp = as(ctx.raw) |> get(image_url(ctx, sanity_sha, "600x400", query))
        assert resp.status == 200, resp.resp_body

        assert get_resp_header(resp, "content-disposition") ==
                 [~s<attachment; filename="two-tone.jpg"; filename*=UTF-8''two-tone.jpg>]
      end

      resp = as(ctx.raw) |> get(image_url(ctx, sanity_sha, "600x400", "w=30"))
      assert get_resp_header(resp, "content-disposition") == ["inline"]
    end

    test "accepts a vanity file name after the asset name", ctx do
      sanity_sha = sha("e")
      upload_image(ctx, %{"sourceId" => "image-#{sanity_sha}-600x400-jpg"})

      url =
        "#{ctx.base}/images/#{@project_id}/production/#{sanity_sha}-600x400.jpg/cover.jpg?w=30"

      assert (as(ctx.raw) |> get(url)).status == 200
    end

    test "an unknown asset, another dataset or a malformed name answers 404", ctx do
      sanity_sha = sha("f")
      upload_image(ctx, %{"sourceId" => "image-#{sanity_sha}-600x400-jpg"})

      assert (as(ctx.raw) |> get(image_url(ctx, sha("9"), "600x400", "w=10"))).status == 404

      assert (as(ctx.raw) |> get(image_url(ctx, sanity_sha, "600x400", "w=10", "staging"))).status ==
               404

      assert (as(ctx.raw) |> get("#{ctx.base}/images/x/production/not-an-asset.jpg")).status ==
               404
    end

    test "@sanity/image-url's dpr and blur are applied, not refused", ctx do
      sanity_sha = sha("1")
      upload_image(ctx, %{"sourceId" => "image-#{sanity_sha}-600x400-jpg"})

      resp = as(ctx.raw) |> get(image_url(ctx, sanity_sha, "600x400", "w=10&dpr=2&blur=20"))
      assert resp.status == 200
      {:ok, image} = Image.from_binary(resp.resp_body)
      assert Image.width(image) == 20
    end

    test "another workspace's token cannot read the asset", ctx do
      sanity_sha = sha("2")
      upload_image(ctx, %{"sourceId" => "image-#{sanity_sha}-600x400-jpg"})

      other_ws = create_workspace!()
      other = "sanity-other-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(other, "sanity-other", "production", ["read"], other_ws.id)

      resp = as(other) |> get(image_url(ctx, sanity_sha, "600x400", "w=10"))
      assert resp.status in [403, 404], "got #{resp.status}: #{resp.resp_body}"
    end
  end

  describe "GET /w/:ws/p/:proj/files/:project/:dataset/<sha1>.<ext>" do
    test "resolves by sourceId and serves the bytes inline; other query parameters are ignored",
         ctx do
      path = pdf_file()
      bytes = File.read!(path)
      sanity_sha = sha("3")
      upload(ctx, path, "doc.pdf", "application/pdf", %{"sourceId" => "file-#{sanity_sha}-pdf"})

      resp =
        as(ctx.raw) |> get("#{ctx.base}/files/#{@project_id}/production/#{sanity_sha}.pdf?x=1")

      assert resp.status == 200, resp.resp_body
      assert resp.resp_body == bytes
      assert get_resp_header(resp, "content-disposition") == ["inline"]
    end

    test "Sanity's dl downloads under the original or the given file name", ctx do
      sanity_sha = sha("4")

      upload(ctx, pdf_file(), "Årsrapport.pdf", "application/pdf", %{
        "sourceId" => "file-#{sanity_sha}-pdf"
      })

      url = "#{ctx.base}/files/#{@project_id}/production/#{sanity_sha}.pdf"
      disposition = &get_resp_header(as(ctx.raw) |> get(url <> &1), "content-disposition")

      original = ~s<attachment; filename="_rsrapport.pdf"; filename*=UTF-8''%C3%85rsrapport.pdf>
      assert disposition.("?dl") == [original]
      assert disposition.("?dl=") == [original]

      assert disposition.("?dl=my%20%22file%22.pdf") ==
               [~s<attachment; filename="my _file_.pdf"; filename*=UTF-8''my%20%22file%22.pdf>]
    end

    test "falls back to the sha1 of the stored bytes", ctx do
      path = pdf_file()
      stored_sha = :crypto.hash(:sha, File.read!(path)) |> Base.encode16(case: :lower)
      upload(ctx, path, "doc.pdf", "application/pdf")

      resp = as(ctx.raw) |> get("#{ctx.base}/files/#{@project_id}/production/#{stored_sha}.pdf")
      assert resp.status == 200
    end
  end

  describe "sourceId on the upload and update API" do
    test "an upload whose sourceId already names a file returns that file and stores nothing",
         ctx do
      source_id = "image-#{sha("4")}-600x400-jpg"
      first = upload_image(ctx, %{"sourceId" => source_id})
      before = Repo.aggregate(MediaFile, :count)

      file = %Plug.Upload{
        path: pdf_file(),
        filename: "other.pdf",
        content_type: "application/pdf"
      }

      resp =
        as(ctx.raw)
        |> post("#{ctx.base}/v1/media/production/upload", %{
          "file" => file,
          "sourceId" => source_id
        })

      body = json_response(resp, 200)
      assert body["existing"] == true
      assert body["result"]["id"] == first["id"]
      assert Repo.aggregate(MediaFile, :count) == before
    end

    test "a malformed sourceId is refused before anything is stored", ctx do
      before = Repo.aggregate(MediaFile, :count)
      file = %Plug.Upload{path: pdf_file(), filename: "x.pdf", content_type: "application/pdf"}

      resp =
        as(ctx.raw)
        |> post("#{ctx.base}/v1/media/production/upload", %{"file" => file, "sourceId" => "a b/c"})

      assert resp.status == 422, resp.resp_body
      assert Repo.aggregate(MediaFile, :count) == before
    end

    test "PATCH sets, refuses a taken id, and clears sourceId", ctx do
      a = upload_image(ctx)
      b = upload(ctx, pdf_file(), "b.pdf", "application/pdf")
      source_id = "image-#{sha("5")}-600x400-jpg"
      url = fn id -> "#{ctx.base}/v1/media/production/#{id}" end

      set = as(ctx.raw) |> patch(url.(a["id"]), %{"sourceId" => source_id})
      assert json_response(set, 200)["result"]["sourceId"] == source_id

      assert (as(ctx.raw) |> get(image_url(ctx, sha("5"), "600x400", "w=10"))).status == 200

      taken = as(ctx.raw) |> patch(url.(b["id"]), %{"sourceId" => source_id})
      assert taken.status == 422, taken.resp_body

      cleared = as(ctx.raw) |> patch(url.(a["id"]), %{"sourceId" => nil})
      assert json_response(cleared, 200)["result"]["sourceId"] == nil
      assert Repo.get!(MediaFile, a["id"]).source_id == nil
    end
  end
end
