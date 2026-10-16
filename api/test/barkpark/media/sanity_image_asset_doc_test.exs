defmodule Barkpark.Media.SanityImageAssetDocTest do
  @moduledoc """
  task-b3e57f301bd502d8: a Sanity-shaped image value whose `asset._ref` is a
  Sanity image id with no `sanityImageAsset` document gets one, so GROQ
  `asset->url` and `asset->metadata.dimensions` resolve.

  On main nothing created the document: an upload saved
  `image-<sha1>-<w>x<h>-<ext>`, Barkpark served the bytes, and `asset->` was
  null.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Groq, Media, TenancyFixtures}
  alias Barkpark.Media.SanityImageAssetDoc

  import Barkpark.SanityImageFixtures

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_asset_schema!(scope)
    %{ws: ws, project: project, scope: scope}
  end

  defp register_asset_schema!(scope) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "sanityImageAsset",
          "title" => "Bilde fra Sanity",
          "visibility" => "public",
          "fields" => [
            %{"name" => "originalFilename", "type" => "string"},
            %{"name" => "mimeType", "type" => "string"},
            %{"name" => "extension", "type" => "string"},
            %{"name" => "size", "type" => "number"},
            %{"name" => "sha1hash", "type" => "string"},
            %{"name" => "metadata", "type" => "json"},
            %{"name" => "url", "type" => "url"},
            %{"name" => "mediaFileId", "type" => "string"},
            %{"name" => "barkparkUrl", "type" => "url"}
          ]
        },
        @dataset,
        scope
      )
  end

  defp groq(query, scope) do
    {:ok, %{result_json: json}} =
      Groq.query(query, %{}, dataset: @dataset, perspective: :published, scope_opts: scope)

    json |> IO.iodata_to_binary() |> Jason.decode!()
  end

  defp asset_doc(id, scope) do
    case Content.get_document(id, "sanityImageAsset", @dataset, scope) do
      {:ok, doc} -> doc
      _ -> nil
    end
  end

  test "a fresh upload's Sanity id gets a published asset document that asset-> follows", %{
    scope: scope
  } do
    file = upload!(scope)
    id = "image-#{file.sha1}-3x2-png"
    assert Media.ImageMetadata.sanity_image_id(file.id, @dataset, scope) == id

    assert SanityImageAssetDoc.ensure([id], @dataset, [source: :studio] ++ scope) == [id]

    doc = asset_doc(id, scope)
    assert doc.status == "published"
    c = doc.content
    assert c["originalFilename"] == "omslag.png"
    assert c["mimeType"] == "image/png"
    assert c["extension"] == "png"
    assert c["size"] == byte_size(png())
    assert c["sha1hash"] == file.sha1
    assert c["mediaFileId"] == file.id

    # The upload's own blur placeholder, when processing stored one.
    case Media.asset_doc_for_file(file, @dataset, scope) do
      %{content: %{"fileInfo" => %{"lqip" => "data:" <> _ = lqip}}} ->
        assert c["metadata"]["lqip"] == lqip

      _ ->
        :ok
    end

    assert c["metadata"]["dimensions"] == %{
             "_type" => "sanity.imageDimensions",
             "width" => 3,
             "height" => 2,
             "aspectRatio" => 1.5
           }

    assert c["url"] =~ ~r"/w/[^/]+/p/[^/]+/images/[^/]+/production/#{file.sha1}-3x2\.png\z"
    assert String.starts_with?(c["url"], "http")
    assert c["barkparkUrl"] =~ "/media/files/#{file.path}"

    # The same read the twin site makes.
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    hero = %{"_type" => "image", "asset" => %{"_type" => "reference", "_ref" => id}}

    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "hero-post", "title" => "Hero", "heroImage" => hero},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("hero-post", "post", @dataset, scope)

    out =
      groq(
        ~s(*[_id == "hero-post"][0]{"url": heroImage.asset->url, "dims": heroImage.asset->metadata.dimensions}),
        scope
      )

    assert out["url"] == c["url"]
    assert out["dims"]["width"] == 3
    assert out["dims"]["height"] == 2
  end

  test "a second call writes nothing and keeps the document's revision", %{scope: scope} do
    file = upload!(scope)
    id = "image-#{file.sha1}-3x2-png"

    assert SanityImageAssetDoc.ensure([id], @dataset, scope) == [id]
    rev = asset_doc(id, scope).rev

    assert SanityImageAssetDoc.ensure([id], @dataset, scope) == []
    assert asset_doc(id, scope).rev == rev
  end

  test "an imported asset document is never rewritten", %{scope: scope} do
    file = upload!(scope)
    sanity_id = "image-2c0e969890ba48060d4d04f63bc620a7b3aee181-2048x1366-jpg"
    {:ok, _} = Media.set_source_id(file, sanity_id)

    imported = %{
      "_id" => sanity_id,
      "_type" => "sanityImageAsset",
      "url" => "https://gyl.example.test/images/zl2pw2j0/production/2c0e9698-2048x1366.jpg",
      "metadata" => %{"lqip" => "data:image/jpeg;base64,AAAA", "palette" => %{"x" => 1}}
    }

    {:ok, _} =
      Content.apply_mutations(
        [%{"createOrReplace" => imported, "publish" => true}],
        @dataset,
        scope
      )

    before = asset_doc(sanity_id, scope)
    assert SanityImageAssetDoc.ensure([sanity_id], @dataset, scope) == []
    after_doc = asset_doc(sanity_id, scope)
    assert after_doc.rev == before.rev
    assert after_doc.content == before.content
  end

  test "an id whose size does not match the file's bytes creates nothing", %{scope: scope} do
    file = upload!(scope)
    forged = "image-#{file.sha1}-300x200-png"

    assert SanityImageAssetDoc.ensure([forged], @dataset, scope) == []
    assert asset_doc(forged, scope) == nil
  end

  test "a workspace without the sanityImageAsset schema gets no documents" do
    ws = TenancyFixtures.create_workspace!()
    project = TenancyFixtures.create_project!(ws)
    scope = [workspace_id: ws.id, project_id: project.id]
    file = upload!(scope)
    id = "image-#{file.sha1}-3x2-png"

    assert SanityImageAssetDoc.ensure([id], @dataset, scope) == []
    assert asset_doc(id, scope) == nil
  end

  test "a file in another workspace is never described in this one", %{scope: scope} do
    other_ws = TenancyFixtures.create_workspace!()
    other_proj = TenancyFixtures.create_project!(other_ws)
    other_scope = [workspace_id: other_ws.id, project_id: other_proj.id]
    register_asset_schema!(other_scope)

    # Bytes only the other workspace holds.
    file = upload!(other_scope, png(5, 4), "hemmelig.png")
    id = "image-#{file.sha1}-5x4-png"

    assert SanityImageAssetDoc.ensure([id], @dataset, scope) == []
    assert asset_doc(id, scope) == nil
    assert asset_doc(id, other_scope) == nil
  end

  test "a caller without a workspace and project in scope creates nothing", %{scope: scope} do
    file = upload!(scope)
    id = "image-#{file.sha1}-3x2-png"

    assert SanityImageAssetDoc.ensure([id], @dataset, []) == []
    assert SanityImageAssetDoc.ensure([id], @dataset, workspace_id: scope[:workspace_id]) == []
    assert asset_doc(id, scope) == nil
  end
end
