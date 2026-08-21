defmodule Barkpark.Tenancy.WorkspaceBundleBlobPathConflictTest do
  @moduledoc """
  Bundle import must REFUSE a media blob path another workspace already owns
  (task-918106d49c62563e — the INTERIM guard).

  ## The failure mode this names

  The blob keyspace is FLAT: `Blobstore` resolves an object by the very string
  `media_files.path` holds, while `media_files` uniqueness is `(path,
  dataset_id)`. Two workspaces can therefore hold a row at ONE path, and the
  loser's own scoped `GET /w/:ws/p/:proj/media/files/*path` streams the winner's
  bytes — a silent, cross-tenant, read-side substitution the victim cannot
  repair (its push to its own row's path is refused `:blob_key_not_owned`).

  Import paths are copied VERBATIM from the source instance, so the import is
  where such a collision is CONSTRUCTED rather than chanced.

  ## Why the check has to fire at ROW-COPY time

  Push time is already where the failure surfaces: by then the rows exist and
  the loser's row points at the winner's object, so a push-time refusal
  reproduces exactly the wedged state it is meant to prevent. The guard runs
  INSIDE the import transaction, immediately after the `media_files` member's
  COPY, and rolls the whole import back — the colliding row never becomes
  visible to any reader and no blob is ever pushed.
  """

  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.WorkspaceBundle

  @collision_path "2026/08/import-collide.png"

  # Seed a workspace holding ONE media_files row at `path`, and return the
  # exported bundle plus the workspace. The row is then deleted so the import
  # below genuinely CREATES the collision rather than inheriting one.
  defp source_bundle_holding!(path) do
    ws = create_workspace!(unique("blobsrc"))
    project = create_project!(ws, unique("blobsrcp"))
    {:ok, _dataset} = Tenancy.get_or_create_dataset(project.id, "production")

    {:ok, _file} =
      create_media_file_in!(ws, project, %{path: path, filename: "collide.png"}, "production")

    {:ok, bundle} = WorkspaceBundle.export(ws.id)

    # Drop the row from the TARGET so the COPY re-creates it — the import is
    # then the actor that constructs the collision.
    Repo.query!("DELETE FROM media_files WHERE workspace_id = $1::text::uuid", [ws.id])

    {ws, bundle}
  end

  defp resident_holder!(path) do
    ws = create_workspace!(unique("blobres"))
    project = create_project!(ws, unique("blobresp"))
    {:ok, _dataset} = Tenancy.get_or_create_dataset(project.id, "production")

    {:ok, file} =
      create_media_file_in!(ws, project, %{path: path, filename: "resident.png"}, "production")

    {ws, file}
  end

  defp media_count(ws_id),
    do:
      Repo.query!("SELECT count(*) FROM media_files WHERE workspace_id = $1::text::uuid", [ws_id]).rows
      |> hd()
      |> hd()

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  describe "row-copy-time refusal" do
    test "an incoming bundle path another workspace owns is REFUSED, and the whole import rolls back" do
      {src_ws, bundle} = source_bundle_holding!(@collision_path)
      {resident_ws, resident_file} = resident_holder!(@collision_path)

      assert {:error, {:blob_path_conflict, info}} =
               WorkspaceBundle.import_bundle(bundle, mode: :merge)

      assert info.workspace_id == src_ws.id
      assert info.count >= 1
      assert @collision_path in Enum.map(info.sample, & &1.path)
      assert resident_ws.id in Enum.map(info.sample, & &1.owner_workspace_id)

      # FAIL CLOSED — the colliding row never became visible, and the resident
      # owner's row is untouched (the whole transaction rolled back).
      assert media_count(src_ws.id) == 0
      assert Repo.get!(Barkpark.Media.Storage.MediaFile, resident_file.id).path == @collision_path
    end

    test "a bundle path an UNSCOPED (workspace_id IS NULL) row owns is refused too" do
      {src_ws, bundle} = source_bundle_holding!(@collision_path)

      # The legacy layer: an unscoped row is served to EVERY tenant, so sharing
      # its key is the same substitution with a wider blast radius.
      Repo.query!(
        "INSERT INTO media_files (id, filename, original_name, path, mime_type, size, dataset, inserted_at, updated_at) " <>
          "VALUES (gen_random_uuid(), 'legacy.png', 'legacy.png', $1, 'image/png', 1, 'production', now(), now())",
        [@collision_path]
      )

      assert {:error, {:blob_path_conflict, info}} =
               WorkspaceBundle.import_bundle(bundle, mode: :merge)

      assert info.workspace_id == src_ws.id
      assert media_count(src_ws.id) == 0
    end
  end

  describe "the negative arm — a legitimate import is untouched" do
    test "no path collision → the import lands and the media_files row is restored" do
      {src_ws, bundle} = source_bundle_holding!(@collision_path)
      {_other_ws, _other_file} = resident_holder!("2026/08/somewhere-else.png")

      assert {:ok, stats} = WorkspaceBundle.import_bundle(bundle, mode: :merge)
      assert stats.total_rows > 0
      assert media_count(src_ws.id) == 1
    end

    test "the SAME workspace re-importing its OWN rows at its OWN paths is not a collision" do
      ws = create_workspace!(unique("blobself"))
      project = create_project!(ws, unique("blobselfp"))
      {:ok, _dataset} = Tenancy.get_or_create_dataset(project.id, "production")

      {:ok, _file} =
        create_media_file_in!(
          ws,
          project,
          %{path: @collision_path, filename: "self.png"},
          "production"
        )

      {:ok, bundle} = WorkspaceBundle.export(ws.id)

      # The row STAYS resident — a merge re-import upserts onto itself.
      assert {:ok, _stats} = WorkspaceBundle.import_bundle(bundle, mode: :merge)
      assert media_count(ws.id) == 1
    end
  end
end
