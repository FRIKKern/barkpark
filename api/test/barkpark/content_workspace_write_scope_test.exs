defmodule Barkpark.ContentWorkspaceWriteScopeTest do
  @moduledoc """
  Wave 1 hard tenant boundary — WRITE-side scope stamping.

  The s2 test proves the read-side WHERE workspace_id filter. This test proves
  the write side: a mutation applied via `Content.apply_mutations/3` under
  workspace A's scope opts STAMPS the new document with A's workspace_id (and is
  NOT visible to a read scoped to workspace B), while a write under the Default
  scope stamps the Default workspace. This is the mutate write-path that
  MutateController threads from `conn.assigns[:current_workspace]` /
  `[:current_project]`.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Tenancy

  @type_name "post"
  # One dataset shared by BOTH workspaces — isolation must come from the
  # stamped workspace_id, NOT the dataset string.
  @shared_dataset "test"

  defp make_scope(ws_slug, project_slug) do
    {:ok, ws} = Tenancy.create_workspace(%{slug: ws_slug, name: ws_slug})
    {:ok, project} = Tenancy.create_project(ws, %{slug: project_slug, name: project_slug})
    {ws, project}
  end

  defp doc_ids(docs), do: docs |> Enum.map(& &1.doc_id) |> Enum.sort()

  defp mutate(attrs, opts) do
    {:ok, {_tx_id, [result]}} =
      Content.apply_mutations(
        [%{"create" => attrs}],
        @shared_dataset,
        opts
      )

    result
  end

  describe "apply_mutations/3 write-side scope stamping" do
    setup do
      {ws_a, proj_a} = make_scope("write-a", "p-a")
      {ws_b, proj_b} = make_scope("write-b", "p-b")
      %{ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, proj_b: proj_b}
    end

    test "a mutation under workspace A's scope stamps the new doc with A's ids", %{
      ws_a: ws_a,
      proj_a: proj_a
    } do
      result =
        mutate(%{"_id" => "wa-doc", "_type" => @type_name, "title" => "A"},
          source: :api,
          workspace_id: ws_a.id,
          project_id: proj_a.id
        )

      {:ok, doc} =
        Content.get_document(result.id, @type_name, @shared_dataset, workspace_id: ws_a.id)

      assert doc.workspace_id == ws_a.id
      assert doc.project_id == proj_a.id
    end

    test "A's written doc is NOT visible to a read scoped to workspace B", %{
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b
    } do
      result =
        mutate(%{"_id" => "wa-only", "_type" => @type_name, "title" => "A only"},
          source: :api,
          workspace_id: ws_a.id,
          project_id: proj_a.id
        )

      # Read scoped to A sees it.
      a_docs =
        Content.list_documents(@type_name, @shared_dataset,
          perspective: :raw,
          workspace_id: ws_a.id
        )

      assert result.id in doc_ids(a_docs)

      # Read scoped to B does NOT — the WRITE landed in A only.
      b_docs =
        Content.list_documents(@type_name, @shared_dataset,
          perspective: :raw,
          workspace_id: ws_b.id
        )

      refute result.id in doc_ids(b_docs)

      assert {:error, :not_found} =
               Content.get_document(result.id, @type_name, @shared_dataset, workspace_id: ws_b.id)
    end

    test "two writes under A and B don't leak — each visible only in its own scope", %{
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b,
      proj_b: proj_b
    } do
      ra =
        mutate(%{"_id" => "ab-a", "_type" => @type_name, "title" => "A"},
          source: :api,
          workspace_id: ws_a.id,
          project_id: proj_a.id
        )

      rb =
        mutate(%{"_id" => "ab-b", "_type" => @type_name, "title" => "B"},
          source: :api,
          workspace_id: ws_b.id,
          project_id: proj_b.id
        )

      a_ids =
        Content.list_documents(@type_name, @shared_dataset, perspective: :raw, workspace_id: ws_a.id)
        |> doc_ids()

      b_ids =
        Content.list_documents(@type_name, @shared_dataset, perspective: :raw, workspace_id: ws_b.id)
        |> doc_ids()

      assert ra.id in a_ids
      refute ra.id in b_ids
      assert rb.id in b_ids
      refute rb.id in a_ids
    end
  end

  describe "back-compat: a write under the Default scope stamps Default" do
    test "a mutation under the seeded Default workspace/project stamps the Default ids" do
      ws = Tenancy.get_default_workspace()
      project = Tenancy.get_default_project()
      assert ws, "Default Workspace must be seeded by the backfill migration"

      result =
        mutate(%{"_id" => "default-write", "_type" => @type_name, "title" => "Default"},
          source: :api,
          workspace_id: ws.id,
          project_id: project.id
        )

      {:ok, doc} =
        Content.get_document(result.id, @type_name, @shared_dataset, workspace_id: ws.id)

      assert doc.workspace_id == ws.id
      assert doc.project_id == project.id
    end

    test "a write with NO scope opts (fresh-DB / pre-backfill) lands unscoped, never nulling" do
      result =
        mutate(%{"_id" => "unscoped-write", "_type" => @type_name, "title" => "unscoped"},
          source: :api
        )

      {:ok, doc} = Content.get_document(result.id, @type_name, @shared_dataset)
      assert is_nil(doc.workspace_id)
      assert is_nil(doc.project_id)
    end
  end
end
