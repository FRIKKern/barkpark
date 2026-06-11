defmodule Barkpark.Search.DocumentsRetrieverScopeTest do
  @moduledoc """
  barkpark-y9ee: the document text-search read path (DocumentsRetriever) must
  resolve the dataset STRING → the project's `dataset_id` and filter on THAT,
  not on the bare `dataset == ^scope` STRING.

  Before the fix, two projects each owning a `production` dataset (distinct
  `dataset_id`, SAME string) conflated: a search scoped to project A's
  `production` returned project B's same-named-dataset hits. After the fix the
  retriever resolves A's `production` dataset_id and filters on it, so A's
  search excludes B's documents.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content

  # SAME dataset STRING across both projects — the conflation surface.
  @ds "production"
  @term "kumquat"

  # Two projects (across two workspaces) each owning a `production` dataset
  # holding a document whose title matches @term. Returns {scope_a, scope_b}.
  defp two_projects_with_matching_doc do
    ws_a = create_workspace!()
    proj_a = create_project!(ws_a)
    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)

    scope_a = [workspace_id: ws_a.id, project_id: proj_a.id]
    scope_b = [workspace_id: ws_b.id, project_id: proj_b.id]

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "a-hit", "title" => "#{@term} from A"},
        @ds,
        scope_a
      )

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "b-hit", "title" => "#{@term} from B"},
        @ds,
        scope_b
      )

    {scope_a, scope_b}
  end

  test "a search scoped to project A returns ONLY A's matching doc, not B's same-named-dataset hit" do
    {scope_a, scope_b} = two_projects_with_matching_doc()

    # perspective: :raw surfaces the freshly-created drafts without a publish
    # step — the conflation under test is the dataset-scope filter, not the
    # published/draft perspective.
    {a_hits, a_total, _} =
      Content.search_documents(@term, @ds, [perspective: :raw] ++ scope_a)

    a_ids = Enum.map(a_hits, & &1.doc_id)

    assert a_total == 1
    assert "drafts.a-hit" in a_ids
    refute "drafts.b-hit" in a_ids

    # Mirror: B's scoped search excludes A's doc.
    {b_hits, b_total, _} =
      Content.search_documents(@term, @ds, [perspective: :raw] ++ scope_b)

    b_ids = Enum.map(b_hits, & &1.doc_id)

    assert b_total == 1
    assert "drafts.b-hit" in b_ids
    refute "drafts.a-hit" in b_ids
  end
end
