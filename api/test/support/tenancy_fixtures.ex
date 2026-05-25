defmodule Barkpark.TenancyFixtures do
  @moduledoc """
  Multi-workspace fixtures + the negative cross-workspace leak assertion.

  The legacy test suite seeds single-workspace fixtures (most `create_document`
  calls pass no workspace), so it structurally CANNOT catch a cross-tenant
  leak — a reader that forgot to thread scope returns the same rows whether or
  not the boundary is enforced. This module is the harness the Wave 1.5
  sibling-controller fixes are proved against: it stands up TWO distinct
  workspaces and asserts a read scoped to workspace B never sees workspace A's
  row.

  Usage in a test:

      import Barkpark.TenancyFixtures

      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      ws_b = create_workspace!()
      proj_b = create_project!(ws_b)

      {:ok, doc_a} = create_document_in!(ws_a, proj_a, "post", %{"doc_id" => "a1"})

      assert_no_cross_workspace_leak(
        fn scope -> Content.list_documents("post", "test", [perspective: :raw] ++ scope) end,
        ws_a,
        proj_a,
        ws_b,
        proj_b,
        & &1.doc_id,
        doc_a.doc_id
      )
  """

  alias Barkpark.{Content, Media, Tenancy}

  import ExUnit.Assertions

  @default_dataset "test"

  @doc """
  Create a Workspace with a unique slug (override via `slug`). Raises on a
  changeset error so a test fails loudly at the fixture instead of later.
  """
  @spec create_workspace!(String.t()) :: Tenancy.Workspace.t()
  def create_workspace!(slug \\ unique_slug("ws")) do
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug, name: slug})
    ws
  end

  @doc """
  Create a Project under `workspace` (struct or id) with a unique slug
  (override via `slug`). Raises on a changeset error.
  """
  @spec create_project!(Tenancy.Workspace.t() | binary(), String.t()) :: Tenancy.Project.t()
  def create_project!(workspace, slug \\ unique_slug("proj")) do
    {:ok, project} = Tenancy.create_project(workspace, %{slug: slug, name: slug})
    project
  end

  @doc """
  Create a document STAMPED with the given workspace/project scope. `project`
  may be `nil` for a workspace-only document. Returns `{:ok, doc}`; raises if
  the write fails so a fixture mistake surfaces immediately.

  `attrs` and `dataset` default to a minimal post in the shared `"test"`
  dataset — the dataset string is deliberately the SAME across workspaces so
  isolation must come from `workspace_id`, not the dataset leaf.
  """
  @spec create_document_in!(
          Tenancy.Workspace.t(),
          Tenancy.Project.t() | nil,
          String.t(),
          map(),
          String.t()
        ) :: {:ok, Content.Document.t()}
  def create_document_in!(workspace, project, type \\ "post", attrs \\ %{}, dataset \\ @default_dataset) do
    attrs = Map.put_new(attrs, "title", "fixture doc")

    {:ok, _doc} =
      Content.create_document(type, attrs, dataset, scope_opts(workspace, project))
  end

  @doc """
  Create a media_file row STAMPED with the given workspace/project scope.
  Inserts directly through `MediaFile.changeset` (no disk I/O) so the harness
  stays light — the leak we test is the DB-scope filter, not the upload path.
  Returns `{:ok, media_file}`; raises on failure.
  """
  @spec create_media_file_in!(
          Tenancy.Workspace.t(),
          Tenancy.Project.t() | nil,
          map(),
          String.t()
        ) :: {:ok, Media.MediaFile.t()}
  def create_media_file_in!(workspace, project, attrs \\ %{}, dataset \\ @default_dataset) do
    suffix = System.unique_integer([:positive])

    attrs =
      %{
        filename: "fixture-#{suffix}.png",
        original_name: "fixture-#{suffix}.png",
        path: "fixtures/#{suffix}.png",
        mime_type: "image/png",
        size: 1
      }
      |> Map.merge(attrs)
      |> Map.put(:workspace_id, workspace.id)
      |> Map.put(:project_id, project && project.id)
      |> Map.put(:dataset, dataset)

    {:ok, _file} =
      %Media.MediaFile{}
      |> Media.MediaFile.changeset(attrs)
      |> Barkpark.Repo.insert()
  end

  @doc """
  The reusable negative assertion. Given a `reader` that takes scope opts
  (`[workspace_id: ..., project_id: ...]`) and returns a list of rows, a
  workspace-A fixture, a workspace-B scope, an `id_fun` that extracts the
  comparable id from a row, and the `expected_a_id` of the row created in A:

    1. assert the row IS visible when the reader is scoped to A (sanity — the
       reader actually surfaces the row under its own scope), and
    2. assert the row is NOT visible when the reader is scoped to B (the leak
       guard — B must never see A's row).

  `project_a` / `project_b` may be `nil` for workspace-only scoping.
  """
  @spec assert_no_cross_workspace_leak(
          (keyword() -> [any()]),
          Tenancy.Workspace.t(),
          Tenancy.Project.t() | nil,
          Tenancy.Workspace.t(),
          Tenancy.Project.t() | nil,
          (any() -> any()),
          any()
        ) :: :ok
  def assert_no_cross_workspace_leak(
        reader,
        workspace_a,
        project_a,
        workspace_b,
        project_b,
        id_fun,
        expected_a_id
      )
      when is_function(reader, 1) and is_function(id_fun, 1) do
    a_ids = reader.(scope_opts(workspace_a, project_a)) |> Enum.map(id_fun)
    b_ids = reader.(scope_opts(workspace_b, project_b)) |> Enum.map(id_fun)

    assert expected_a_id in a_ids,
           "expected #{inspect(expected_a_id)} to be visible under workspace A's scope, " <>
             "got #{inspect(a_ids)} — the reader is not surfacing A's own row"

    refute expected_a_id in b_ids,
           "CROSS-WORKSPACE LEAK: #{inspect(expected_a_id)} (created in workspace A) was " <>
             "returned under workspace B's scope — the reader is not threading tenancy scope"

    :ok
  end

  @doc """
  Ensure the seeded Default Workspace + Project exist for the current test.
  The backfill migration (20260527110200) seeds them in the test DB, so this
  is normally a no-op read; it creates them only when a fresh per-test sandbox
  lacks them, so a Default-scope reader (the flat back-compat path) behaves.
  Returns `{workspace, project}`.
  """
  @spec ensure_default_scope!() :: {Tenancy.Workspace.t(), Tenancy.Project.t()}
  def ensure_default_scope! do
    ws =
      case Tenancy.get_default_workspace() do
        nil -> create_workspace!("default")
        ws -> ws
      end

    project =
      case Tenancy.get_default_project() do
        nil -> create_project!(ws, "default")
        project -> project
      end

    {ws, project}
  end

  # Build [workspace_id: ..., project_id: ...] from fixtures, dropping a nil
  # project so the opts shape matches the production scope_opts contract.
  defp scope_opts(workspace, nil), do: [workspace_id: workspace.id]
  defp scope_opts(workspace, project), do: [workspace_id: workspace.id, project_id: project.id]

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
