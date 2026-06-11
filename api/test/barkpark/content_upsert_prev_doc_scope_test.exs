defmodule Barkpark.ContentUpsertPrevDocScopeTest do
  @moduledoc """
  barkpark-0mw9 (keystone WRITE-scoping fix): `upsert_document/4`'s prev-doc
  lookup must be SCOPED to the writer's workspace/project.

  Before the fix the prev-doc lookup was the 3-arg `get_document(doc_id, type,
  dataset)` — UNSCOPED. When two workspaces each owned a `production` dataset
  (distinct `dataset_id`) holding a document that shared the SAME `(doc_id,
  type)` leaf, an upsert in workspace B's scope would resolve workspace A's row
  as `prev_doc` and UPDATE it — clobbering A's content (or, with the
  uniqueness-flip, risking a MultipleResultsError on a many-match lookup).

  After the fix the lookup threads the writer's scope, so a same-id write from
  workspace B sees no prev_doc for A's row: B updates its OWN row and A's row is
  byte-unchanged.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.{Content, Repo}
  alias Barkpark.Content.Document

  @type_name "post"
  # SAME dataset STRING across both workspaces — isolation must come from the
  # per-project dataset_id the writer's scope resolves, NOT the leaf string.
  @ds "production"
  @doc_id "shared-doc"

  # Two workspaces, each owning a `production` dataset (distinct dataset_id) with
  # a document sharing the SAME doc_id + type. Workspace A is the seeded Default;
  # workspace B is a fresh, isolated tenant. Returns {scope_a, scope_b, doc_a, doc_b}.
  defp two_workspaces_sharing_doc_id do
    {ws_a, proj_a} = ensure_default_scope!()
    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)

    scope_a = [workspace_id: ws_a.id, project_id: proj_a.id]
    scope_b = [workspace_id: ws_b.id, project_id: proj_b.id]

    {:ok, doc_a} =
      Content.create_document(
        @type_name,
        %{"doc_id" => @doc_id, "title" => "A-original"},
        @ds,
        scope_a
      )

    {:ok, doc_b} =
      Content.create_document(
        @type_name,
        %{"doc_id" => @doc_id, "title" => "B-original"},
        @ds,
        scope_b
      )

    # Sanity: same leaf, distinct authoritative dataset_id — the conflation setup.
    assert doc_a.doc_id == doc_b.doc_id
    assert doc_a.type == doc_b.type
    assert doc_a.dataset == doc_b.dataset
    assert is_binary(doc_a.dataset_id)
    assert is_binary(doc_b.dataset_id)
    assert doc_a.dataset_id != doc_b.dataset_id

    {scope_a, scope_b, doc_a, doc_b}
  end

  test "an upsert scoped to B updates B's row and leaves A's row byte-unchanged" do
    {_scope_a, scope_b, doc_a, doc_b} = two_workspaces_sharing_doc_id()

    a_before = Repo.get!(Document, doc_a.id)

    {:ok, updated_b} =
      Content.upsert_document(
        @type_name,
        %{"doc_id" => @doc_id, "title" => "B-edited"},
        @ds,
        scope_b
      )

    # B's OWN row is the one that changed.
    assert updated_b.id == doc_b.id
    assert updated_b.title == "B-edited"
    assert updated_b.dataset_id == doc_b.dataset_id

    # A's row is byte-unchanged — NOT clobbered, no rollback. The unscoped
    # lookup would have resolved A's row as prev_doc and overwritten it here.
    a_after = Repo.get!(Document, doc_a.id)
    assert a_after.title == "A-original"
    assert a_after.title == a_before.title
    assert a_after.content == a_before.content
    assert a_after.dataset_id == a_before.dataset_id
    assert a_after.rev == a_before.rev
    assert a_after.updated_at == a_before.updated_at

    # Two distinct rows still exist — the write did not collapse them.
    assert Repo.aggregate(
             from(d in Document, where: d.doc_id == ^updated_b.doc_id and d.type == @type_name),
             :count
           ) == 2
  end

  test "an upsert in B's scope where the Default has NO matching row does NOT crash" do
    # Only workspace B has a `production` doc for this id. A scoped upsert in B
    # must resolve cleanly (insert, since B has no prev row here either) without
    # a MultipleResultsError from a cross-workspace many-match lookup.
    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)
    scope_b = [workspace_id: ws_b.id, project_id: proj_b.id]

    assert {:ok, doc} =
             Content.upsert_document(
               @type_name,
               %{"doc_id" => "b-fresh", "title" => "fresh"},
               @ds,
               scope_b
             )

    assert doc.title == "fresh"
    assert doc.workspace_id == ws_b.id
    assert doc.project_id == proj_b.id

    # A SECOND scoped upsert of the same id finds B's prev_doc and UPDATEs it
    # (the scoped lookup must still find the writer's own row).
    assert {:ok, updated} =
             Content.upsert_document(
               @type_name,
               %{"doc_id" => "b-fresh", "title" => "fresh-2"},
               @ds,
               scope_b
             )

    assert updated.id == doc.id
    assert updated.title == "fresh-2"
  end
end
