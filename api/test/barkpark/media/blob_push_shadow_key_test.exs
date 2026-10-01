defmodule Barkpark.Media.BlobPushShadowKeyTest do
  @moduledoc """
  r2-lane-c authz sweep (2026-10-01): `Media.put_blob/3`'s ownership check
  (`authorize_blob_key/2`) asked only "does any row's PATH equal this key?".
  Since task-8eb6542ece62aff1 a second claimant of a flat path stores its bytes
  at a tenant SHADOW object key, `d/<its dataset_id>/<path>`, which no row
  holds as its `path`. So a third workspace pushing to that shadow key found it
  "unclaimed" and wrote straight onto another tenant's object.

  A key a FOREIGN row holds as its stored `object_key` is now owned too:
  `:blob_key_not_owned`. Controls: the shadow's owner still reads its own
  bytes, and a genuinely unclaimed key is still writable (the bundle-import seam).
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Media
  alias Barkpark.Media.Blobstore
  alias Barkpark.Media.Storage.{MediaFile, ObjectKey}
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  defp tenant!(base) do
    slug = "#{base}-#{System.unique_integer([:positive])}"
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug, name: slug})
    {:ok, project} = Tenancy.create_project(ws, %{slug: slug <> "-p", name: slug})
    {:ok, dataset} = Tenancy.get_or_create_dataset(project.id, "production")
    %{ws: ws, project: project, dataset: dataset}
  end

  defp claim!(t, path, bytes) do
    row =
      %MediaFile{}
      |> MediaFile.changeset(%{
        filename: Path.basename(path),
        original_name: Path.basename(path),
        path: path,
        mime_type: "image/png",
        size: byte_size(bytes),
        dataset: "production",
        workspace_id: t.ws.id,
        project_id: t.project.id,
        dataset_id: t.dataset.id
      })
      |> Repo.insert!()

    on_exit(fn -> Blobstore.delete(row) end)
    {:ok, _, _} = Media.put_blob(path, bytes, workspace_id: t.ws.id)
    row
  end

  defp stored_bytes(%MediaFile{} = row) do
    File.read!(Media.file_path(ObjectKey.for_row(row)))
  end

  test "a third workspace cannot write onto another tenant's shadow object key" do
    a = tenant!("bpsk-a")
    b = tenant!("bpsk-b")
    c = tenant!("bpsk-c")
    shared = "2026/10/shadow-#{System.unique_integer([:positive])}.png"

    _row_a = claim!(a, shared, "BYTES-A")
    row_b = claim!(b, shared, "BYTES-B")
    shadow = ObjectKey.for_row(row_b)
    assert shadow != shared, "precondition: B's bytes live at a tenant shadow key"

    assert {:error, :blob_key_not_owned} =
             Media.put_blob(shadow, "EVIL-FROM-C", workspace_id: c.ws.id)

    assert stored_bytes(row_b) == "BYTES-B",
           "the shadow object was overwritten by a workspace that owns no row there"
  end

  test "CONTROL: a key no row claims, by path or object key, is still writable" do
    c = tenant!("bpsk-free")
    free = "2026/10/unclaimed-#{System.unique_integer([:positive])}.png"
    on_exit(fn -> File.rm(Media.file_path(free)) end)

    assert {:ok, ^free, _} = Media.put_blob(free, "FREE", workspace_id: c.ws.id)
  end
end
