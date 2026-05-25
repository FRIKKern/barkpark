defmodule Barkpark.TenancyFixturesTest do
  @moduledoc """
  Meta-test for the Wave 1.5 cross-workspace leak harness.

  Proves the harness itself catches what the legacy single-workspace fixtures
  could not: a row created in workspace A is visible under A's scope and
  INVISIBLE under workspace B's scope. The `assert_no_cross_workspace_leak/7`
  assertion wraps both halves so the sibling-controller fixes can call it in
  one line.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.{Content, Media}

  # Same dataset in BOTH workspaces — isolation must come from workspace_id,
  # not the dataset leaf.
  @dataset "test"
  @type_name "post"

  setup do
    ws_a = create_workspace!()
    proj_a = create_project!(ws_a)
    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)

    %{ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, proj_b: proj_b}
  end

  describe "fixtures stand up distinct workspaces" do
    test "create_workspace!/create_project! make isolated, valid scopes", %{
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b
    } do
      refute ws_a.id == ws_b.id
      assert proj_a.workspace_id == ws_a.id
    end

    test "ensure_default_scope! returns the seeded Default workspace + project" do
      {ws, project} = ensure_default_scope!()
      assert ws.slug == "default"
      assert project.slug == "default"
      assert project.workspace_id == ws.id
    end
  end

  describe "document leak detection" do
    test "a doc created in A is visible under A's scope, NOT under B's", %{
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b,
      proj_b: proj_b
    } do
      {:ok, doc_a} = create_document_in!(ws_a, proj_a, @type_name, %{"doc_id" => "leak-a"})

      # Sanity: A's scoped read sees A's doc.
      a_docs =
        Content.list_documents(@type_name, @dataset,
          perspective: :raw,
          workspace_id: ws_a.id,
          project_id: proj_a.id
        )

      assert doc_a.doc_id in Enum.map(a_docs, & &1.doc_id)

      # Leak guard: B's scoped read does NOT see A's doc.
      b_docs =
        Content.list_documents(@type_name, @dataset,
          perspective: :raw,
          workspace_id: ws_b.id,
          project_id: proj_b.id
        )

      refute doc_a.doc_id in Enum.map(b_docs, & &1.doc_id)
    end

    test "assert_no_cross_workspace_leak/7 passes for a correctly-scoped reader", %{
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b,
      proj_b: proj_b
    } do
      {:ok, doc_a} = create_document_in!(ws_a, proj_a, @type_name, %{"doc_id" => "guard-a"})

      reader = fn scope ->
        Content.list_documents(@type_name, @dataset, [perspective: :raw] ++ scope)
      end

      assert :ok =
               assert_no_cross_workspace_leak(
                 reader,
                 ws_a,
                 proj_a,
                 ws_b,
                 proj_b,
                 & &1.doc_id,
                 doc_a.doc_id
               )
    end

    test "assert_no_cross_workspace_leak/7 FAILS when the reader ignores scope (proves it catches leaks)",
         %{ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, proj_b: proj_b} do
      {:ok, doc_a} = create_document_in!(ws_a, proj_a, @type_name, %{"doc_id" => "leaky-a"})

      # A deliberately-broken reader that drops the scope opts — exactly the
      # bug the Wave 1.5 sibling controllers have today. The harness MUST raise.
      leaky_reader = fn _ignored_scope ->
        Content.list_documents(@type_name, @dataset, perspective: :raw)
      end

      assert_raise ExUnit.AssertionError, fn ->
        assert_no_cross_workspace_leak(
          leaky_reader,
          ws_a,
          proj_a,
          ws_b,
          proj_b,
          & &1.doc_id,
          doc_a.doc_id
        )
      end
    end
  end

  describe "media leak detection" do
    test "a media_file created in A is visible under A's scope, NOT under B's", %{
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b,
      proj_b: proj_b
    } do
      {:ok, file_a} = create_media_file_in!(ws_a, proj_a)

      reader = fn scope ->
        {files, _total} = Media.query_files(@dataset, scope)
        files
      end

      assert :ok =
               assert_no_cross_workspace_leak(
                 reader,
                 ws_a,
                 proj_a,
                 ws_b,
                 proj_b,
                 & &1.id,
                 file_a.id
               )
    end
  end
end
