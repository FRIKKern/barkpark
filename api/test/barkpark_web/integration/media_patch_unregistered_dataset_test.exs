defmodule BarkparkWeb.Integration.MediaPatchUnregisteredDatasetTest do
  @moduledoc """
  task-8ddfc18c98283581: PATCH /v1/media/:dataset/:id 404s "document not
  found" for an asset uploaded into a dataset that has never had the
  `mediaAsset` schema registered — e.g. a fresh dataset slug a scoped
  upload mints on first use via `Tenancy.get_or_create_dataset/2` (an e2e/CI
  dataset, or any dataset nobody has run `Bootstrap.register_all_schemas/0`
  against). Repro used the CLI's own route shape: token auth (not an
  account session), scoped under `/w/:ws/p/:proj/v1/media/:dataset`.

  Root cause: `Media.patch_asset_metadata/3` gated on
  `Content.get_schema(@asset_type, dataset)` without ever reading the
  result — a pure existence check — while the CREATE path
  (`Assets.ensure_for_upload/1` -> `create_draft/1`) calls
  `Content.create_document/4` directly and asks for no schema at all. So an
  asset could be uploaded into an unregistered dataset but never have its
  metadata edited afterward, even though the asset document it names
  resolves fine.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Media}

  @ds "e2e-freeform-patch-repro"
  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  setup %{conn: conn} do
    ws = create_workspace!("tok-media-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")
    ensure_default_scope!()

    raw = "tok-media-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "tok writer", @ds, ["read", "write"], ws.id)

    conn = put_req_header(conn, "authorization", "Bearer " <> raw)
    {:ok, conn: conn, ws: ws, proj: proj}
  end

  defp png_upload do
    png_bin = Base.decode64!(@png_b64)
    tmp_path = Path.join(System.tmp_dir!(), "tok-media-#{:rand.uniform(1_000_000)}.png")
    File.write!(tmp_path, png_bin)
    %Plug.Upload{path: tmp_path, filename: "pixel.png", content_type: "image/png"}
  end

  test "an asset uploaded into a never-schema-registered dataset still accepts a metadata PATCH",
       %{conn: conn, ws: ws, proj: proj} do
    upload =
      conn
      |> put_req_header("x-requested-with", "bp-media-picker")
      |> post("/w/#{ws.slug}/p/#{proj.slug}/v1/media/#{@ds}/upload", %{"file" => png_upload()})

    assert upload.status in [200, 201], "upload failed: #{upload.status} #{upload.resp_body}"
    file_id = Jason.decode!(upload.resp_body)["result"]["id"]
    assert is_binary(file_id), "no file id: #{upload.resp_body}"

    on_exit(fn ->
      case Media.get_file(file_id, []) do
        {:ok, file} -> File.rm(Path.join(Media.upload_dir(), file.path))
        _ -> :ok
      end
    end)

    # The precondition the bug depends on: this dataset genuinely has no
    # mediaAsset schema registered (never asserted blindly as a given).
    assert Barkpark.Content.get_schema("mediaAsset", @ds) == {:error, :not_found}

    patched =
      conn
      |> put_req_header("x-requested-with", "bp-media-picker")
      |> patch("/w/#{ws.slug}/p/#{proj.slug}/v1/media/#{@ds}/#{file_id}", %{
        "altText" => "renamed by a token"
      })

    assert patched.status == 200,
           "PATCH refused: #{patched.status} #{patched.resp_body}"

    {:ok, file} = Media.get_file(file_id, workspace_id: ws.id, project_id: proj.id)
    asset_doc = Media.asset_doc_for_file(file, @ds, Media.Storage.MediaFile.scope_opts(file))
    assert asset_doc.content["altText"] == "renamed by a token"
  end
end
