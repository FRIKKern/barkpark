defmodule Barkpark.Plugins.OutboundOneWorkspaceTest do
  @moduledoc """
  Owner ruling #12 (task-803343b8cce8bfb7): on a box with several workspaces,
  the outbound GitHub mirror sends only the intake workspace's tasks, and
  Bokbasen only receives books from an allow-listed workspace.

  Both sinks are instance-wide (one repo, one Bokbasen account). Before this,
  every workspace's tasks were published to the repo and every workspace's
  published books were submitted under the one account. Unset, both keep
  today's behaviour, so single-workspace installs see no change.

  `async: false` — both switches are OS env vars.
  """
  use Barkpark.DataCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.MutationEvent
  alias Barkpark.Plugins.Github.Outbox
  alias Barkpark.Plugins.OnixEdit.Bokbasen.PublishWorker
  alias Barkpark.Plugins.OnixEdit.Lifecycle
  alias Barkpark.Repo

  @github_env "BARKPARK_GITHUB_INTAKE_WORKSPACE_ID"
  @bokbasen_env "BARKPARK_BOKBASEN_WORKSPACE_IDS"
  @dataset "outbound-one-ws"

  setup do
    prior = {System.get_env(@github_env), System.get_env(@bokbasen_env)}

    on_exit(fn ->
      {g, b} = prior
      if g, do: System.put_env(@github_env, g), else: System.delete_env(@github_env)
      if b, do: System.put_env(@bokbasen_env, b), else: System.delete_env(@bokbasen_env)
    end)

    System.delete_env(@github_env)
    System.delete_env(@bokbasen_env)

    %{ws_a: create_workspace!(), ws_b: create_workspace!()}
  end

  defp event!(doc_id, workspace_id) do
    %MutationEvent{}
    |> Ecto.Changeset.change(%{
      dataset: @dataset,
      type: "task",
      doc_id: doc_id,
      mutation: "create",
      rev: "r-#{doc_id}",
      document: %{"_id" => doc_id, "_type" => "task"},
      source: "api",
      workspace_id: workspace_id,
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp fetched_ids, do: @dataset |> Outbox.fetch(0, 100) |> Enum.map(& &1.doc_id) |> Enum.sort()

  describe "GitHub outbox" do
    test "with the intake workspace set, workspace B's task is not fetched", %{ws_a: a, ws_b: b} do
      event!("task-a", a.id)
      event!("task-b", b.id)

      System.put_env(@github_env, a.id)
      assert fetched_ids() == ["task-a"]
    end

    test "unset, every workspace's task is fetched as before", %{ws_a: a, ws_b: b} do
      event!("task-a", a.id)
      event!("task-b", b.id)

      assert fetched_ids() == ["task-a", "task-b"]
    end
  end

  describe "Bokbasen auto-submit on publish" do
    defp publish_payload(workspace_id) do
      doc = %{type: "book", doc_id: "book-1", workspace_id: workspace_id, project_id: nil}

      %{
        event: :after_publish,
        doc: doc,
        dataset: "production",
        prev_doc: doc,
        ctx: %{source: :studio}
      }
    end

    test "a book from a workspace outside the allowlist is not enqueued", %{ws_a: a, ws_b: b} do
      System.put_env(@bokbasen_env, a.id)

      assert :ok == Lifecycle.publish_to_bokbasen_if_book(publish_payload(b.id))
      refute_enqueued(worker: PublishWorker)

      assert :ok == Lifecycle.publish_to_bokbasen_if_book(publish_payload(a.id))
      assert_enqueued(worker: PublishWorker, args: %{"document_id" => "book-1"})
    end

    test "unset, a book from any workspace is enqueued as before", %{ws_b: b} do
      assert :ok == Lifecycle.publish_to_bokbasen_if_book(publish_payload(b.id))
      assert_enqueued(worker: PublishWorker, args: %{"document_id" => "book-1"})
    end
  end

  describe "the worker, the floor for the manual action too" do
    @describetag :requires_plugins

    test "refuses a book outside the allowlist before any Bokbasen call", %{ws_a: a, ws_b: b} do
      proj_b = create_project!(b)
      scope = [workspace_id: b.id, project_id: proj_b.id]

      {:ok, doc} =
        Content.create_document(
          "book",
          %{"doc_id" => "book-b", "title" => "B book", "content" => %{}},
          "production",
          scope
        )

      System.put_env(@bokbasen_env, "#{a.id}, ")

      args =
        %{"document_id" => doc.doc_id, "type" => "book", "dataset" => "production"}
        |> PublishWorker.put_scope_args(scope)

      assert {:cancel, :workspace_not_allowed} = perform_job(PublishWorker, args)
    end
  end
end
