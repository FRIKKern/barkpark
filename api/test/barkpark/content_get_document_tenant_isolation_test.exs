defmodule Barkpark.ContentGetDocumentTenantIsolationTest do
  @moduledoc """
  barkpark-w9dg scar class (the FIXED public-paper cross-workspace leak).

  `Content.get_document/4` — the general single-doc scoped read spine — pipes
  through `Barkpark.Content.Scope.scope_to_workspace_or_global/3`. When a REAL
  `workspace_id` is threaded (the production read path always does) the read is
  scope-by-construction: a doc that lives in workspace B is NOT returned under
  workspace A's scope, and vice-versa. This is the positive lock the static
  `scripts/tenant-scope-check.sh` gate defends — the gate keeps a NEW read from
  reaching for the fail-OPEN nil branch, this test proves the scoped branch
  actually isolates.

  Distinct from `content_cross_project_dataset_scope_test.exs` (which proves the
  dataset-STRING conflation fix on analytics/export/revision reads): this proves
  the by-id `get_document` fetch itself refuses a foreign tenant.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content

  @ds "test"

  test "get_document scoped to workspace A never returns a document created in workspace B" do
    ws_a = create_workspace!()
    proj_a = create_project!(ws_a)
    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)

    scope_a = [workspace_id: ws_a.id, project_id: proj_a.id]
    scope_b = [workspace_id: ws_b.id, project_id: proj_b.id]

    {:ok, doc_b} =
      Content.create_document(
        "post",
        %{"doc_id" => "secret-b", "title" => "B secret"},
        @ds,
        scope_b
      )

    # Sanity — B's own scope finds B's doc (the read actually surfaces it).
    assert {:ok, _} = Content.get_document(doc_b.doc_id, "post", @ds, scope_b)

    # The leak guard — A's scope must NEVER see B's doc, even though the doc_id +
    # type + dataset STRING are all known to A. Isolation comes from workspace_id,
    # not the dataset leaf (both workspaces share the "test" dataset string).
    assert {:error, :not_found} = Content.get_document(doc_b.doc_id, "post", @ds, scope_a)
  end

  test "the mirror — get_document scoped to B never returns A's document" do
    ws_a = create_workspace!()
    proj_a = create_project!(ws_a)
    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)

    scope_a = [workspace_id: ws_a.id, project_id: proj_a.id]
    scope_b = [workspace_id: ws_b.id, project_id: proj_b.id]

    {:ok, doc_a} =
      Content.create_document(
        "post",
        %{"doc_id" => "secret-a", "title" => "A secret"},
        @ds,
        scope_a
      )

    assert {:ok, _} = Content.get_document(doc_a.doc_id, "post", @ds, scope_a)
    assert {:error, :not_found} = Content.get_document(doc_a.doc_id, "post", @ds, scope_b)
  end
end
