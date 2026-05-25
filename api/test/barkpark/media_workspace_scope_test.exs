defmodule Barkpark.MediaWorkspaceScopeTest do
  @moduledoc """
  Wave 1 hard tenant boundary — workspace-scoped MEDIA reads/writes.

  Proves the WHERE workspace_id filter on the media query path: a media file
  created in workspace A and one in workspace B do NOT leak across the
  workspace boundary when a read is scoped, and an unscoped / Default-scope
  read still returns rows (back-compat). Mirrors
  `Barkpark.ContentWorkspaceScopeTest` for the media context.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Media
  alias Barkpark.Media.MediaFile
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  # A dataset shared by BOTH workspaces — isolation must come from
  # workspace_id, NOT from the dataset string.
  @shared_dataset "test"

  defp make_scope(ws_slug, project_slug) do
    {:ok, ws} = Tenancy.create_workspace(%{slug: ws_slug, name: ws_slug})
    {:ok, project} = Tenancy.create_project(ws, %{slug: project_slug, name: project_slug})
    {ws, project}
  end

  defp insert_file(name, dataset, opts) do
    attrs =
      %{
        filename: name,
        original_name: name,
        path: "uploads/#{dataset}/#{name}",
        mime_type: "image/png",
        size: 42,
        dataset: dataset
      }
      |> maybe_put(:workspace_id, Keyword.get(opts, :workspace_id))
      |> maybe_put(:project_id, Keyword.get(opts, :project_id))

    %MediaFile{}
    |> MediaFile.changeset(attrs)
    |> Repo.insert!()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp names(files), do: files |> Enum.map(& &1.filename) |> Enum.sort()

  describe "workspace-scoped media reads isolation" do
    setup do
      {ws_a, proj_a} = make_scope("media-a", "mp-a")
      {ws_b, proj_b} = make_scope("media-b", "mp-b")

      file_a = insert_file("a.png", @shared_dataset, workspace_id: ws_a.id, project_id: proj_a.id)
      file_b = insert_file("b.png", @shared_dataset, workspace_id: ws_b.id, project_id: proj_b.id)

      %{ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, file_a: file_a, file_b: file_b}
    end

    test "the MediaFile changeset stamps workspace_id/project_id on insert", %{
      ws_a: ws_a,
      proj_a: proj_a,
      file_a: file_a
    } do
      assert file_a.workspace_id == ws_a.id
      assert file_a.project_id == proj_a.id
    end

    test "list_files scoped to A returns ONLY A's file, never B's", %{ws_a: ws_a} do
      files = Media.list_files(@shared_dataset, workspace_id: ws_a.id)
      assert names(files) == ["a.png"]
      refute "b.png" in names(files)
    end

    test "query_files scoped to B returns ONLY B's file", %{ws_b: ws_b} do
      {files, total} = Media.query_files(@shared_dataset, workspace_id: ws_b.id)
      assert names(files) == ["b.png"]
      assert total == 1
    end

    test "search_files scoped to A returns ONLY A's file", %{ws_a: ws_a} do
      {files, total, _facets} = Media.search_files(@shared_dataset, workspace_id: ws_a.id)
      assert names(files) == ["a.png"]
      assert total == 1
    end

    test "get_file scoped to A cannot fetch B's file", %{ws_a: ws_a, file_b: file_b, file_a: file_a} do
      assert {:error, :not_found} = Media.get_file(file_b.id, workspace_id: ws_a.id)
      assert {:ok, _} = Media.get_file(file_a.id, workspace_id: ws_a.id)
    end

    test "an unscoped read (nil workspace) still sees both — proves the filter is the gate", %{} do
      files = Media.list_files(@shared_dataset)
      assert "a.png" in names(files)
      assert "b.png" in names(files)
    end
  end

  describe "back-compat: Default-workspace scope (flat routes)" do
    test "a read scoped to the seeded Default workspace returns Default rows only" do
      ws = Tenancy.get_default_workspace()
      project = Tenancy.get_default_project()
      assert ws, "Default Workspace must be seeded by the backfill migration"

      _default =
        insert_file("default.png", @shared_dataset,
          workspace_id: ws.id,
          project_id: project.id
        )

      {other_ws, other_proj} = make_scope("media-other", "mp-other")

      _other =
        insert_file("other.png", @shared_dataset,
          workspace_id: other_ws.id,
          project_id: other_proj.id
        )

      files = Media.list_files(@shared_dataset, workspace_id: ws.id, project_id: project.id)
      assert names(files) == ["default.png"]
    end
  end
end
