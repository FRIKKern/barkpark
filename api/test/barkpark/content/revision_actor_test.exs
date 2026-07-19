defmodule Barkpark.Content.RevisionActorTest do
  @moduledoc """
  activity-audit-log (api/ half): the `revisions` table gains an `actor_user_id`
  threaded from the mutation's `opts[:user_id]` (`ctx.user_id`) through
  `tap_broadcast/6` → `save_revision/5`. This turns version history into a
  who-edited-what content trail, atomic-with-mutation for free (the revision
  insert already runs inside the write path).

  Back-compat is part of the contract: a write with NO `:user_id` leaves the
  actor nil, so every existing caller (and test) keeps passing.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.{Document, Revision}
  alias Barkpark.Repo

  defp scope do
    ws = create_workspace!()
    proj = create_project!(ws)
    [workspace_id: ws.id, project_id: proj.id]
  end

  describe "actor threading" do
    test "a write with :user_id stamps the new revision's actor_user_id" do
      opts = [{:user_id, "u-1"} | scope()]

      {:ok, _} =
        Content.upsert_document(
          "post",
          %{"doc_id" => "p-actor", "title" => "Hi"},
          "production",
          opts
        )

      [rev | _] = Content.list_revisions("p-actor", "post", "production", opts)
      assert rev.actor_user_id == "u-1"
    end

    test "a write WITHOUT :user_id leaves actor_user_id nil (back-compat)" do
      opts = scope()

      {:ok, _} =
        Content.upsert_document(
          "post",
          %{"doc_id" => "p-anon", "title" => "Hi"},
          "production",
          opts
        )

      [rev | _] = Content.list_revisions("p-anon", "post", "production", opts)
      assert is_nil(rev.actor_user_id)
    end

    test "each edit records its own actor — the trail follows the editor" do
      base = scope()

      {:ok, _} =
        Content.upsert_document(
          "post",
          %{"doc_id" => "p-trail", "title" => "v1"},
          "production",
          [{:user_id, "alice"} | base]
        )

      {:ok, _} =
        Content.upsert_document(
          "post",
          %{"doc_id" => "p-trail", "title" => "v2"},
          "production",
          [{:user_id, "bob"} | base]
        )

      actors =
        "p-trail"
        |> Content.list_revisions("post", "production", base)
        |> Enum.map(& &1.actor_user_id)

      # Newest first: bob's edit, then alice's.
      assert "bob" in actors
      assert "alice" in actors
    end
  end

  describe "document binding" do
    test "a draft document records history under its canonical published id" do
      opts = scope()
      id = "revision-binding-#{System.unique_integer([:positive])}"

      assert {:ok, document} =
               Content.create_document(
                 "post",
                 %{"_id" => id, "title" => "Canonical history"},
                 "production",
                 opts
               )

      assert document.doc_id == "drafts.#{id}"

      [revision | _] = Content.list_revisions(id, "post", "production", opts)
      assert revision.document_id == document.id
      assert revision.doc_id == id
      assert revision.type == document.type
      assert revision.dataset_id == document.dataset_id
      assert revision.workspace_id == document.workspace_id
      assert revision.project_id == document.project_id
      assert revision.title == document.title
      assert revision.status == document.status
      assert revision.content == document.content
    end

    test "a draft document rejects a noncanonical draft-prefixed revision id" do
      opts = scope()
      id = "revision-binding-hostile-#{System.unique_integer([:positive])}"

      assert {:ok, document} =
               Content.create_document(
                 "post",
                 %{"_id" => id, "title" => "Reject alternate id"},
                 "production",
                 opts
               )

      [revision | _] = Content.list_revisions(id, "post", "production", opts)

      hostile_attrs =
        revision
        |> Map.from_struct()
        |> Map.take([
          :document_id,
          :type,
          :dataset,
          :dataset_id,
          :title,
          :status,
          :content,
          :workspace_id,
          :project_id
        ])
        |> Map.merge(%{doc_id: document.doc_id, action: "update"})

      assert_raise Postgrex.Error,
                   ~r/revision snapshot does not exactly match its document/,
                   fn ->
                     %Revision{}
                     |> Revision.changeset(hostile_attrs)
                     |> Repo.insert!()
                   end
    end
  end

  describe "lifecycle-transition actor threading" do
    test "publish and unpublish preserve canonical history while deleted twin FKs nullify" do
      base = scope()
      id = "revision-lifecycle-#{System.unique_integer([:positive])}"

      write = fn actor, title, version ->
        Content.upsert_document(
          "post",
          %{
            "doc_id" => id,
            "title" => title,
            "content" => %{"version" => version}
          },
          "production",
          [{:user_id, actor} | base]
        )
      end

      assert {:ok, first_draft} =
               Content.create_document(
                 "post",
                 %{
                   "_id" => id,
                   "title" => "Draft v1",
                   "content" => %{"version" => "draft-v1"}
                 },
                 "production",
                 [{:user_id, "draft-author-1"} | base]
               )

      assert {:ok, _} = write.("draft-author-2", "Draft v2", "draft-v2")
      assert {:ok, _} = write.("draft-author-3", "Draft v3", "draft-v3")

      draft_history = Content.list_revisions(id, "post", "production", base)

      assert Enum.map(draft_history, & &1.actor_user_id) |> Enum.sort() ==
               Enum.sort(["draft-author-1", "draft-author-2", "draft-author-3"])

      assert Enum.all?(draft_history, &(&1.document_id == first_draft.id))
      draft_snapshots = revision_snapshots(draft_history)

      assert {:ok, published} =
               Content.publish_document(id, "post", "production", [
                 {:user_id, "publisher-1"} | base
               ])

      assert is_nil(Repo.get(Document, first_draft.id))

      Enum.each(draft_snapshots, fn {revision_id, snapshot} ->
        revision = Repo.get!(Revision, revision_id)
        assert is_nil(revision.document_id)
        assert revision_snapshot(revision) == snapshot
      end)

      first_publish_revision =
        Content.list_revisions(id, "post", "production", base)
        |> Enum.find(&(&1.actor_user_id == "publisher-1"))

      assert first_publish_revision.document_id == published.id
      assert first_publish_revision.status == "published"
      assert first_publish_revision.content == %{"version" => "draft-v3"}

      assert {:ok, second_draft} = write.("published-editor-1", "Published edit v1", "edit-v1")
      assert {:ok, _} = write.("published-editor-2", "Published edit v2", "edit-v2")

      second_draft_history =
        Content.list_revisions(id, "post", "production", base)
        |> Enum.filter(&(&1.actor_user_id in ["published-editor-1", "published-editor-2"]))

      assert Enum.all?(second_draft_history, &(&1.document_id == second_draft.id))
      second_draft_snapshots = revision_snapshots(second_draft_history)

      assert {:ok, republished} =
               Content.publish_document(id, "post", "production", [
                 {:user_id, "publisher-2"} | base
               ])

      assert republished.id == published.id

      Enum.each(second_draft_snapshots, fn {revision_id, snapshot} ->
        revision = Repo.get!(Revision, revision_id)
        assert is_nil(revision.document_id)
        assert revision_snapshot(revision) == snapshot
      end)

      before_unpublish = Content.list_revisions(id, "post", "production", base)
      before_unpublish_snapshots = revision_snapshots(before_unpublish)
      assert Enum.any?(before_unpublish, &(&1.actor_user_id == "publisher-2"))

      assert {:ok, unpublished_draft} =
               Content.unpublish_document(id, "post", "production", [
                 {:user_id, "unpublisher"} | base
               ])

      Enum.each(before_unpublish_snapshots, fn {revision_id, snapshot} ->
        revision = Repo.get!(Revision, revision_id)
        assert is_nil(revision.document_id)
        assert revision_snapshot(revision) == snapshot
      end)

      after_unpublish = Content.list_revisions(id, "post", "production", base)
      assert length(after_unpublish) == length(before_unpublish) + 1

      unpublish_revision = Enum.find(after_unpublish, &(&1.actor_user_id == "unpublisher"))
      assert unpublish_revision.document_id == unpublished_draft.id
      assert unpublish_revision.status == "draft"
      assert unpublish_revision.content == %{"version" => "edit-v2"}
    end

    test "publish with :user_id stamps the publish revision's actor_user_id" do
      base = scope()

      {:ok, _} =
        Content.create_document(
          "post",
          %{"_id" => "p-pub", "title" => "Hi"},
          "production",
          base
        )

      {:ok, _} =
        Content.publish_document("p-pub", "post", "production", [{:user_id, "publisher"} | base])

      pub_rev =
        "p-pub"
        |> Content.list_revisions("post", "production", base)
        |> Enum.find(&(&1.action == "publish"))

      assert pub_rev, "expected a publish revision"
      assert pub_rev.actor_user_id == "publisher"
    end

    test "delete with :user_id stamps the delete revision's actor_user_id" do
      base = scope()

      {:ok, _} =
        Content.create_document(
          "post",
          %{"_id" => "p-del", "title" => "Hi"},
          "production",
          base
        )

      {:ok, _} =
        Content.delete_document("p-del", "post", "production", [{:user_id, "deleter"} | base])

      del_rev =
        "p-del"
        |> Content.list_revisions("post", "production", base)
        |> Enum.find(&(&1.action == "delete"))

      assert del_rev, "expected a delete revision"
      assert del_rev.actor_user_id == "deleter"
    end
  end

  defp revision_snapshots(revisions) do
    Map.new(revisions, &{&1.id, revision_snapshot(&1)})
  end

  defp revision_snapshot(revision) do
    Map.take(revision, [
      :doc_id,
      :type,
      :dataset,
      :dataset_id,
      :title,
      :status,
      :content,
      :action,
      :actor_user_id,
      :workspace_id,
      :project_id
    ])
  end
end
