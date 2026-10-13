defmodule BarkparkWeb.Integration.MediaDeleteScopedRefGuardTest do
  @moduledoc """
  task-fe13ea62be4a69e6 — the structural `_ref` delete guard (#22427) on the
  route Studio actually uses: a WORKSPACE-scoped upload into a non-production
  dataset, then a scoped `DELETE`.

  #22427's own tests (`media_delete_ref_field_gap_test.exs`) build the blob on
  the flat route in the Default scope, so they never met the live failure on
  guerrilla: workspace studio-parity, dataset e2e-freeform, `DELETE` answered
  200 while a draft and a published post held the asset by bare `asset-…`
  `_ref`. `WhereUsed.structural_referrers/1` called
  `Content.Query.list_reference_holders/3` with NO tenancy opts, so the
  backlinks read resolved the dataset against the Default project, found its
  same-named dataset, and filtered both the schema catalog and the documents
  to THAT dataset id: no schema, no referrers, 200.

  Everything here goes through HTTP the way a Studio client does — the upload
  (whose `assetDocId` is a DRAFT `drafts.asset-…` id) and the delete — and the
  referrers hold the asset by its BARE id, as the image/file picker writes it.
  The Default project carries a dataset of the same name, as guerrilla's does.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content, Media, Tenancy}
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  @ds "e2e-freeform-delete-ref"
  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="
  @pdf "%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n"

  setup %{conn: conn} do
    ws = create_workspace!("media-ref-guard-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")
    {_default_ws, default_proj} = ensure_default_scope!()

    # Guerrilla's shape: the Default project has a dataset of the SAME name.
    {:ok, _} = Tenancy.get_or_create_dataset(default_proj, @ds)

    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "mainImage", "type" => "image"},
            %{"name" => "attachment", "type" => "file"}
          ]
        },
        @ds,
        scope
      )

    raw = "media-ref-guard-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "member", @ds, ["read", "write"], ws.id)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("x-requested-with", "bp-media-picker")

    {:ok, conn: conn, ws: ws, proj: proj, scope: scope}
  end

  defp base(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/v1/media/#{@ds}"

  defp upload!(conn, ws, proj, filename, content_type, bytes) do
    tmp = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-#{filename}")
    File.write!(tmp, bytes)
    upload = %Plug.Upload{path: tmp, filename: filename, content_type: content_type}

    resp = post(conn, base(ws, proj) <> "/upload", %{"file" => upload})
    assert resp.status in [200, 201], "upload failed: #{resp.status} #{resp.resp_body}"
    result = Jason.decode!(resp.resp_body)["result"]

    on_exit(fn ->
      case Repo.get(MediaFile, result["id"]) do
        %MediaFile{path: path} when is_binary(path) ->
          File.rm(Path.join(Media.upload_dir(), path))

        _ ->
          :ok
      end
    end)

    # The live precondition: the companion asset doc exists only as a draft.
    assert "drafts.asset-" <> _ = result["assetDocId"]
    {result["id"], Content.published_id(result["assetDocId"])}
  end

  defp png, do: Base.decode64!(@png_b64)

  test "a draft and a published post holding bare asset-… refs block an unforced scoped delete (409, both named)",
       %{conn: conn, ws: ws, proj: proj, scope: scope} do
    {png_id, png_ref} = upload!(conn, ws, proj, "pixel.png", "image/png", png())
    {pdf_id, pdf_ref} = upload!(conn, ws, proj, "doc.pdf", "application/pdf", @pdf)
    refute String.starts_with?(png_ref, "drafts.")

    {:ok, draft} =
      Content.create_document(
        "post",
        %{
          "title" => "draft referrer",
          "mainImage" => %{
            "_type" => "image",
            "asset" => %{"_type" => "reference", "_ref" => png_ref}
          },
          "attachment" => %{"_type" => "file", "asset" => %{"_ref" => pdf_ref}}
        },
        @ds,
        scope
      )

    {:ok, pub_draft} =
      Content.create_document(
        "post",
        %{"title" => "published referrer", "mainImage" => %{"asset" => %{"_ref" => png_ref}}},
        @ds,
        scope
      )

    {:ok, published} = Content.publish_document(pub_draft.doc_id, "post", @ds, scope)

    png_body = conn |> delete(base(ws, proj) <> "/#{png_id}") |> json_response(409)
    assert Repo.get(MediaFile, png_id), "the guard answered 409 but the PNG row is gone"
    assert png_body["error"]["details"]["referencedByCount"] == 2

    png_referrers = Enum.map(png_body["error"]["details"]["referencedBy"], & &1["doc_id"])
    assert draft.doc_id in png_referrers, "draft referrer not named: #{inspect(png_referrers)}"

    assert published.doc_id in png_referrers,
           "published referrer not named: #{inspect(png_referrers)}"

    pdf_body = conn |> delete(base(ws, proj) <> "/#{pdf_id}") |> json_response(409)
    assert Repo.get(MediaFile, pdf_id), "the guard answered 409 but the PDF row is gone"
    assert [%{"doc_id" => doc_id}] = pdf_body["error"]["details"]["referencedBy"]
    assert doc_id == draft.doc_id
  end

  test "a field that stores the upload's drafts.asset-… id verbatim also blocks the delete",
       %{conn: conn, ws: ws, proj: proj, scope: scope} do
    {png_id, png_ref} = upload!(conn, ws, proj, "pixel.png", "image/png", png())
    {pdf_id, pdf_ref} = upload!(conn, ws, proj, "doc.pdf", "application/pdf", @pdf)

    {:ok, draft} =
      Content.create_document(
        "post",
        %{
          "title" => "draft-id referrer",
          "mainImage" => %{"asset" => %{"_ref" => Content.draft_id(png_ref)}},
          "attachment" => %{"asset" => %{"_ref" => Content.draft_id(pdf_ref)}}
        },
        @ds,
        scope
      )

    for id <- [png_id, pdf_id] do
      body = conn |> delete(base(ws, proj) <> "/#{id}") |> json_response(409)
      assert [%{"doc_id" => doc_id}] = body["error"]["details"]["referencedBy"]
      assert doc_id == draft.doc_id
      assert Repo.get(MediaFile, id)
    end
  end

  test "?force=true still deletes a referenced asset, and says it was forced",
       %{conn: conn, ws: ws, proj: proj, scope: scope} do
    {png_id, png_ref} = upload!(conn, ws, proj, "pixel.png", "image/png", png())

    {:ok, _} =
      Content.create_document(
        "post",
        %{"title" => "referrer", "mainImage" => %{"asset" => %{"_ref" => png_ref}}},
        @ds,
        scope
      )

    body = conn |> delete(base(ws, proj) <> "/#{png_id}?force=true") |> json_response(200)
    assert body["result"]["deleted"] == png_id
    assert body["result"]["forced"] == true
    assert body["result"]["referencedByCount"] == 1
    refute Repo.get(MediaFile, png_id)
  end

  test "an unreferenced asset still deletes with a plain 200", %{conn: conn, ws: ws, proj: proj} do
    {png_id, _png_ref} = upload!(conn, ws, proj, "pixel.png", "image/png", png())

    body = conn |> delete(base(ws, proj) <> "/#{png_id}") |> json_response(200)
    assert body["result"]["deleted"] == png_id
    refute Map.has_key?(body["result"], "forced")
    refute Repo.get(MediaFile, png_id)
  end
end
