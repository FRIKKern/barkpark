defmodule Barkpark.Search.DocumentsRetrieverTest do
  @moduledoc """
  Covers DocumentsRetriever.search/4 behaviour that the scope-isolation test
  does not touch: browse mode (empty query), type filtering, perspective
  (published vs drafts), and the types allowlist.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content

  @ds "retriever-test"

  defp setup_scope do
    ws = create_workspace!()
    proj = create_project!(ws)
    [workspace_id: ws.id, project_id: proj.id]
  end

  defp unique_id, do: "doc-#{System.unique_integer([:positive])}"

  # ── browse (empty query) ────────────────────────────────────────────────────

  test "browse mode (empty query) returns all published docs in the dataset" do
    scope = setup_scope()
    doc_id = unique_id()

    {:ok, _} =
      Content.create_document("post", %{"doc_id" => doc_id, "title" => "Browse Target"}, @ds, scope)

    {:ok, _} = Content.publish_document(doc_id, "post", @ds, scope)

    {hits, total, _meta} = Content.search_documents("", @ds, scope)

    ids = Enum.map(hits, & &1.doc_id)
    assert total >= 1
    assert doc_id in ids
  end

  # ── type filter ─────────────────────────────────────────────────────────────

  test "type opt limits results to matching type" do
    scope = setup_scope()
    post_id = unique_id()
    page_id = unique_id()

    {:ok, _} =
      Content.create_document("post", %{"doc_id" => post_id, "title" => "Post Doc"}, @ds, scope)

    {:ok, _} = Content.publish_document(post_id, "post", @ds, scope)

    {:ok, _} =
      Content.create_document("page", %{"doc_id" => page_id, "title" => "Page Doc"}, @ds, scope)

    {:ok, _} = Content.publish_document(page_id, "page", @ds, scope)

    {hits, _total, _} = Content.search_documents("", @ds, [type: "post"] ++ scope)
    ids = Enum.map(hits, & &1.doc_id)

    assert post_id in ids
    refute page_id in ids
  end

  # ── types allowlist ─────────────────────────────────────────────────────────

  test "types allowlist restricts results to listed types only" do
    scope = setup_scope()
    post_id = unique_id()
    note_id = unique_id()
    page_id = unique_id()

    for {type, id, title} <- [
          {"post", post_id, "Allowlist Post"},
          {"note", note_id, "Allowlist Note"},
          {"page", page_id, "Allowlist Page"}
        ] do
      {:ok, _} = Content.create_document(type, %{"doc_id" => id, "title" => title}, @ds, scope)
      {:ok, _} = Content.publish_document(id, type, @ds, scope)
    end

    {hits, _total, _} = Content.search_documents("", @ds, [types: ["post", "note"]] ++ scope)
    ids = Enum.map(hits, & &1.doc_id)

    assert post_id in ids
    assert note_id in ids
    refute page_id in ids
  end

  # ── perspective: published vs drafts ────────────────────────────────────────

  test "default perspective returns only published docs (not drafts)" do
    scope = setup_scope()
    id = unique_id()

    # Create draft only — no publish step.
    {:ok, _} =
      Content.create_document("post", %{"doc_id" => id, "title" => "Draft Only"}, @ds, scope)

    {hits, _total, _} = Content.search_documents("", @ds, scope)
    ids = Enum.map(hits, & &1.doc_id)

    refute id in ids
    refute "drafts.#{id}" in ids
  end

  test "perspective :drafts returns only draft docs" do
    scope = setup_scope()
    id = unique_id()

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => id, "title" => "Draft Perspective"},
        @ds,
        scope
      )

    # Not published — should appear under :drafts, not under :published.
    {draft_hits, _total, _} = Content.search_documents("", @ds, [perspective: :drafts] ++ scope)
    draft_ids = Enum.map(draft_hits, & &1.doc_id)

    assert "drafts.#{id}" in draft_ids
  end
end
