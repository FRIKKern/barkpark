defmodule BarkparkWeb.Studio.ImageRefRowMediaTest do
  @moduledoc """
  An image stored in the reference shape, `{_type: "image", asset: {_ref:
  "image-<sha1>-<w>x<h>-<ext>"}}` with no `url` (what the desk writes where
  `CanonicalShapes` is on), is a document's media for Barkpark's own readers:
  the list rows of the old Studio and the desk (`PaneBuilder`) and search's
  `_preview.media` (`HitPreview`). Its URL is the dataset's image route under
  the reader's scope (`ImageRefUrl`).

  On 10a8d56dcc `PreviewText.url/1` read only a `url`, so the row drew no
  thumbnail for such a document.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.PreviewText
  alias Barkpark.Search.HitPreview
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.Studio.ImageRefUrl
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "production"
  @sha1 "a88ad4d7210c7ff5716cd5e9fc4ec61f2f3bb1e3"
  @ref "image-#{@sha1}-640x400-png"
  @image %{"_type" => "image", "asset" => %{"_type" => "reference", "_ref" => @ref}}

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()
    suffix = System.unique_integer([:positive])

    {:ok, ws} = Tenancy.create_workspace(%{slug: "imgref-#{suffix}", name: "Image refs"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})

    raw = "imgref-owner-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "imgref-owner", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "poster",
          "title" => "Poster",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "cover", "title" => "Cover", "type" => "image"}
          ],
          "list_preview" => %{"media" => "cover"}
        },
        @dataset,
        scope
      )

    for {id, t, content} <- [
          {"pos-ref", "Poster by reference", %{"cover" => @image}},
          {"pos-url", "Poster by url",
           %{"cover" => %{"assetId" => "a1", "url" => "/media/files/d/x/cover.jpg"}}}
        ] do
      {:ok, _} =
        Content.upsert_document(
          "poster",
          %{"doc_id" => id, "title" => t, "status" => "published", "content" => content},
          @dataset,
          Keyword.put(scope, :source, :api)
        )

      {:ok, _} = Content.publish_document(id, "poster", @dataset, scope)
    end

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    prefix = "/w/#{ws.slug}/p/#{proj.slug}"

    {:ok,
     conn: conn,
     ws: ws,
     proj: proj,
     scope: scope,
     prefix: prefix,
     src: "#{prefix}/images/barkpark/#{@dataset}/#{@sha1}-640x400.png?w=120&fit=max"}
  end

  defp row(html, doc_id) do
    [row] =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s([id="doc-#{doc_id}"]))
      |> Enum.to_list()

    LazyHTML.to_html(row)
  end

  test "the old Studio's list row draws a reference-shape image from the scope's image route",
       c do
    {:ok, _view, html} = live(c.conn, "#{c.prefix}/d/#{@dataset}/studio/poster")
    assert row(html, "pos-ref") =~ ~s(src="#{String.replace(c.src, "&", "&amp;")}")
    assert row(html, "pos-url") =~ ~s(src="/media/files/d/x/cover.jpg")
  end

  test "the desk's rows (no URL prefix, the scope's ids) carry the same URL", c do
    {:ok, schema} = Content.resolve_schema("poster", @dataset, c.scope)
    docs = Content.list_documents("poster", @dataset, [perspective: :drafts] ++ c.scope)
    media = Map.new(PaneBuilder.view_rows(docs, schema, @dataset, c.scope), &{&1.id, &1.media})

    assert media["pos-ref"] == c.src
    assert media["pos-url"] == "/media/files/d/x/cover.jpg"
  end

  test "search's _preview.media follows the reference too", c do
    docs = [%{"_id" => "pos-ref", "_type" => "poster", "title" => "P", "cover" => @image}]
    schema = fn "poster" -> %{"list_preview" => %{"media" => "cover"}} end
    ctx = %Barkpark.Content.CallerContext{principal_type: :api_token}
    image_ref = ImageRefUrl.resolver(@dataset, c.prefix)

    [hit] = HitPreview.attach(docs, @dataset, c.scope, schema, ctx, image_ref: image_ref)
    assert hit["_preview"]["media"] == c.src
  end

  test "PreviewText: a reference with no resolver, or no prefix, has no URL; a url wins", c do
    assert PreviewText.url(@image) == nil
    assert ImageRefUrl.resolver(@dataset, "") == nil
    assert PreviewText.url(@image, ImageRefUrl.resolver(@dataset, c.prefix)) == c.src
    assert PreviewText.url(%{"asset" => %{"_ref" => "asset-not-a-sanity-id"}}, & &1) == nil
    assert PreviewText.url(Map.put(@image, "url", "/x.png"), fn _ -> "/other" end) == "/x.png"
  end

  test "the prefix from scope ids needs the project to belong to the workspace", c do
    assert ImageRefUrl.prefix(nil, c.scope) == c.prefix
    other = Tenancy.get_default_workspace()
    assert ImageRefUrl.prefix(nil, workspace_id: other.id, project_id: c.proj.id) == ""
  end
end
