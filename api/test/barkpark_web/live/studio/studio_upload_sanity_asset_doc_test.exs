defmodule BarkparkWeb.Studio.StudioUploadSanityAssetDocTest do
  @moduledoc """
  task-b3e57f301bd502d8, through the Studio save path: an editor uploads an
  image into a Sanity-shaped image field and the autosave stores
  `asset._ref: "image-<sha1>-<w>x<h>-<ext>"`. The save now also creates the
  `sanityImageAsset` document with that id, so the GROQ read the twin site
  makes, `heroImage.asset->url` and `asset->metadata.dimensions`, resolves.

  On main the draft held the ref and `asset->` was null.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content, Media, TenancyFixtures}
  alias Barkpark.Content.DraftId
  alias Barkpark.SanityImageFixtures, as: Fixtures

  @dataset "production"
  @version "v2025-02-19"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for {name, fields} <- [
          {"article",
           [
             %{"name" => "title", "title" => "Title", "type" => "string"},
             %{"name" => "heroImage", "title" => "Hero", "type" => "image"}
           ]},
          {"sanityImageAsset",
           [
             %{"name" => "url", "type" => "url"},
             %{"name" => "metadata", "type" => "json"}
           ]}
        ] do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => name, "title" => name, "visibility" => "public", "fields" => fields},
          @dataset,
          scope
        )
    end

    %{ws: ws, project: project, scope: scope}
  end

  defp seed_article!(doc_id, scope) do
    {:ok, _} =
      Content.create_document(
        "article",
        %{"_id" => doc_id, "title" => "Lærelyst"},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document(doc_id, "article", @dataset, scope)
  end

  defp token!(ws, perms) do
    raw = "upload-asset-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "upload-asset", @dataset, perms, ws.id)
    raw
  end

  defp open!(raw, doc_id) do
    conn = scoped_conn() |> Plug.Test.init_test_session(%{"api_token" => raw})
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/article/#{doc_id}"))
    view
  end

  # What the picker posts after an upload: the reference shape pointing at the
  # Barkpark asset document, as the JSON string the hidden input carries.
  defp picked(file) do
    Jason.encode!(%{
      "_type" => "image",
      "asset" => %{"_type" => "reference", "_ref" => "asset-" <> file.id}
    })
  end

  defp asset_doc(id, scope) do
    case Content.get_document(id, "sanityImageAsset", @dataset, scope) do
      {:ok, doc} -> doc
      _ -> nil
    end
  end

  defp groq(raw, ws, project, query) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> raw)
    |> get("/w/#{ws.slug}/p/#{project.slug}/#{@version}/data/query/#{@dataset}", %{
      "query" => query,
      "perspective" => "drafts"
    })
    |> json_response(200)
  end

  test "an upload then save leaves an asset document that GROQ asset->url resolves", %{
    ws: ws,
    project: project,
    scope: scope
  } do
    doc_id = "art-upload-#{System.unique_integer([:positive])}"
    seed_article!(doc_id, scope)
    file = Fixtures.upload!(scope)
    want = "image-#{file.sha1}-3x2-png"

    raw = token!(ws, ["read", "write"])
    view = open!(raw, doc_id)

    render_change(view, "autosave", %{
      "doc" => %{"title" => "Lærelyst", "heroImage" => picked(file)}
    })

    {:ok, draft} = Content.get_document(DraftId.draft_id(doc_id), "article", @dataset, scope)
    assert draft.content["heroImage"]["asset"]["_ref"] == want

    asset = asset_doc(want, scope)
    assert asset, "the save created no sanityImageAsset document for #{want}"
    assert asset.status == "published"
    assert asset.content["mediaFileId"] == file.id

    body =
      groq(
        raw,
        ws,
        project,
        ~s(*[_type == "article" && _id == "#{doc_id}"][0]{"url": heroImage.asset->url, "dims": heroImage.asset->metadata.dimensions})
      )

    assert body["result"]["url"] == asset.content["url"]
    assert body["result"]["url"] =~ "/images/"
    assert %{"width" => 3, "height" => 2} = body["result"]["dims"]

    # The URL it names serves the bytes.
    path = URI.parse(body["result"]["url"]).path
    served = scoped_conn() |> put_req_header("authorization", "Bearer " <> raw) |> get(path)
    assert served.status == 200

    # Saving again writes no second document and leaves the first unchanged.
    rev = asset.rev

    render_change(view, "autosave", %{
      "doc" => %{"title" => "Lærelyst igjen", "heroImage" => picked(file)}
    })

    assert asset_doc(want, scope).rev == rev
  end

  test "a library pick of an imported image keeps its asset document unchanged", %{
    ws: ws,
    scope: scope
  } do
    doc_id = "art-pick-#{System.unique_integer([:positive])}"
    seed_article!(doc_id, scope)
    file = Fixtures.upload!(scope)
    sanity_id = "image-917cdfa94037b90600d868383cd1f27ea690b55b-1000x667-jpg"
    {:ok, file} = Media.set_source_id(file, sanity_id)

    imported = %{
      "_id" => sanity_id,
      "_type" => "sanityImageAsset",
      "url" => "https://gyl.example.test/images/zl2pw2j0/production/917cdfa9-1000x667.jpg",
      "metadata" => %{"dimensions" => %{"width" => 1000, "height" => 667}}
    }

    {:ok, _} =
      Content.apply_mutations(
        [%{"createOrReplace" => imported, "publish" => true}],
        @dataset,
        scope
      )

    before = asset_doc(sanity_id, scope)

    view = open!(token!(ws, ["read", "write"]), doc_id)
    render_change(view, "autosave", %{"doc" => %{"heroImage" => picked(file)}})

    {:ok, draft} = Content.get_document(DraftId.draft_id(doc_id), "article", @dataset, scope)
    assert draft.content["heroImage"]["asset"]["_ref"] == sanity_id

    after_doc = asset_doc(sanity_id, scope)
    assert after_doc.rev == before.rev
    assert after_doc.content == before.content
  end

  # task-7ea6f41cede5ee97, criterion 2: REPLACING the image of a field that
  # already holds Sanity's shape. The picker keeps the stored object and swaps
  # its asset (bp-media-picker.js bpSerializeAssetRefValue), so the save must
  # keep `_type` and the other keys and still leave a ref that `asset->` reads.
  test "replacing a Sanity-shaped image keeps its _type and alt and asset-> resolves", %{
    ws: ws,
    project: project,
    scope: scope
  } do
    doc_id = "art-replace-#{System.unique_integer([:positive])}"
    old_ref = "image-0123456789abcdef0123456789abcdef01234567-640x480-jpg"

    {:ok, _} =
      Content.create_document(
        "article",
        %{
          "_id" => doc_id,
          "title" => "Bytte",
          "heroImage" => %{
            "_type" => "imageAsset",
            "alt" => "Gammelt bilde",
            "caption" => "Foto: Eksempel",
            "asset" => %{"_type" => "reference", "_ref" => old_ref}
          }
        },
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document(doc_id, "article", @dataset, scope)

    file = Fixtures.upload!(scope)
    want = "image-#{file.sha1}-3x2-png"

    # What the picker writes after a new pick into that value.
    replaced =
      Jason.encode!(%{
        "_type" => "imageAsset",
        "alt" => "Gammelt bilde",
        "caption" => "Foto: Eksempel",
        "asset" => %{"_type" => "reference", "_ref" => "asset-" <> file.id}
      })

    raw = token!(ws, ["read", "write"])
    view = open!(raw, doc_id)
    render_change(view, "autosave", %{"doc" => %{"title" => "Bytte", "heroImage" => replaced}})

    {:ok, draft} = Content.get_document(DraftId.draft_id(doc_id), "article", @dataset, scope)

    assert %{
             "_type" => "imageAsset",
             "alt" => "Gammelt bilde",
             "caption" => "Foto: Eksempel",
             "asset" => %{"_type" => "reference", "_ref" => ^want}
           } = draft.content["heroImage"]

    body =
      groq(
        raw,
        ws,
        project,
        ~s(*[_type == "article" && _id == "#{doc_id}"][0]{"t": heroImage._type, "url": heroImage.asset->url, "dims": heroImage.asset->metadata.dimensions})
      )

    assert body["result"]["t"] == "imageAsset"
    assert body["result"]["url"] =~ "/images/"
    assert %{"width" => 3, "height" => 2} = body["result"]["dims"]
  end

  test "a reader who cannot write the document creates no asset document", %{
    ws: ws,
    scope: scope
  } do
    doc_id = "art-reader-#{System.unique_integer([:positive])}"
    seed_article!(doc_id, scope)
    file = Fixtures.upload!(scope)
    want = "image-#{file.sha1}-3x2-png"

    view = open!(token!(ws, ["read"]), doc_id)
    render_change(view, "autosave", %{"doc" => %{"heroImage" => picked(file)}})

    assert asset_doc(want, scope) == nil

    assert {:error, _} =
             Content.get_document(DraftId.draft_id(doc_id), "article", @dataset, scope)
  end
end
