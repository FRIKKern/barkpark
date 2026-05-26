defmodule Barkpark.ContentCrossProjectDatasetScopeTest do
  @moduledoc """
  barkpark-9y0w: datasets are PROJECT-owned, so the slug `"production"` is NOT
  globally unique — `project A`'s `production` and `project B`'s `production`
  are DIFFERENT datasets (distinct `dataset_id`) that share the STRING.

  Before the fix, the residual analytics / export / revision reads filtered by
  the bare `dataset == ^dataset` STRING with no dataset_id/project qualifier, so
  a read of A's `production` CONFLATED B's same-named dataset into the result.
  After the fix each read resolves the dataset STRING → the CURRENT project's
  `dataset_id` and filters on that, so A's read excludes B's rows.

  This proves the headline functions on a representative spread —
  `document_stats`, `total_documents`, `recent_activity`, `export_stream`,
  `list_revisions`. `reference_title`, `allowed_origins_for_dataset`,
  `schema_hash_for_dataset` are fixed the SAME way (resolve_read_dataset_id →
  `scope_to_dataset` dataset_id filter, STRING fallback when unresolved).
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.{Content, Repo}

  @ds "production"

  # Two projects (across two workspaces) each owning a `"production"` dataset
  # with distinct docs. Returns {scope_a, scope_b}.
  defp two_projects_with_production do
    ws_a = create_workspace!()
    proj_a = create_project!(ws_a)
    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)

    scope_a = [workspace_id: ws_a.id, project_id: proj_a.id]
    scope_b = [workspace_id: ws_b.id, project_id: proj_b.id]

    {:ok, _} = Content.create_document("post", %{"doc_id" => "a-only", "title" => "A1"}, @ds, scope_a)
    {:ok, _} = Content.create_document("post", %{"doc_id" => "a-two", "title" => "A2"}, @ds, scope_a)

    {:ok, _} = Content.create_document("post", %{"doc_id" => "b-only", "title" => "B1"}, @ds, scope_b)
    {:ok, _} = Content.create_document("note", %{"doc_id" => "b-two", "title" => "B2"}, @ds, scope_b)
    {:ok, _} = Content.create_document("note", %{"doc_id" => "b-three", "title" => "B3"}, @ds, scope_b)

    {scope_a, scope_b}
  end

  test "total_documents for A's production counts ONLY A's docs, not B's same-named dataset" do
    {scope_a, scope_b} = two_projects_with_production()

    # A wrote 2 docs, B wrote 3 — all in the STRING "production". A's scoped
    # count is 2 (would be 5 under the old bare-string conflation).
    assert Content.total_documents(@ds, scope_a) == 2
    assert Content.total_documents(@ds, scope_b) == 3
  end

  test "document_stats for A's production groups ONLY A's types, not B's" do
    {scope_a, scope_b} = two_projects_with_production()

    a_types = Content.document_stats(@ds, scope_a) |> Enum.map(& &1.type) |> Enum.sort()
    b_types = Content.document_stats(@ds, scope_b) |> Enum.map(& &1.type) |> Enum.sort()

    # A only ever wrote "post"; B wrote "post" + "note". A's stats must NOT leak
    # B's "note" group (which it would under the bare-string read).
    assert a_types == ["post"]
    assert b_types == ["note", "post"]
  end

  test "recent_activity for A's production returns ONLY A's mutation events" do
    {scope_a, scope_b} = two_projects_with_production()

    a_ids = Content.recent_activity(@ds, scope_a) |> Enum.map(& &1.doc_id) |> MapSet.new()
    b_ids = Content.recent_activity(@ds, scope_b) |> Enum.map(& &1.doc_id) |> MapSet.new()

    assert MapSet.member?(a_ids, "drafts.a-only")
    assert MapSet.member?(a_ids, "drafts.a-two")
    refute MapSet.member?(a_ids, "drafts.b-only")
    refute MapSet.member?(a_ids, "drafts.b-two")

    # And the mirror: B's read excludes A's events.
    refute MapSet.member?(b_ids, "drafts.a-only")
    assert MapSet.member?(b_ids, "drafts.b-only")
  end

  test "export_stream for A's production yields ONLY A's documents" do
    {scope_a, scope_b} = two_projects_with_production()

    # export_stream uses Repo.stream — must be reduced inside a transaction.
    a_ids =
      Repo.transaction(fn ->
        Content.export_stream(@ds, scope_a) |> Enum.map(& &1["_id"])
      end)
      |> elem(1)
      |> MapSet.new()

    assert MapSet.member?(a_ids, "drafts.a-only")
    assert MapSet.member?(a_ids, "drafts.a-two")
    refute MapSet.member?(a_ids, "drafts.b-only")
    refute MapSet.member?(a_ids, "drafts.b-two")

    # B's export, scoped to B's production, has exactly its three docs and none
    # of A's — no conflation either direction.
    b_count =
      Repo.transaction(fn -> Content.export_stream(@ds, scope_b) |> Enum.to_list() end)
      |> elem(1)
      |> length()

    assert b_count == 3
  end

  test "list_revisions for A's production returns ONLY A's revisions" do
    {scope_a, scope_b} = two_projects_with_production()

    # Both projects have a `post` "shared-rev" doc in "production" — a write
    # records a revision per project, scoped by dataset_id.
    {:ok, _} =
      Content.upsert_document("post", %{"doc_id" => "shared-rev", "title" => "A-rev"}, @ds, scope_a)

    {:ok, _} =
      Content.upsert_document("post", %{"doc_id" => "shared-rev", "title" => "B-rev"}, @ds, scope_b)

    a_revs = Content.list_revisions("shared-rev", "post", @ds, scope_a)
    b_revs = Content.list_revisions("shared-rev", "post", @ds, scope_b)

    # Same doc_id + type + dataset STRING in both projects. The bare-string read
    # would surface BOTH revisions under either scope. Scoped by dataset_id, A
    # sees only its "A-rev" title and B only its "B-rev".
    a_titles = a_revs |> Enum.map(& &1.title) |> Enum.uniq()
    b_titles = b_revs |> Enum.map(& &1.title) |> Enum.uniq()

    assert a_titles == ["A-rev"]
    assert b_titles == ["B-rev"]
  end
end
