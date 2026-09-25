defmodule Barkpark.Content.PatchKeepsRowWorkspaceTest do
  @moduledoc """
  task-60f53b3ab9cc6bb0 — a patch to an EXISTING row never changes the row's
  workspace.

  `Writer.upsert_document/4` stamps the RESOLVED write scope
  (`WriteScope.put_scope_attrs/2`) and its update branch handed that stamp to
  `Document.changeset(existing, …)`. The resolved scope is right for a birth and
  wrong for an update whenever it differs from the row being updated — which a
  key-absent write resolves independently of the row it read:

    * no caller (`[]`)            -> the seeded Default    (class c residual)
    * a single-workspace caller   -> that caller's workspace (class a, inferred)
    * a `:shared_only` caller     -> reads ONLY shared (NULL-workspace) rows,
                                     stamps the caller's inferred workspace
                                     (internal callers only: the /mutate door
                                     swaps in the inferred binary workspace
                                     before the batch, so its reads are
                                     fail-closed and it cannot reach this)

  Each arm below takes a row living somewhere else and patches it through
  `Content.apply_mutations/3`. The unscoped arms use a PROJECTLESS workspace:
  its rows carry no `dataset_id` (the legacy / wykb shape), and only such a
  row is visible to an unscoped read at all. A row with a `dataset_id` in
  another workspace's project is invisible to it (`:not_found`, pinned as a
  control), so it cannot be moved. On origin/main the row moves; after the fix it
  keeps its own workspace and is audited under it. Creates are the control:
  a key-absent create still lands where it did.

  `async: false`: the class-(c) arm reads the process-global seeded Default.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.{Content, Repo, Tenancy, TenancyFixtures}
  alias Barkpark.Audit.Event
  alias Barkpark.Content.{CallerContext, Document}

  @dataset "production"
  @type_name "post"

  defp workspace_with_project! do
    ws = TenancyFixtures.create_workspace!()
    _ = TenancyFixtures.create_project!(ws, "default")
    ws
  end

  defp user_in!(workspaces) do
    user =
      Barkpark.AccountsFixtures.register_user(
        "restamp-#{System.unique_integer([:positive])}@example.com"
      )

    for ws <- workspaces do
      {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, "member", "user")
    end

    user
  end

  defp draft_in!(ws) do
    id = "restamp-#{System.unique_integer([:positive])}"

    {:ok, doc} =
      Content.create_document(@type_name, %{"doc_id" => id, "title" => "before"}, @dataset,
        workspace_id: ws.id
      )

    assert doc.workspace_id == ws.id
    id
  end

  defp patch(id),
    do: %{"patch" => %{"id" => id, "type" => @type_name, "set" => %{"title" => "after"}}}

  defp row(id) do
    Repo.one!(
      from(d in Document,
        where: d.doc_id == ^("drafts." <> id) and d.type == @type_name,
        select: %{workspace_id: d.workspace_id, project_id: d.project_id, title: d.title}
      )
    )
  end

  defp update_audit_workspaces(id) do
    Repo.all(
      from(e in Event,
        where: e.subject == ^("drafts." <> id) and e.action == "document.update",
        select: e.workspace_id
      )
    )
  end

  describe "a patch to an existing row keeps the row's workspace" do
    test "no caller (class c): a W2 row is not moved into the seeded Default" do
      {default, _} = TenancyFixtures.ensure_default_scope!()
      w2 = TenancyFixtures.create_workspace!()
      id = draft_in!(w2)
      before = row(id)

      assert {:ok, _} = Content.apply_mutations([patch(id)], @dataset, [])

      after_ = row(id)
      assert after_.title == "after", "the patch must land, or this test proves nothing"
      refute after_.workspace_id == default.id, "the unscoped patch moved the W2 row into Default"
      assert after_.workspace_id == w2.id
      assert after_.project_id == before.project_id
      assert update_audit_workspaces(id) == [w2.id]
    end

    test "a single-workspace caller (class a): a W2 row is not moved into the caller's W1" do
      w1 = workspace_with_project!()
      w2 = TenancyFixtures.create_workspace!()
      user = user_in!([w1])
      id = draft_in!(w2)

      ctx = %CallerContext{principal_type: :user, user_id: user.id}
      assert {:ok, _} = Content.apply_mutations([patch(id)], @dataset, caller_context: ctx)

      after_ = row(id)
      assert after_.title == "after"
      assert after_.workspace_id == w2.id, "the inferred patch moved the W2 row into W1"
      assert update_audit_workspaces(id) == [w2.id]
    end

    test "a :shared_only caller: a SHARED (NULL-workspace) row is not adopted by the caller" do
      w1 = workspace_with_project!()
      user = user_in!([w1])
      id = "restamp-shared-#{System.unique_integer([:positive])}"

      Repo.insert!(%Document{
        doc_id: "drafts." <> id,
        type: @type_name,
        dataset: @dataset,
        title: "before",
        status: "draft",
        content: %{},
        rev: "r-#{System.unique_integer([:positive])}",
        workspace_id: nil
      })

      ctx = %CallerContext{principal_type: :user, user_id: user.id}

      assert {:ok, _} =
               Content.apply_mutations([patch(id)], @dataset,
                 workspace_id: :shared_only,
                 caller_context: ctx
               )

      after_ = row(id)
      assert after_.title == "after"
      assert is_nil(after_.workspace_id), "the :shared_only patch moved a shared row into W1"
      assert update_audit_workspaces(id) == [nil]
    end
  end

  describe "controls" do
    test "an unscoped read cannot see a W2 row that has a dataset_id, so it cannot move it" do
      TenancyFixtures.ensure_default_scope!()
      w2 = workspace_with_project!()
      id = draft_in!(w2)

      assert {:error, :not_found} = Content.apply_mutations([patch(id)], @dataset, [])
      assert %{title: "before", workspace_id: ws} = row(id)
      assert ws == w2.id
    end

    test "a SCOPED patch in the row's own workspace still lands, same workspace" do
      w2 = workspace_with_project!()
      id = draft_in!(w2)

      assert {:ok, _} = Content.apply_mutations([patch(id)], @dataset, workspace_id: w2.id)

      assert %{title: "after", workspace_id: ws} = row(id)
      assert ws == w2.id
    end

    test "a key-absent CREATE keeps its current resolution (the seeded Default)" do
      {default, _} = TenancyFixtures.ensure_default_scope!()
      id = "restamp-create-#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               Content.apply_mutations(
                 [%{"create" => %{"_id" => id, "_type" => @type_name, "title" => "born"}}],
                 @dataset,
                 []
               )

      assert %{workspace_id: ws} = row(id)
      assert ws == default.id
    end
  end
end
