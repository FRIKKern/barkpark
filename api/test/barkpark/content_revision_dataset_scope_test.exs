defmodule Barkpark.ContentRevisionDatasetScopeTest do
  @moduledoc """
  barkpark-vdmk: intra-workspace revision IDOR + cross-dataset restore.

  `HistoryController.show` / `restore` receive `:dataset` in the URL, but before
  this fix `Content.get_revision/2` filtered ONLY by `r.id` + workspace/project
  scope — never by dataset. So inside ONE workspace:

    (a) a token could fetch ANY revision in its workspace by UUID regardless of
        the URL dataset (intra-workspace IDOR READ), and
    (b) `restore_revision/4` would read a rev from dataset A and re-upsert it
        under the URL's `dataset` B (a cross-dataset WRITE).

  The fix threads the dataset through `get_revision/3` and applies
  `scope_to_dataset` (NULL-tolerant), plus a `rev.dataset == dataset` assertion
  on restore. These tests prove all three legs — and the IDOR-READ test is
  guarded against a silent revert by asserting the leak path is closed.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content

  @ds_a "alpha"
  @ds_b "beta"

  # One workspace+project, two distinct dataset STRINGS, each with its own
  # revision for the same logical doc_id. Returns {scope, rev_a, rev_b}.
  defp one_workspace_two_datasets do
    ws = create_workspace!()
    proj = create_project!(ws)
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_document("post", %{"doc_id" => "shared", "title" => "A-title"}, @ds_a, scope)

    {:ok, _} =
      Content.upsert_document("post", %{"doc_id" => "shared", "title" => "B-title"}, @ds_b, scope)

    [rev_a | _] = Content.list_revisions("shared", "post", @ds_a, scope)
    [rev_b | _] = Content.list_revisions("shared", "post", @ds_b, scope)

    {scope, rev_a, rev_b}
  end

  describe "get_revision/3 dataset scoping (intra-workspace IDOR READ)" do
    test "fetching A's revision under dataset B (same workspace) is not_found" do
      {scope, rev_a, _rev_b} = one_workspace_two_datasets()

      # The bug: same workspace, A's revision id, but the URL names dataset B.
      # Pre-fix this returned {:ok, rev_a} (leak). Post-fix → :not_found.
      assert {:error, :not_found} = Content.get_revision(rev_a.id, @ds_b, scope)
    end

    test "LEAK GUARD: the same id IS reachable under its OWN dataset" do
      # Proves the not_found above is dataset scoping, not a broken fixture: the
      # revision genuinely exists and is fetchable when the dataset matches. If a
      # future edit reverts the scope, the cross-dataset test above flips to a
      # leak while THIS one still passes — the pair is the regression tripwire.
      {scope, rev_a, _rev_b} = one_workspace_two_datasets()

      assert {:ok, fetched} = Content.get_revision(rev_a.id, @ds_a, scope)
      assert fetched.id == rev_a.id
      assert fetched.dataset == @ds_a
    end

    test "LEGIT: each dataset's own revision is fetchable under its own scope" do
      {scope, rev_a, rev_b} = one_workspace_two_datasets()

      assert {:ok, fa} = Content.get_revision(rev_a.id, @ds_a, scope)
      assert {:ok, fb} = Content.get_revision(rev_b.id, @ds_b, scope)
      assert fa.title == "A-title"
      assert fb.title == "B-title"
    end
  end

  describe "restore_revision/4 dataset assertion (CROSS-DATASET WRITE)" do
    test "restoring A's revision while the URL names dataset B is rejected" do
      {scope, rev_a, _rev_b} = one_workspace_two_datasets()

      # The cross-dataset write: rev belongs to A, URL names B. Must refuse so
      # A's content cannot be re-upserted into B inside the workspace.
      assert {:error, :not_found} =
               Content.restore_revision(rev_a.id, "post", @ds_b, [source: :api] ++ scope)

      # And no write happened into B: B's "shared" doc still carries its own
      # title, never A's.
      [b_rev | _] = Content.list_revisions("shared", "post", @ds_b, scope)
      assert b_rev.title == "B-title"
    end

    test "LEGIT: restoring a revision into its OWN dataset works" do
      {scope, rev_a, _rev_b} = one_workspace_two_datasets()

      assert {:ok, doc} =
               Content.restore_revision(rev_a.id, "post", @ds_a, [source: :api] ++ scope)

      assert doc.title == "A-title"
      assert doc.dataset == @ds_a
    end
  end
end
