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
end
