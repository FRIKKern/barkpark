defmodule Barkpark.ContentWorkspaceScopeTest do
  @moduledoc """
  Wave 1 hard tenant boundary — workspace-scoped content reads.

  Proves the WHERE workspace_id filter at the query layer: a document created
  in workspace A and one created in workspace B do NOT leak across the
  workspace boundary when a read is scoped, and the flat / Default-scope read
  still returns the Default workspace's docs (back-compat).
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Tenancy

  @type_name "post"
  # A dataset name shared by BOTH workspaces — the isolation must come from
  # workspace_id, NOT from the dataset string. If scoping fell back to the
  # dataset leaf alone, A's query would also see B's doc (same dataset).
  @shared_dataset "test"

  defp make_scope(ws_slug, project_slug) do
    {:ok, ws} = Tenancy.create_workspace(%{slug: ws_slug, name: ws_slug})
    {:ok, project} = Tenancy.create_project(ws, %{slug: project_slug, name: project_slug})
    {ws, project}
  end

  defp doc_ids(docs), do: docs |> Enum.map(& &1.doc_id) |> Enum.sort()

  describe "workspace-scoped list_documents/3 isolation" do
    setup do
      {ws_a, proj_a} = make_scope("scope-a", "p-a")
      {ws_b, proj_b} = make_scope("scope-b", "p-b")

      {:ok, doc_a} =
        Content.create_document(
          @type_name,
          %{"doc_id" => "doc-in-a", "title" => "A's doc"},
          @shared_dataset,
          workspace_id: ws_a.id,
          project_id: proj_a.id
        )

      {:ok, doc_b} =
        Content.create_document(
          @type_name,
          %{"doc_id" => "doc-in-b", "title" => "B's doc"},
          @shared_dataset,
          workspace_id: ws_b.id,
          project_id: proj_b.id
        )

      %{ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, proj_b: proj_b, doc_a: doc_a, doc_b: doc_b}
    end

    test "writes stamp workspace_id/project_id from the scope on insert", %{
      ws_a: ws_a,
      proj_a: proj_a,
      doc_a: doc_a
    } do
      assert doc_a.workspace_id == ws_a.id
      assert doc_a.project_id == proj_a.id
    end

    test "a query scoped to workspace A returns ONLY A's doc, never B's", %{ws_a: ws_a} do
      docs =
        Content.list_documents(@type_name, @shared_dataset,
          perspective: :raw,
          workspace_id: ws_a.id
        )

      assert doc_ids(docs) == ["drafts.doc-in-a"]
      refute "drafts.doc-in-b" in doc_ids(docs)
    end

    test "a query scoped to workspace B returns ONLY B's doc", %{ws_b: ws_b} do
      docs =
        Content.list_documents(@type_name, @shared_dataset,
          perspective: :raw,
          workspace_id: ws_b.id
        )

      assert doc_ids(docs) == ["drafts.doc-in-b"]
    end

    test "project scoping narrows within the workspace", %{ws_a: ws_a, proj_a: proj_a} do
      docs =
        Content.list_documents(@type_name, @shared_dataset,
          perspective: :raw,
          workspace_id: ws_a.id,
          project_id: proj_a.id
        )

      assert doc_ids(docs) == ["drafts.doc-in-a"]
    end

    test "get_document scoped to A cannot fetch B's doc", %{ws_a: ws_a} do
      assert {:error, :not_found} =
               Content.get_document("drafts.doc-in-b", @type_name, @shared_dataset,
                 workspace_id: ws_a.id
               )

      assert {:ok, _} =
               Content.get_document("drafts.doc-in-a", @type_name, @shared_dataset,
                 workspace_id: ws_a.id
               )
    end

    test "an unscoped query (nil workspace) still sees both — proves the filter is the gate", %{} do
      docs = Content.list_documents(@type_name, @shared_dataset, perspective: :raw)
      ids = doc_ids(docs)
      assert "drafts.doc-in-a" in ids
      assert "drafts.doc-in-b" in ids
    end
  end

  describe "back-compat: Default-workspace scope (flat routes)" do
    test "a read scoped to the seeded Default workspace returns Default docs" do
      ws = Tenancy.get_default_workspace()
      project = Tenancy.get_default_project()
      assert ws, "Default Workspace must be seeded by the backfill migration"

      {:ok, _doc} =
        Content.create_document(
          @type_name,
          %{"doc_id" => "default-doc", "title" => "Default doc"},
          @shared_dataset,
          workspace_id: ws.id,
          project_id: project.id
        )

      # Also create a doc in a DIFFERENT workspace sharing the dataset.
      {other_ws, other_proj} = make_scope("scope-other", "p-other")

      {:ok, _} =
        Content.create_document(
          @type_name,
          %{"doc_id" => "other-doc", "title" => "Other"},
          @shared_dataset,
          workspace_id: other_ws.id,
          project_id: other_proj.id
        )

      docs =
        Content.list_documents(@type_name, @shared_dataset,
          perspective: :raw,
          workspace_id: ws.id,
          project_id: project.id
        )

      assert doc_ids(docs) == ["drafts.default-doc"]
    end
  end
end
