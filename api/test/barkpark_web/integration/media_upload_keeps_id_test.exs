defmodule BarkparkWeb.Integration.MediaUploadKeepsIdTest do
  @moduledoc """
  task-fa5aedea4a584d34. A gyl to staging copy uploaded each of 1,307 media
  files again: every file got a new asset id, byte duplicates merged into one
  asset, and content that referenced `asset-<id>` broke. `mediaFileId` on the
  upload lets the copy keep each id. It is off unless sent.
  """
  use BarkparkWeb.ConnCase, async: false

  # Plugins-off: the media plugin owns mediaAsset, its upload hook and routes.
  @moduletag :requires_plugins

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content, Media, Repo}
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Plugins.Media.Assets

  setup do
    ws = create_workspace!()
    proj = create_project!(ws)
    raw = "keep-id-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "keep-id", "production", ["read", "write"], ws.id)
    %{ws: ws, raw: raw, base: "/w/#{ws.slug}/p/#{proj.slug}"}
  end

  defp pdf(text) do
    path = Path.join(System.tmp_dir!(), "keep-id-#{System.unique_integer([:positive])}.pdf")
    File.write!(path, "%PDF-1.4\n% #{text}\n%%EOF\n")
    path
  end

  defp upload(ctx, path, extra) do
    file = %Plug.Upload{path: path, filename: "doc.pdf", content_type: "application/pdf"}

    resp =
      build_conn()
      |> put_req_header("authorization", "Bearer #{ctx.raw}")
      |> post("#{ctx.base}/v1/media/production/upload", Map.put(extra, "file", file))

    body = Jason.decode!(resp.resp_body)

    with %{"result" => %{"id" => id, "path" => p}} <- body do
      on_exit(fn ->
        File.rm(Path.join(Media.upload_dir(), p))
        Assets.delete_for_blob(id, "production")
      end)
    end

    {resp.status, body}
  end

  test "an upload with mediaFileId keeps that id, and its asset document follows", ctx do
    id = Ecto.UUID.generate()
    {status, body} = upload(ctx, pdf("one"), %{"mediaFileId" => id})

    assert status == 201
    assert body["result"]["id"] == id
    assert body["result"]["assetDocId"] in ["asset-#{id}", "drafts.asset-#{id}"]
    assert %MediaFile{workspace_id: ws_id} = Repo.get!(MediaFile, id)
    assert ws_id == ctx.ws.id

    assert {:ok, _} =
             Content.get_document("drafts.asset-#{id}", "mediaAsset", "production",
               workspace_id: ctx.ws.id
             )
  end

  test "byte duplicates keep their own ids", ctx do
    path = pdf("same bytes")
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()

    assert {201, %{"result" => %{"id" => ^a}}} = upload(ctx, path, %{"mediaFileId" => a})
    assert {201, %{"result" => %{"id" => ^b}}} = upload(ctx, path, %{"mediaFileId" => b})
  end

  test "a re-run answers with the same file, and other bytes on that id are a conflict", ctx do
    id = Ecto.UUID.generate()
    path = pdf("rerun")

    assert {201, _} = upload(ctx, path, %{"mediaFileId" => id})

    assert {200, %{"existing" => true, "result" => %{"id" => ^id}}} =
             upload(ctx, path, %{"mediaFileId" => id})

    assert {409, %{"error" => %{"code" => "conflict"}}} =
             upload(ctx, pdf("other bytes"), %{"mediaFileId" => id})
  end

  test "a mediaFileId that is not a UUID is refused", ctx do
    assert {422, %{"error" => %{"code" => "validation_failed"}}} =
             upload(ctx, pdf("bad"), %{"mediaFileId" => "not-a-uuid"})
  end
end
