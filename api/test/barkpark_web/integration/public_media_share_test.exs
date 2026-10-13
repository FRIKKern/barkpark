defmodule BarkparkWeb.Integration.PublicMediaShareTest do
  @moduledoc """
  Public media for a website (task-c9fb2c2087dbba4d).

  A browser loads a site's images without a token. The opt-in that makes a
  scope's media readable by an anonymous caller is the `:media` `:read` share
  (`POST /v1/shares/media`, `bp share publish-media <ws>/<proj>/<dataset>`),
  as ruled in `BarkparkWeb.Plugs.RequireShareScope` (task-8627e1a3f974693d).
  This file proves the whole delivery surface a site uses behind that one
  opt-in, with files created through the real upload path:

    * originals, on-demand transforms, named renditions, and the Sanity image
      and file routes answer 403 without the share and 200 with it, with a
      public `Cache-Control`, a strong `ETag` and `304` on `If-None-Match`;
    * a `bp_visibility: "private"` asset stays 403 on every one of them;
    * a watermarked asset's original stays 403 for the anonymous caller, while
      its transform (which carries the watermark) is served;
    * delivery reads the asset document whether it is stored as a draft
      (`drafts.<id>`) or published, so it does not depend on the pending
      decision about the draft state of uploads (task-9ca3b4c6c58839cc);
    * writes still need membership: an anonymous upload, patch or delete on
      the shared scope is refused.
  """
  use BarkparkWeb.ConnCase, async: false

  # The media plugin owns mediaAsset, its upload hook and the media routes.
  @moduletag :requires_plugins

  import Barkpark.TenancyFixtures
  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Media, Repo}
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Media.Assets

  @project_id "abc123de"
  @dataset "production"

  setup do
    ws = create_workspace!()
    proj = create_project!(ws)
    Barkpark.SharingFixtures.plant_shares!("")

    raw = "public-media-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Auth.create_token(raw, "public-media", @dataset, ["read", "write", "admin"], ws.id)

    ctx = %{ws: ws, proj: proj, raw: raw, base: "/w/#{ws.slug}/p/#{proj.slug}"}
    image = upload(ctx, jpeg(), "photo.jpg", "image/jpeg", %{"sourceId" => sanity_id(:image)})
    pdf = upload(ctx, pdf(), "doc.pdf", "application/pdf", %{"sourceId" => sanity_id(:file)})

    Map.merge(ctx, %{image: image, pdf: pdf})
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp as(raw), do: scoped_conn() |> put_req_header("authorization", "Bearer #{raw}")
  defp anon, do: scoped_conn()

  defp jpeg do
    {:ok, image} = Image.new(60, 40, color: [200, 30, 30])
    path = Path.join(System.tmp_dir!(), "public-media-#{System.unique_integer([:positive])}.jpg")
    {:ok, _} = Image.write(image, path, quality: 90)
    path
  end

  defp pdf do
    path = Path.join(System.tmp_dir!(), "public-media-#{System.unique_integer([:positive])}.pdf")
    File.write!(path, "%PDF-1.4\n% public media #{System.unique_integer([:positive])}\n%%EOF\n")
    path
  end

  # One sha per test run, so the two Sanity ids never collide across tests.
  defp sanity_sha(kind) do
    key = {__MODULE__, kind}

    case Process.get(key) do
      nil ->
        sha = :crypto.strong_rand_bytes(20) |> Base.encode16(case: :lower)
        Process.put(key, sha)
        sha

      sha ->
        sha
    end
  end

  defp sanity_id(:image), do: "image-#{sanity_sha(:image)}-60x40-jpg"
  defp sanity_id(:file), do: "file-#{sanity_sha(:file)}-pdf"

  defp upload(ctx, path, filename, content_type, extra) do
    file = %Plug.Upload{path: path, filename: filename, content_type: content_type}

    resp =
      as(ctx.raw)
      |> post("#{ctx.base}/v1/media/#{@dataset}/upload", Map.put(extra, "file", file))

    assert resp.status in [200, 201], resp.resp_body
    result = json_response(resp, resp.status)["result"]

    on_exit(fn ->
      File.rm(Path.join(Media.upload_dir(), result["path"]))
      Media.Renditions.delete_for_file(result["id"])
      Assets.delete_for_blob(result["id"], @dataset)
    end)

    result
  end

  defp publish_media!(ctx) do
    resp =
      as(ctx.raw)
      |> post("/v1/shares/media", %{"scope" => "#{ctx.ws.slug}/#{ctx.proj.slug}/#{@dataset}"})

    assert json_response(resp, 201)["share"]["surfaces"] == ["media"]
  end

  defp patch_asset!(ctx, file, body) do
    resp = as(ctx.raw) |> patch("#{ctx.base}/v1/media/#{@dataset}/#{file["id"]}", body)
    assert resp.status == 200, resp.resp_body
  end

  defp asset_doc(file) do
    Repo.one!(
      from(d in Document,
        where:
          d.type == "mediaAsset" and fragment("?->>'mediaFileId' = ?", d.content, ^file["id"])
      )
    )
  end

  # Every anonymous URL a website uses for the image.
  defp image_urls(ctx) do
    sha = sanity_sha(:image)

    [
      original: "#{ctx.base}/media/files/#{ctx.image["path"]}",
      transform: "#{ctx.base}/media/files/#{ctx.image["path"]}?w=30",
      rendition: "#{ctx.base}/media/renditions/#{ctx.image["id"]}/thumb",
      sanity_image: "#{ctx.base}/images/#{@project_id}/#{@dataset}/#{sha}-60x40.jpg",
      sanity_transform: "#{ctx.base}/images/#{@project_id}/#{@dataset}/#{sha}-60x40.jpg?w=30"
    ]
  end

  defp sanity_file_url(ctx),
    do: "#{ctx.base}/files/#{@project_id}/#{@dataset}/#{sanity_sha(:file)}.pdf"

  defp statuses(urls),
    do: Map.new(urls, fn {name, url} -> {name, anon() |> get(url) |> Map.get(:status)} end)

  # ── the opt-in ─────────────────────────────────────────────────────────

  describe "without the :media share" do
    test "every anonymous media URL answers 403, and a member still reads them", ctx do
      expected = Map.new(image_urls(ctx), fn {name, _} -> {name, 403} end)
      assert statuses(image_urls(ctx)) == expected
      assert anon() |> get(sanity_file_url(ctx)) |> Map.get(:status) == 403

      for {name, url} <- image_urls(ctx) do
        assert as(ctx.raw) |> get(url) |> Map.get(:status) == 200, "member #{name}"
      end
    end
  end

  describe "with the :media share" do
    setup ctx do
      publish_media!(ctx)
      :ok
    end

    test "originals, transforms, renditions and the Sanity routes answer 200", ctx do
      expected = Map.new(image_urls(ctx), fn {name, _} -> {name, 200} end)
      assert statuses(image_urls(ctx)) == expected

      file = anon() |> get(sanity_file_url(ctx))
      assert file.status == 200
      assert file.resp_body =~ "%PDF-1.4"
    end

    test "anonymous responses are publicly cacheable and revalidate to 304", ctx do
      urls = image_urls(ctx)

      for {name, url} <- urls do
        resp = anon() |> get(url)
        assert [cache] = get_resp_header(resp, "cache-control"), "#{name}"
        assert String.starts_with?(cache, "public, max-age="), "#{name}: #{cache}"
        assert [etag] = get_resp_header(resp, "etag"), "#{name}"

        again = anon() |> put_req_header("if-none-match", etag) |> get(url)
        assert again.status == 304, "#{name}"
      end

      assert get_resp_header(anon() |> get(urls[:transform]), "cache-control") ==
               ["public, max-age=2592000"]

      assert get_resp_header(anon() |> get(urls[:original]), "cache-control") ==
               ["public, max-age=86400, must-revalidate"]
    end

    test "a private asset stays 403 on every URL", ctx do
      patch_asset!(ctx, ctx.image, %{"bp_visibility" => "private"})
      patch_asset!(ctx, ctx.pdf, %{"bp_visibility" => "private"})

      expected = Map.new(image_urls(ctx), fn {name, _} -> {name, 403} end)
      assert statuses(image_urls(ctx)) == expected
      assert anon() |> get(sanity_file_url(ctx)) |> Map.get(:status) == 403
    end

    test "a token-visibility asset stays 403 for an anonymous caller", ctx do
      patch_asset!(ctx, ctx.image, %{"bp_visibility" => "token"})

      for {name, url} <- image_urls(ctx), name != :rendition do
        assert anon() |> get(url) |> Map.get(:status) == 403, "#{name}"
      end
    end

    test "a watermarked asset's clean original stays 403; its transform is served", ctx do
      urls = image_urls(ctx)
      clean = anon() |> get(urls[:transform])
      assert clean.status == 200

      patch_asset!(ctx, ctx.image, %{"rights" => %{"watermarkProfile" => "draft"}})

      assert anon() |> get(urls[:original]) |> Map.get(:status) == 403
      assert anon() |> get(urls[:sanity_image]) |> Map.get(:status) == 403
      marked = anon() |> get(urls[:transform])
      assert marked.status == 200
      refute marked.resp_body == clean.resp_body, "the transform carries the watermark"
      assert anon() |> get(urls[:sanity_transform]) |> Map.get(:status) == 200

      # A member keeps the original.
      assert as(ctx.raw) |> get(urls[:original]) |> Map.get(:status) == 200
    end

    test "delivery does not depend on whether the asset document is a draft", ctx do
      doc = asset_doc(ctx.image)
      bare = String.replace_prefix(doc.doc_id, "drafts.", "")
      urls = image_urls(ctx)

      for doc_id <- ["drafts." <> bare, bare] do
        doc = asset_doc(ctx.image)
        doc |> Ecto.Changeset.change(doc_id: doc_id) |> Repo.update!()

        assert anon() |> get(urls[:original]) |> Map.get(:status) == 200, doc_id
        assert anon() |> get(urls[:sanity_transform]) |> Map.get(:status) == 200, doc_id
      end

      asset_doc(ctx.image)
      |> Ecto.Changeset.change(
        content: Map.put(asset_doc(ctx.image).content, "bp_visibility", "private")
      )
      |> Repo.update!()

      for doc_id <- ["drafts." <> bare, bare] do
        asset_doc(ctx.image) |> Ecto.Changeset.change(doc_id: doc_id) |> Repo.update!()
        assert anon() |> get(urls[:original]) |> Map.get(:status) == 403, doc_id
        assert anon() |> get(urls[:transform]) |> Map.get(:status) == 403, doc_id
      end
    end

    test "writes on the shared scope still need membership", ctx do
      upload = %Plug.Upload{path: jpeg(), filename: "anon.jpg", content_type: "image/jpeg"}

      up = anon() |> post("#{ctx.base}/v1/media/#{@dataset}/upload", %{"file" => upload})
      assert up.status in [401, 403], up.resp_body

      patched =
        anon()
        |> patch("#{ctx.base}/v1/media/#{@dataset}/#{ctx.image["id"]}", %{"title" => "x"})

      assert patched.status in [401, 403], patched.resp_body

      deleted = anon() |> delete("#{ctx.base}/v1/media/#{@dataset}/#{ctx.image["id"]}")
      assert deleted.status in [401, 403], deleted.resp_body

      # The file is untouched and still served.
      assert anon() |> get(image_urls(ctx)[:original]) |> Map.get(:status) == 200
    end

    test "the share covers its own dataset only", ctx do
      sha = sanity_sha(:image)
      other = "#{ctx.base}/images/#{@project_id}/staging/#{sha}-60x40.jpg"
      status = anon() |> get(other) |> Map.get(:status)
      assert status in [403, 404]
    end
  end
end
