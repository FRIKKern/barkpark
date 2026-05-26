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

    test "a write with NO scope opts lands in the seeded Default scope" do
      # The backfill migration seeds a Default Workspace/Project into every db
      # (including test sandboxes), and an unscoped write now defaults to it
      # (see Content.put_scope_attrs). Explicit scope still wins (covered above);
      # this asserts the no-scope fallback so nil-scope fixtures stay visible to
      # Default-scoped flat-route reads.
      ws = Tenancy.get_default_workspace()
      project = Tenancy.get_default_project()
      assert ws, "Default Workspace must be seeded by the backfill migration"

      result =
        mutate(%{"_id" => "unscoped-write", "_type" => @type_name, "title" => "unscoped"},
          source: :api
        )

      {:ok, doc} = Content.get_document(result.id, @type_name, @shared_dataset)
      assert doc.workspace_id == ws.id
      assert doc.project_id == project.id
    end
  end

  describe "workspace-only write resolves the workspace's default project + dataset_id (wykb)" do
    # The NULL-dataset_id gap: a write scoped with workspace_id but NO project_id
    # (the scope_to_workspace(q, ws, nil) contract) used to leave project_id nil,
    # so resolve_dataset_id_for_write short-circuited and stamped dataset_id=NULL.
    # The fix resolves the workspace's OWN default project, which lets dataset_id
    # resolve. This row is then visible to a strict dataset_id reader in its own
    # scope.

    test "stamps the dataset_id resolved via the workspace's default-slug project (NOT NULL)" do
      {:ok, ws} = Tenancy.create_workspace(%{slug: "wo-default", name: "wo-default"})
      # The workspace's OWN default project — the resolver must prefer the
      # "default"-slug project.
      {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "default"})

      result =
        mutate(%{"_id" => "wo-doc", "_type" => @type_name, "title" => "WS-only"},
          source: :api,
          workspace_id: ws.id
          # NO project_id — workspace-only scope.
        )

      {:ok, doc} =
        Content.get_document(result.id, @type_name, @shared_dataset, workspace_id: ws.id)

      assert doc.workspace_id == ws.id
      # The fix: project resolved from the workspace's default project...
      assert doc.project_id == proj.id
      # ...and dataset_id is NOT NULL — it points at the `@shared_dataset` dataset
      # row under THAT project (the workspace's default-project production-style
      # dataset for the written dataset string).
      assert is_binary(doc.dataset_id)
      ds = Tenancy.get_dataset_by_id(doc.dataset_id)
      assert ds.project_id == proj.id
      assert ds.slug == @shared_dataset
    end

    test "prefers the \"default\"-slug project over a non-default project" do
      {:ok, ws} = Tenancy.create_workspace(%{slug: "wo-prefer", name: "wo-prefer"})
      # A non-default project (slug-orders BEFORE "default": "aaa" < "default")
      # to prove the resolver picks "default" by slug, not by ordering.
      {:ok, _other} = Tenancy.create_project(ws, %{slug: "aaa", name: "aaa"})
      {:ok, default_proj} = Tenancy.create_project(ws, %{slug: "default", name: "default"})

      result =
        mutate(%{"_id" => "wo-prefer-doc", "_type" => @type_name, "title" => "prefer"},
          source: :api,
          workspace_id: ws.id
        )

      {:ok, doc} =
        Content.get_document(result.id, @type_name, @shared_dataset, workspace_id: ws.id)

      assert doc.project_id == default_proj.id
    end

    test "NEVER-WORSE: a workspace with NO projects writes dataset_id=NULL without crashing, still readable" do
      {:ok, ws} = Tenancy.create_workspace(%{slug: "wo-empty", name: "wo-empty"})
      # No projects created under this workspace — nothing to resolve.

      result =
        mutate(%{"_id" => "wo-null", "_type" => @type_name, "title" => "no-proj"},
          source: :api,
          workspace_id: ws.id
        )

      # The write did NOT crash and stamped the workspace.
      {:ok, doc} =
        Content.get_document(result.id, @type_name, @shared_dataset, workspace_id: ws.id)

      assert doc.workspace_id == ws.id
      # No project resolved => project_id + dataset_id stay nil (never-worse).
      assert is_nil(doc.project_id)
      assert is_nil(doc.dataset_id)

      # And the row is STILL readable in its own scope via the yx7f NULL-tolerant
      # read — a workspace-only list surfaces it.
      ids =
        Content.list_documents(@type_name, @shared_dataset, perspective: :raw, workspace_id: ws.id)
        |> doc_ids()

      assert result.id in ids
    end

    test "explicit project_id is UNCHANGED — the resolver does not override it" do
      {:ok, ws} = Tenancy.create_workspace(%{slug: "wo-explicit", name: "wo-explicit"})
      {:ok, _default_proj} = Tenancy.create_project(ws, %{slug: "default", name: "default"})
      # An explicit, NON-default project the caller named directly.
      {:ok, explicit_proj} = Tenancy.create_project(ws, %{slug: "chosen", name: "chosen"})

      result =
        mutate(%{"_id" => "wo-explicit-doc", "_type" => @type_name, "title" => "explicit"},
          source: :api,
          workspace_id: ws.id,
          project_id: explicit_proj.id
        )

      {:ok, doc} =
        Content.get_document(result.id, @type_name, @shared_dataset, workspace_id: ws.id)

      # The explicit project wins — NOT the "default"-slug project the resolver
      # would have picked for a workspace-only write.
      assert doc.project_id == explicit_proj.id
      assert is_binary(doc.dataset_id)
      ds = Tenancy.get_dataset_by_id(doc.dataset_id)
      assert ds.project_id == explicit_proj.id
    end
  end
end
