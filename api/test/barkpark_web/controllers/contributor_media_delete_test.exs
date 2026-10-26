defmodule BarkparkWeb.ContributorMediaDeleteTest do
  @moduledoc """
  task-166a84a8502afbc5: a `contributor` (draft-only) seat may not change what
  readers see, so it may not delete a media file whose `mediaAsset` document
  is published, nor force-delete a file live documents still show. Both media
  delete doors (`DELETE /v1/media/:ds/:id` and the legacy `DELETE /media/:id`)
  ran the asset doc's delete without the caller's context, so the seat gate
  passed. A member deletes as before; a contributor still deletes a file whose
  asset is a draft and nothing references.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Media, Repo, TenancyFixtures}
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Tenancy.Membership

  @dataset "production"
  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  setup do
    ws_id = TenancyFixtures.default_workspace_id!()

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "cmd_note",
          "title" => "Note",
          "visibility" => "public",
          "fields" => [%{"name" => "body", "type" => "string"}]
        },
        @dataset
      )

    {:ok, ws_id: ws_id}
  end

  defp seated(ws_id, role) do
    raw = "cmd-#{role}-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "cmd #{role}", @dataset, ["read", "write"], ws_id)

    Membership
    |> Repo.get_by!(principal_id: token.id, principal_type: "api_token", workspace_id: ws_id)
    |> Ecto.Changeset.change(role: role)
    |> Repo.update!()

    raw
  end

  defp as(raw), do: scoped_conn() |> put_req_header("authorization", "Bearer " <> raw)

  defp upload!(raw) do
    tmp = Path.join(System.tmp_dir!(), "cmd-#{System.unique_integer([:positive])}.png")
    File.write!(tmp, Base.decode64!(@png_b64) <> "#{System.unique_integer([:positive])}")
    upload = %Plug.Upload{path: tmp, filename: "cmd.png", content_type: "image/png"}
    created = as(raw) |> post("/media/upload", %{"file" => upload}) |> json_response(201)
    on_exit(fn -> File.rm(Path.join(Media.upload_dir(), created["path"])) end)
    Repo.get!(MediaFile, created["id"])
  end

  defp publish_asset!(%MediaFile{} = file) do
    scope = MediaFile.scope_opts(file)
    asset = Media.asset_doc_for_file(file, file.dataset, scope)
    pub = Content.published_id(asset.doc_id)
    {:ok, _} = Content.publish_document(pub, "mediaAsset", file.dataset, scope)
    pub
  end

  defp asset_published?(pub, file),
    do:
      match?(
        {:ok, %{doc_id: ^pub}},
        Content.get_document(pub, "mediaAsset", file.dataset, MediaFile.scope_opts(file))
      )

  defp refused!(conn) do
    body = json_response(conn, 403)
    assert body["error"]["reason"] == "publish_not_permitted", inspect(body)
  end

  test "a contributor may not delete a file whose asset is published, on either door", %{
    ws_id: ws_id
  } do
    member = seated(ws_id, "member")
    contributor = seated(ws_id, "contributor")

    for path <- [&"/v1/media/#{@dataset}/#{&1}", &"/media/#{&1}"] do
      file = upload!(member)
      pub = publish_asset!(file)

      refused!(as(contributor) |> delete(path.(file.id)))
      assert Repo.get(MediaFile, file.id), "the blob row was deleted"
      assert asset_published?(pub, file), "the published asset was deleted"
    end
  end

  test "a contributor may not force-delete a file a document still shows", %{ws_id: ws_id} do
    member = seated(ws_id, "member")
    contributor = seated(ws_id, "contributor")
    file = upload!(member)

    {:ok, _} =
      Content.create_document("cmd_note", %{"body" => "see /media/files/#{file.path}"}, @dataset)

    # Unforced, the where-used guard answers 409 for anyone, as before.
    assert (as(contributor) |> delete("/v1/media/#{@dataset}/#{file.id}")).status == 409
    refused!(as(contributor) |> delete("/v1/media/#{@dataset}/#{file.id}?force=true"))
    assert Repo.get(MediaFile, file.id)
  end

  test "a member still deletes a published-asset file; a contributor a draft-only one", %{
    ws_id: ws_id
  } do
    member = seated(ws_id, "member")
    contributor = seated(ws_id, "contributor")

    published = upload!(member)
    publish_asset!(published)
    assert json_response(as(member) |> delete("/v1/media/#{@dataset}/#{published.id}"), 200)
    refute Repo.get(MediaFile, published.id)

    draft_only = upload!(contributor)
    assert json_response(as(contributor) |> delete("/v1/media/#{@dataset}/#{draft_only.id}"), 200)
    refute Repo.get(MediaFile, draft_only.id)
  end
end
